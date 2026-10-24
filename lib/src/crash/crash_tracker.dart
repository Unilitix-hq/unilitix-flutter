import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' show ClientException;

import '../events/event.dart';
import '../logger/logger.dart';
import '../core/sdk_scope.dart';
import '../storage/event_database.dart';
import '../generated/sdk_contract.dart';

/// Where a native crash from a previous process should be attributed.
class CrashAttribution {
  /// The session that was running when the process died, or null when no
  /// session stub matches (the event then goes to the current session).
  final String? sessionId;
  const CrashAttribution(this.sessionId);
}

/// Installs error hooks and classifies what they catch.
///
/// Three tiers, matching how Crashlytics and Sentry report:
///  * `EXCEPTION` (non-fatal) — `FlutterError.onError`: build/layout errors the
///    framework already caught. The app keeps running; the session is not
///    marked crashed. Previously every one of these was recorded as a CRASH,
///    which inflated crash rates with overflow warnings.
///  * `CRASH` (fatal: false) — `PlatformDispatcher.onError`: an uncaught Dart
///    error. Marks the session crashed; the Flutter engine usually survives.
///  * `CRASH` (fatal: true) — native: a JVM uncaught exception, an NSException
///    or a fatal signal recorded by the platform plugin and reported on the
///    next launch, against the session that was running when it happened.
///
/// Android 11+ also reports ANRs the system killed the app for (2.6.0): the
/// plugin returns them in the same stream as native crashes, and they become
/// `ANR` events (not crashes: the session is not marked crashed) against the
/// session that was running, the same way.
///
/// iOS reports app hangs (2.7.0): the plugin's main-thread watchdog
/// (UnilitixCore's detector and stack sampler) sends a hang the app recovered
/// from live, on `com.unilitix/app_hang` ([handleAppHang]: an `ANR` in the
/// current session, under the per-session caps), and one the process did not
/// survive through `readNativeCrash` on the next launch, like Android's.
///
/// Every record carries a [fingerprint] in `metadata` so the server can count
/// one bug once across devices, and repeats of the same fingerprint within a
/// session are capped ([maxPerFingerprint]) so a build-method error that
/// fires every frame does not flood the queue.
class CrashTracker {
  final void Function(UnilitixEvent event) onCrashEvent;
  final void Function(UnilitixEvent event)? onExceptionEvent;

  /// An ANR from an earlier process that no stored session matches; it goes
  /// to the current session, which it must not mark crashed. Unset, it
  /// falls back to [onExceptionEvent], then [onCrashEvent] (the SDK sets it).
  final void Function(UnilitixEvent event)? onAnrEvent;
  final List<Map<String, dynamic>> breadcrumbs;
  final EventDatabase database;

  /// Same-fingerprint reports allowed per session; later ones are counted
  /// (`metadata.occurrences`) on the next report of that fingerprint only.
  final int maxPerFingerprint;

  /// Total crash + exception reports allowed per session.
  final int maxPerSession;

  static const _sdkChannel = MethodChannel('com.unilitix/sdk');

  /// iOS: hangs the main thread recovered from, pushed by the plugin.
  static const _appHangChannel = MethodChannel('com.unilitix/app_hang');

  /// The iOS plugin's hang id (a lower-case UUID), used as the event id.
  static final _uuidRe =
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

  FlutterExceptionHandler? _previousFlutterHandler;
  bool Function(Object error, StackTrace stack)? _previousPlatformHandler;
  bool _isRecording = false;
  bool _installed = false;
  int _appHangTimeoutMs = 0;

  final Map<String, int> _seen = {};
  int _reportedThisSession = 0;

  CrashTracker({
    required this.onCrashEvent,
    required this.breadcrumbs,
    required this.database,
    this.onExceptionEvent,
    this.onAnrEvent,
    this.maxPerFingerprint = SdkContract.maxReportsPerFingerprint,
    this.maxPerSession = SdkContract.maxErrorReportsPerSession,
  });

  /// Installs the hooks, chaining to whatever the app (or another SDK) had
  /// installed before: the previous `FlutterError.onError` still runs, and the
  /// previous `PlatformDispatcher.onError` still decides whether the error is
  /// considered handled.
  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutterHandler = FlutterError.onError;

    // 1. Framework-caught errors: non-fatal.
    FlutterError.onError = (details) {
      _record(details.exception, details.stack, type: EventTypes.exception);
      _previousFlutterHandler?.call(details);
    };

