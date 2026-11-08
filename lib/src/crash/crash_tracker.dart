import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;

import '../generated/sdk_contract.dart';
import '../logger/logger.dart';

/// A Dart error ready for the native SDK's `recordExternalError`.
@immutable
class DartErrorReport {
  const DartErrorReport({
    required this.type,
    required this.message,
    required this.stackTrace,
    required this.fatal,
    required this.fingerprint,
    required this.metadata,
  });

  /// `exceptionType`: the error's runtime type (or the reported type).
  final String type;

  /// `exceptionMessage`.
  final String message;

  /// The stack as printed by the Dart VM, or null.
  final String? stackTrace;

  /// true: `CRASH` (marks the session crashed); false: `EXCEPTION`.
  final bool fatal;

  /// The contract fingerprint (`metadata.fingerprint`).
  final String fingerprint;

  /// Extra `metadata` for symbolication of `--split-debug-info` builds
  /// (`buildId`, `isolateDsoBase`); may be empty.
  final Map<String, Object?> metadata;

  /// The platform name sent with every Dart error.
  static const String platform = 'dart';

  /// The method channel arguments of `recordError` (see the plugins).
  Map<String, Object?> toChannelArguments() => {
        'type': type,
        'message': message,
        'stackTrace': stackTrace,
        'fatal': fatal,
        'platform': platform,
        'fingerprint': fingerprint,
        'metadata': metadata,
      };
}

/// Captures what only Dart can see: errors in Dart code and the Flutter
/// framework. Native crashes (JVM, NDK signals, NSException, Mach/POSIX
/// signals), ANRs and iOS app hangs are the native SDK's since 3.0.0.
///
///  * `FlutterError.onError` — build/layout/paint errors the framework
///    caught. The app keeps running: `EXCEPTION` (fatal false).
///  * `PlatformDispatcher.onError` — an uncaught Dart error (also what a
///    zone without its own handler forwards): `CRASH` (fatal true; it marks
///    the session crashed).
///  * [capture] — errors the app caught itself (`Unilitix.captureException`)
///    or got from a `runZonedGuarded` handler.
///
/// Both hooks chain to whatever was installed before: the previous
/// `FlutterError.onError` still runs, and the previous
/// `PlatformDispatcher.onError` still decides whether the error is handled.
///
/// The per-fingerprint and per-session caps are the native SDK's; the hooks
/// only drop repeats of one fingerprint beyond
/// [SdkContract.maxReportsPerFingerprint] until [resetSession], so a build
/// error that fires every frame does not cross the platform channel sixty
/// times a second.
class CrashTracker {
  CrashTracker({required this.onReport});

  /// Receives every report that passed the filters.
  final void Function(DartErrorReport report) onReport;

  FlutterExceptionHandler? _previousFlutterHandler;
  bool Function(Object error, StackTrace stack)? _previousPlatformHandler;
  bool _installed = false;
  bool _isRecording = false;
  final Map<String, int> _seen = {};

  /// Whether the hooks are installed.
  bool get installed => _installed;

  /// Installs the hooks, chaining to the handlers already in place.
  void install() {
    if (_installed) return;
    _installed = true;
    _previousFlutterHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      _record(details.exception, details.stack, fatal: false, automatic: true);
      _previousFlutterHandler?.call(details);
    };