    // 2. Uncaught Dart errors: a crash from the user's point of view.
    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error, stack, type: EventTypes.crash);
      final previous = _previousPlatformHandler;
      if (previous != null) {
        try {
          return previous(error, stack);
        } catch (_) {
          // A throwing upstream handler must not hide the original error.
        }
      }
      // In debug: return false so Flutter re-throws and shows the red screen.
      // In release: return true to suppress the rethrow.
      return !kDebugMode;
    };
  }

  /// Restores the handlers that were in place before [install]. Used by
  /// tests and hot restart.
  void uninstall() {
    if (_appHangTimeoutMs > 0) {
      // Stops listening only; the plugin keeps a hang it could not deliver.
      _appHangChannel.setMethodCallHandler(null);
      _appHangTimeoutMs = 0;
    }
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousFlutterHandler;
    PlatformDispatcher.instance.onError = _previousPlatformHandler;
  }

  // ── iOS app hangs ─────────────────────────────────────────────────────────

  /// iOS: starts the plugin's main-thread watchdog (once per process; later
  /// calls only update [capture]) and listens for the hangs it reports.
  /// [timeoutMs] <= 0 does nothing. Call after [reportNativeCrashIfAny] /
  /// [discardNativeCrashes], so the earlier launch's hang is read before
  /// this process can record one. [capture] is false while consent is
  /// denied: a hang is then not recorded at all.
  Future<void> startAppHangDetection(
      {required int timeoutMs, required bool capture}) async {
    if (timeoutMs <= 0) return;
    _appHangTimeoutMs = timeoutMs;
    _appHangChannel.setMethodCallHandler(_onAppHangCall);
    await _configureAppHang(capture);
  }

  /// Consent changed: hangs are recorded unless [capture] is false.
  Future<void> setAppHangCapture(bool capture) async {
    if (_appHangTimeoutMs <= 0) return;
    await _configureAppHang(capture);
  }

  Future<void> _configureAppHang(bool capture) async {
    try {
      await _sdkChannel.invokeMethod<void>('configureAppHang',
          {'timeoutMs': _appHangTimeoutMs, 'capture': capture});
    } catch (e) {
      // Old plugin, or no native side: no hang detection.
      UnilitixLogger.d('App-hang detection unavailable: $e');
    }
  }

  /// Answers true once the hang is dealt with (reported, held for consent,
  /// or dropped), so the plugin deletes its copy; it is never sent twice.
  Future<Object?> _onAppHangCall(MethodCall call) async {
    if (call.method != 'onAppHang') throw MissingPluginException();
    final raw = call.arguments;
    if (raw is String) {
      try {
        handleAppHang(raw);
      } catch (e) {
        UnilitixLogger.w('Could not report app hang: $e');
      }
    }
    return true;
  }

  /// A hang the main thread recovered from in this process (iOS plugin
  /// record, see [anrEventFromRecord]): an `ANR` in the current session, on
  /// the current screen with the current breadcrumbs, not marking it
  /// crashed, under the same per-session caps as crashes and exceptions.
  /// Returns true when it was reported (consent is applied by the
  /// receiver: pending holds it, denied drops it).
  @visibleForTesting
  bool handleAppHang(String raw) {
    final m = jsonDecode(raw);
    if (m is! Map<String, dynamic> || m['type'] != EventTypes.anr) {
      return false;
    }
    final event = anrEventFromRecord(m,
        screen: SdkScope.currentScreen, breadcrumbs: List.of(breadcrumbs));
    final fp = event.crashMetadata!['fingerprint'] as String;
    final n = (_seen[fp] ?? 0) + 1;
    _seen[fp] = n;
    if (n > maxPerFingerprint || _reportedThisSession >= maxPerSession) {
      UnilitixLogger.d('Suppressed repeat ANR $fp (#$n this session)');
      return false;
    }
    _reportedThisSession++;
    UnilitixLogger.d('App hang: ${event.exceptionMessage}');
    (onAnrEvent ?? onExceptionEvent ?? onCrashEvent)(event);
    return true;
  }

  /// Clears the per-session dedup state. Called on every session start.
  void resetSession() {
    _seen.clear();
    _reportedThisSession = 0;
  }

  /// Records an error the app caught itself (`Unilitix.captureException`).
  void capture(Object error, StackTrace? stack, {bool fatal = false}) {
    _record(error, stack,
        type: fatal ? EventTypes.crash : EventTypes.exception);
  }

  void _record(Object error, StackTrace? stack, {required String type}) {
    if (_isRecording) return;
    _isRecording = true;
    try {
      // Network errors are not crashes — skip to avoid false positives.
      if (error is ClientException ||
          error.toString().contains('Connection closed') ||
          error.toString().contains('Software caused connection abort')) {
        return;
      }
      // A bug in this SDK is not the host app crashing. Every entry point is
      // already guarded; this is the backstop for anything that escapes.
      if (isSdkInternal(stack)) {
        UnilitixLogger.e(
            'Internal SDK error (not recorded as a crash)', error, stack);
        return;
      }
      final stackText = stack?.toString();
      final exType = error.runtimeType.toString();
      final fp = fingerprint(exType, stackText);
      final n = (_seen[fp] ?? 0) + 1;
      _seen[fp] = n;
      if (n > maxPerFingerprint || _reportedThisSession >= maxPerSession) {
        UnilitixLogger.d('Suppressed repeat $type $fp (#$n this session)');
        return;
      }
      _reportedThisSession++;

      UnilitixLogger.e(
          type == EventTypes.crash ? 'Crash captured' : 'Exception captured',
          error,
          stack);
      final raw = '$exType: ${error.toString()}';
      final title = raw.length > 200 ? raw.substring(0, 200) : raw;
      final event = UnilitixEvent(type: type, screen: SdkScope.currentScreen)
        ..fatal = false
        ..title = title
        ..exceptionType = exType
        ..exceptionMessage = error.toString()
        ..stackTrace = stackText
        ..breadcrumbs = List.of(breadcrumbs)
        ..crashMetadata = crashMetadata(fp, n, stackText);
      if (type == EventTypes.crash) {
        onCrashEvent(event);
      } else {
        (onExceptionEvent ?? onCrashEvent)(event);
      }
    } finally {
      _isRecording = false;
    }
  }

  // ── Fingerprinting ────────────────────────────────────────────────────────

  static final _frameRe = RegExp(r'^#\d+\s+(.*)$');
  static final _lineColRe = RegExp(r':\d+(:\d+)?\)');
  static final _obfuscatedRe = RegExp(r'virt\s+([0-9a-f]+)');
  static final _buildIdRe = RegExp(r"build_id:\s*'([0-9a-f]+)'");
  static final _dsoBaseRe = RegExp(r'isolate_dso_base:\s*([0-9a-f]+)');

  /// A stable id for "this bug": the exception type plus the first three
  /// frames with line and column numbers removed, so an edit elsewhere in
  /// the file does not create a new group. For obfuscated release traces the
  /// `virt` offsets stand in for symbols; they are stable within a build, and
  /// the server joins across builds once symbols are uploaded.
  @visibleForTesting
  static String fingerprint(String exceptionType, String? stack) {
    final parts = <String>[exceptionType];
    if (stack != null) {
      var taken = 0;
      for (final line in stack.split('\n')) {
        if (taken == 3) break;
        final m = _frameRe.firstMatch(line.trim());
        if (m == null) continue;
        final frame = m.group(1)!;
        final obf = _obfuscatedRe.firstMatch(frame);
        if (obf != null) {
          parts.add('virt:${obf.group(1)}');
        } else {
          // "Foo.bar (package:app/foo.dart:12:5)" -> "Foo.bar (package:app/foo.dart)"
          final noLine = frame.replaceAll(_lineColRe, ')');
          if (noLine.startsWith('<asynchronous suspension>')) continue;
          parts.add(noLine.replaceAll(RegExp(r'\s+'), ' ').trim());
        }
        taken++;
      }
    }
    return _fnv1a64(parts.join('|'));
  }

  static final _appleFrameRe =
      RegExp(r'^\d+\s+(\S+)\s+0x[0-9a-fA-F]+\s+(.+?)(?:\s+\+\s+(\d+))?$');
  static final _jsFrameRe = RegExp(r'^at\s+(.*?)\s*\((.*?)(?::\d+)+\)$');
  static final _jvmFrameRe = RegExp(r'^at\s+(.*?)\(([^:()]+)(?::\d+)?\)$');
  static final _trailLineRe = RegExp(r':\d+(:\d+)?$');

  /// The SDK contract's crash fingerprint with every platform's frame rules
  /// (the api repo's `internal/sdkcontract/fingerprint.go`): Dart frames as
  /// [fingerprint] does, plus JavaScript, JVM (`at a.B.c(B.kt:12)`), bare
  /// `at` and Apple frames; any other line (an ANR dump's thread header,
  /// `native:` frames, `- locked` lines) is not a frame.
  ///
  /// Used for an Android ANR record that comes without the plugin's
  /// `fingerprint`, so it groups with the Android SDK's ANRs. Dart's own
  /// errors keep [fingerprint], which only counts `#n` frames: for a Dart VM
  /// stack both agree (the contract's Dart vectors pin that), but on the web
  /// `at` lines would start counting and regroup existing issues.
  @visibleForTesting
  static String contractFingerprint(String exceptionType, String? stack) {
    final parts = <String>[exceptionType];
    if (stack != null) {
      var taken = 0;
      for (final line in stack.split('\n')) {
        if (taken == SdkContract.fingerprintFrames) break;
        final frame = normaliseFrame(line);
        if (frame == null) continue;
        parts.add(frame);
        taken++;
      }
    }
    return _fnv1a64(parts.join('|'));
  }

  /// One stack line in its contract fingerprint form, or null when it is not
  /// a frame (`NormaliseFrame` in the api repo; first matching rule wins).
  @visibleForTesting
  static String? normaliseFrame(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return null;
    final apple = _appleFrameRe.firstMatch(line);
    if (apple != null) {
      final image = apple.group(1)!;
      final symbol = apple.group(2)!.trim();
      final offset = apple.group(3);
      if (symbol == image && offset != null && offset.isNotEmpty) {
        return '$image+$offset';
      }
      return '$image $symbol';
    }
    final dart = _frameRe.firstMatch(line);
    if (dart != null) {
      final frame = dart.group(1)!;
      final obf = _obfuscatedRe.firstMatch(frame);
      if (obf != null) return 'virt:${obf.group(1)}';
      final noLine = frame.replaceAll(_lineColRe, ')');
      if (noLine.startsWith('<asynchronous suspension>')) return null;
      return noLine.replaceAll(RegExp(r'\s+'), ' ').trim();
    }
    final js = _jsFrameRe.firstMatch(line);
    if (js != null) return '${js.group(1)} (${js.group(2)})';
    final jvm = _jvmFrameRe.firstMatch(line);
    if (jvm != null) return '${jvm.group(1)}(${jvm.group(2)})';
    if (line.startsWith('at ')) {
      return line.substring(3).replaceAll(_trailLineRe, '').trim();
    }
    return null;
  }

  /// `metadata` block for crash/exception events: grouping key, occurrence
  /// count, and the build identifiers the server needs to symbolicate an
  /// obfuscated trace (`--split-debug-info` builds print them at the top of
  /// every stack trace).
  @visibleForTesting
  static Map<String, dynamic> crashMetadata(
      String fp, int occurrence, String? stack) {
    final m = <String, dynamic>{'fingerprint': fp, 'occurrence': occurrence};
    if (stack != null) {
      final b = _buildIdRe.firstMatch(stack);
      if (b != null) m['buildId'] = b.group(1);
      final d = _dsoBaseRe.firstMatch(stack);
      if (d != null) m['isolateDsoBase'] = d.group(1);
    }
    return m;
  }

  /// Two 32-bit FNV-1a hashes with different seeds, concatenated: 64 bits of
  /// grouping key computed with arithmetic that stays exact on the web too
  /// (JavaScript numbers lose precision above 2^53, so a true 64-bit FNV
  /// would differ between native and web builds of the same app).
  static String _fnv1a64(String s) {
    final bytes = utf8.encode(s);
    final a = _fnv1a32(bytes, 0x811c9dc5);
    final b = _fnv1a32(bytes, 0x811c9dc5 ^ 0x5bd1e995);
    return a.toRadixString(16).padLeft(8, '0') +
        b.toRadixString(16).padLeft(8, '0');
  }

  static int _fnv1a32(List<int> bytes, int seed) {
    const prime = 16777619;
    var h = seed;
    for (final b in bytes) {
      h ^= b;
      // h * prime mod 2^32, in two halves so no intermediate exceeds 2^53.
      h = ((h & 0xFFFF) * prime + ((((h >> 16) * prime) & 0xFFFF) << 16)) &
          0xFFFFFFFF;
    }
    return h;
  }

  /// True when the top of [stack] is inside this package, i.e. the error was
  /// thrown by SDK code rather than by the app.
  @visibleForTesting
  static bool isSdkInternal(StackTrace? stack) {
    if (stack == null) return false;
    final lines = stack.toString().split('\n');
    for (final line in lines.take(3)) {
      if (line.contains('package:unilitix/')) return true;
      if (line.trim().isNotEmpty && line.contains('package:')) return false;
    }
    return false;
  }

  // ── Native crashes ────────────────────────────────────────────────────────

  /// Builds the fatal CRASH event for a native marker written by the plugin,
  /// or null when the marker cannot be parsed. [timestampMs] is the moment
  /// the process died, as the marker recorded it.
  ///
  /// The iOS plugin (UnilitixCore's crash file) adds `fingerprint`, computed
  /// with the SDK contract's frame rules, which group Apple stack frames the
  /// way the native iOS SDK does; it is used as is. Otherwise (Android) the
  /// fingerprint is computed here.
  ///
  /// A record with `"type":"ANR"` (Android plugin 2.6.0+, iOS 2.7.0+)
  /// becomes an `ANR` event instead ([anrEventFromRecord]).
  @visibleForTesting
  static UnilitixEvent? eventFromNativeMarker(String raw,
      {required void Function(int? timestampMs) onTimestamp}) {
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      if (m['type'] == EventTypes.anr) {
        final ts = m['timestamp'];
        onTimestamp(ts is num ? ts.toInt() : null);
        return anrEventFromRecord(m);
      }
      final platform = m['platform'] as String? ?? 'native';
      final exType = (m['exceptionType'] as String?) ?? 'NativeCrash';
      final signal = m['signal'];
      final msg = (m['exceptionMessage'] as String?) ??
          (signal != null ? 'Fatal signal $signal' : 'Native crash');
      final stack = m['stackTrace'] as String?;
      final ts = m['timestamp'];
      onTimestamp(ts is num ? ts.toInt() : null);
      final nativeFp = m['fingerprint'];
      final key = signal != null ? '$exType:$signal' : exType;
      final fp = nativeFp is String && nativeFp.isNotEmpty
          ? nativeFp
          : fingerprint(key, stack);
      final title = '$exType: $msg';
      return UnilitixEvent(type: EventTypes.crash, screen: null)
        ..fatal = true
        ..title = title.length > 200 ? title.substring(0, 200) : title
        ..exceptionType = exType
        ..exceptionMessage = '[$platform] $msg'
        ..stackTrace = stack
        ..crashMetadata = crashMetadata(fp, 1, stack);
    } catch (e) {
      UnilitixLogger.w('Could not parse native crash record: $e');
      return null;
    }
  }

  /// The `ANR` event for an ANR record from the plugin, in the shape the
  /// native Unilitix SDKs send (contract 1.3.0): `exceptionType` `ANR`, the
  /// record's description as `exceptionMessage` (no platform prefix), the
  /// main thread's stack, no `fatal` and no `title`, and `metadata` with the
  /// fingerprint (the plugin's, else [contractFingerprint] of type `ANR`
  /// over the stack) and `platform`.
  ///
  /// Android records add `importance` / `foreground` when the system
  /// recorded the importance. iOS app-hang records (2.7.0) carry their own
  /// `metadata` (`hangDurationMs`, `appHangTimeoutMs`, `appTerminated`,
  /// `debugImages` for symbolication), which is passed through; their `id`
  /// becomes the event id and their `timestamp` (when the hang began) the
  /// event time, as the native iOS SDK does.
  @visibleForTesting
  static UnilitixEvent anrEventFromRecord(Map<String, dynamic> m,
      {String? screen, List<Map<String, dynamic>>? breadcrumbs}) {
    final message = m['exceptionMessage'];
    final stack = m['stackTrace'] is String ? m['stackTrace'] as String : '';
    final nativeFp = m['fingerprint'];
    final platform = m['platform'] is String ? m['platform'] : 'android';
    final metadata = <String, dynamic>{};
    final extra = m['metadata'];
    if (extra is Map) {
      for (final entry in extra.entries) {
        if (entry.key is String) metadata[entry.key as String] = entry.value;
      }
    }
    metadata['fingerprint'] = nativeFp is String && nativeFp.isNotEmpty
        ? nativeFp
        : contractFingerprint(EventTypes.anr, stack);
    metadata['platform'] = platform;
    final importance = m['importance'];
    if (importance is num) metadata['importance'] = importance.toInt();
    final foreground = m['foreground'];
    if (foreground is bool) metadata['foreground'] = foreground;
    final id = m['id'];
    final ts = m['timestamp'];
    final ios = platform == 'ios';
    return UnilitixEvent(
      type: EventTypes.anr,
      screen: screen,
      id: ios && id is String && _uuidRe.hasMatch(id) ? id : null,
      timestamp: ios && ts is num && ts > 0 ? ts.toInt() : null,
    )
      ..exceptionType = EventTypes.anr
      ..exceptionMessage = message is String && message.isNotEmpty
          ? message
          : 'Application Not Responding'
      ..stackTrace = stack
      ..breadcrumbs = breadcrumbs ?? []
      ..crashMetadata = metadata;
  }

  /// Most native records read per launch. The Android plugin returns at
  /// most 16 (a JVM crash, 5 signal records, 5 exit-info crashes, 5 ANRs;
  /// signal records are API 21-29, exit info API 30+, so 11 in practice);
  /// the cap only guards against a plugin that never returns null.
  static const maxNativeCrashesPerLaunch = 16;

  /// Reads the next crash record the native plugin kept from an earlier
  /// process, or null when there is none (or no native hook: web, desktop).
  /// iOS returns at most a crash and an app hang per launch, Android one
  /// per earlier crash, oldest first; each is returned once.
  Future<String?> _readNativeCrash() async {
    try {
      final raw = await _sdkChannel.invokeMethod<String>('readNativeCrash');
      return raw == null || raw.isEmpty ? null : raw;
    } catch (_) {
      // Platform without the native hook (web, desktop, old plugin).
      return null;
    }
  }

  /// Reads every crash recorded by the native plugin in earlier processes and
  /// reports each as a fatal CRASH (an ANR record as an `ANR` event) against
  /// the session that was running when its process died ([attribute] maps
  /// the marker's timestamp to that session's id from the pending stubs;
  /// null means "no match"). An event is handed to [report] with the
  /// resolved session id, or to [onCrashEvent] for the current session when
  /// there is no match (an ANR to [onAnrEvent]). Returns true when a record
  /// was found.
  Future<bool> reportNativeCrashIfAny({
    Future<CrashAttribution> Function(int? timestampMs)? attribute,
    Future<void> Function(String sessionId, UnilitixEvent event)? report,
  }) async {
    var found = false;
    for (var i = 0; i < maxNativeCrashesPerLaunch; i++) {
      final raw = await _readNativeCrash();
      if (raw == null) break;
      int? ts;
      final event = eventFromNativeMarker(raw, onTimestamp: (t) => ts = t);
      if (event == null) continue;
      found = true;

      String? sessionId;
      if (attribute != null) {
        try {
          sessionId = (await attribute(ts)).sessionId;
        } catch (e) {
          UnilitixLogger.w('Native crash attribution failed: $e');
        }
      }
      final what = event.type == EventTypes.anr ? 'ANR' : 'native crash';
      if (sessionId != null && report != null) {
        await report(sessionId, event);
        UnilitixLogger.d('Reported $what from previous launch '
            'against session $sessionId');
      } else {
        if (event.type == EventTypes.anr) {
          (onAnrEvent ?? onExceptionEvent ?? onCrashEvent)(event);
        } else {
          onCrashEvent(event);
        }
        UnilitixLogger.d('Reported $what from previous launch '
            '(no matching session; attributed to the current one)');
      }
    }
    return found;
  }

  /// Consent denied: reads and drops the native plugin's crash and ANR
  /// records, so one from a denied period is never reported after a later
  /// grant (and Android's exit-info watermark still moves). Returns how
  /// many there were.
  Future<int> discardNativeCrashes() async {
    var dropped = 0;
    for (var i = 0; i < maxNativeCrashesPerLaunch; i++) {
      if (await _readNativeCrash() == null) break;
      dropped++;
    }
    if (dropped > 0) {
      UnilitixLogger.d('Dropped $dropped native crash record(s) from an '
          'earlier launch (consent denied)');
    }
    return dropped;
  }

  /// On next launch, logs any crash batches persisted from the previous session.
  /// Actual retry is handled automatically by FlushScheduler on the next flush.
  Future<void> logPendingCrashesIfAny() async {
    try {
      final rows = await database.getOldestEvents(10);
      final crashBatches = rows.where((r) {
        try {
          final events = jsonDecode(r.eventsJson) as List;
          return events.any((e) => (e as Map)['type'] == 'CRASH');
        } catch (_) {
          return false;
        }
      }).toList();
      if (crashBatches.isNotEmpty) {
        UnilitixLogger.d(
            'Recovered ${crashBatches.length} pending crash batch(es) from DB');
      }
    } catch (e) {
      UnilitixLogger.e('logPendingCrashesIfAny failed', e);
    }
  }
}