    _previousPlatformHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error, stack, fatal: true, automatic: true);
      final previous = _previousPlatformHandler;
      if (previous != null) {
        try {
          return previous(error, stack);
        } catch (_) {
          // A throwing upstream handler must not hide the original error.
        }
      }
      // Debug: false, so Flutter prints the error as usual. Release: true,
      // so it is not re-thrown.
      return !kDebugMode;
    };
  }

  /// Restores the handlers that were in place before [install].
  void uninstall() {
    if (!_installed) return;
    _installed = false;
    FlutterError.onError = _previousFlutterHandler;
    PlatformDispatcher.instance.onError = _previousPlatformHandler;
    _previousFlutterHandler = null;
    _previousPlatformHandler = null;
  }

  /// A new native session started: repeats count from zero again.
  void resetSession() => _seen.clear();

  /// An error the app caught itself; never filtered by the repeat guard
  /// (the native caps apply).
  void capture(Object error, StackTrace? stack, {bool fatal = false}) {
    _record(error, stack, fatal: fatal, automatic: false);
  }

  void _record(Object error, StackTrace? stack,
      {required bool fatal, required bool automatic}) {
    if (_isRecording) return;
    _isRecording = true;
    try {
      // Network errors are not crashes — skip to avoid false positives.
      if (error is ClientException ||
          error.toString().contains('Connection closed') ||
          error.toString().contains('Software caused connection abort')) {
        return;
      }
      // A bug in this SDK is not the host app crashing. (Not for explicit
      // captures: their default stack starts in Unilitix.captureException.)
      if (automatic && isSdkInternal(stack)) {
        UnilitixLogger.e(
            'Internal SDK error (not recorded as a crash)', error, stack);
        return;
      }
      final report = buildReport(
          error.runtimeType.toString(), error.toString(), stack?.toString(),
          fatal: fatal);
      if (automatic) {
        final n = (_seen[report.fingerprint] ?? 0) + 1;
        _seen[report.fingerprint] = n;
        if (n > SdkContract.maxReportsPerFingerprint) return;
      }
      UnilitixLogger.e(fatal ? 'Crash captured' : 'Exception captured', error,
          automatic ? stack : null);
      onReport(report);
    } catch (e) {
      UnilitixLogger.w('Could not record error: $e');
    } finally {
      _isRecording = false;
    }
  }

  /// The report for an error of [type] with [message] and [stack].
  static DartErrorReport buildReport(String type, String message, String? stack,
          {required bool fatal}) =>
      DartErrorReport(
        type: type,
        message: message,
        stackTrace: stack,
        fatal: fatal,
        fingerprint: contractFingerprint(type, stack),
        metadata: symbolicationMetadata(stack),
      );

  // ── Fingerprinting ────────────────────────────────────────────────────────

  static final _frameRe = RegExp(r'^#\d+\s+(.*)$');
  static final _lineColRe = RegExp(r':\d+(:\d+)?\)');
  static final _obfuscatedRe = RegExp(r'virt\s+([0-9a-f]+)');
  static final _buildIdRe = RegExp(r"build_id:\s*'([0-9a-f]+)'");
  static final _dsoBaseRe = RegExp(r'isolate_dso_base:\s*([0-9a-f]+)');
  static final _whitespaceRe = RegExp(r'\s+');

  /// The Dart-only rule set (2.x): the exception type plus the first three
  /// `#n` frames with line and column numbers removed; `virt` offsets for
  /// obfuscated release traces. For a Dart VM stack it equals
  /// [contractFingerprint] (the contract's Dart vectors pin that).
  @visibleForTesting
  static String fingerprint(String exceptionType, String? stack) {
    final parts = <String>[exceptionType];
    if (stack != null) {
      var taken = 0;
      for (final line in stack.split('\n')) {
        if (taken == SdkContract.fingerprintFrames) break;
        final m = _frameRe.firstMatch(line.trim());
        if (m == null) continue;
        final frame = m.group(1)!;
        final obf = _obfuscatedRe.firstMatch(frame);
        if (obf != null) {
          parts.add('virt:${obf.group(1)}');
        } else {
          final noLine = frame.replaceAll(_lineColRe, ')');
          if (noLine.startsWith('<asynchronous suspension>')) continue;
          parts.add(noLine.replaceAll(_whitespaceRe, ' ').trim());
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
  /// (the api repo's `internal/sdkcontract/fingerprint.go`): Dart, JavaScript,
  /// JVM and Apple frames. Sent with every Dart error, so a stack reported
  /// through `Unilitix.recordException` from another runtime groups the way
  /// the native SDKs group it.
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

  /// One stack line in its contract form, or null when it is not a frame
  /// (`NormaliseFrame` in the api repo; first matching rule wins).
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
      return noLine.replaceAll(_whitespaceRe, ' ').trim();
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

  /// The build identifiers the server needs to symbolicate an obfuscated
  /// trace (`--split-debug-info` builds print them at the top of every
  /// stack trace). Empty for a symbolized trace.
  static Map<String, Object?> symbolicationMetadata(String? stack) {
    final m = <String, Object?>{};
    if (stack != null) {
      final b = _buildIdRe.firstMatch(stack);
      if (b != null) m['buildId'] = b.group(1);
      final d = _dsoBaseRe.firstMatch(stack);
      if (d != null) m['isolateDsoBase'] = d.group(1);
    }
    return m;
  }

  /// Two 32-bit FNV-1a hashes with different seeds, concatenated: 64 bits of
  /// grouping key computed with arithmetic that stays exact on the web too.
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
}
