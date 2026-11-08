/// Unilitix Flutter SDK — mobile UX analytics for African apps.
///
/// Since 3.0.0 this package is a thin wrapper over the native Unilitix SDKs
/// (Android `com.unilitix:unilitix-android`, iOS UnilitixCore): sessions,
/// identity, consent, the offline queue, uploads and retries, device and
/// network context, and native crashes, ANRs and app hangs are theirs, so
/// a Flutter app behaves exactly like a native one. Dart keeps what only
/// Dart can see: Dart and Flutter errors, the route names of the
/// [Navigator], and masked session replay of the widget tree.
///
/// ## Setup
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Unilitix.init('YOUR_API_KEY');
///   Unilitix.runApp(MyApp());
/// }
///
/// class MyApp extends StatelessWidget {
///   Widget build(BuildContext context) => MaterialApp(
///     navigatorObservers: [Unilitix.observer],
///     builder: (context, child) => UnilitixWidget(child: child!),
///   );
/// }
/// ```
library unilitix;

import 'dart:async' show unawaited;
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/widgets.dart';

import 'src/capture/screenshot_capture.dart';
import 'src/capture/snapshot_capture.dart';
import 'src/config.dart';
import 'src/consent.dart';
import 'src/core/init_guard.dart';
import 'src/core/legacy_migration.dart';
import 'src/core/native_bridge.dart';
import 'src/core/sdk_scope.dart';
import 'src/core/version.dart';
import 'src/crash/crash_tracker.dart';
import 'src/logger/logger.dart';
import 'src/power/install_id.dart';
import 'src/power/power_contribution.dart';
import 'src/power/power_transport.dart';
import 'src/privacy/privacy_mask.dart';
import 'src/tracking/observer.dart';
import 'src/tracking/rage_tap_detector.dart';

export 'src/config.dart';
export 'src/consent.dart' show UnilitixConsent;
export 'src/tracking/observer.dart';
export 'src/tracking/gesture_tracker.dart';
export 'src/tracking/unilitix_widget.dart';
export 'src/privacy/privacy_mask.dart';

// Top-level alias so Unilitix.runApp can call Flutter's runApp without
// triggering Dart's static-scope resolution, which would make the bare
// identifier `runApp` inside class Unilitix resolve to the static method
// itself and recurse infinitely.
void _flutterRunApp(Widget app) => runApp(app);

/// The method channel arguments of the native `init` for [config].
///
/// Option keys are the SDK contract's canonical keys; each plugin maps them
/// to its native config (`replaySampleRate` is `sampleRate` on Android,
/// `maskScreenshots` is the contract's `maskInputsInScreenshots`). The
/// wrapper identity goes to the native `setWrapper` before its `init`.
@visibleForTesting
Map<String, Object?> nativeInitArguments(
    UnilitixConfig config, UnilitixConsent consent) {
  return {
    'apiKey': config.apiKey,
    'consent': consent.name,
    'wrapperName': kUnilitixWrapperName,
    'wrapperVersion': kUnilitixSdkVersion,
    'config': <String, Object?>{
      'apiUrl': config.apiUrl,
      'debug': config.debug,
      'autoTrackTaps': config.autoTrackTaps,
      'autoTrackRageTaps': config.autoTrackRageTaps,
      'autoTrackCrashes': config.autoTrackCrashes,
      'appHangTimeoutMs': config.appHangTimeoutMs,
      'flushIntervalSeconds': config.flushIntervalSeconds,
      'flushBatchSize': config.flushBatchSize,
      'maxOfflineEvents': config.maxOfflineEvents,
      'sessionTimeoutSeconds': config.sessionTimeoutSeconds,
      'maskInputs': config.maskInputs,
      'maskAllText': config.maskAllText,
      'maskImages': config.maskImages,
      'maskInputsInScreenshots': config.maskScreenshots,
      'replaySampleRate': config.replaySampleRate,
      'captureSnapshots': config.captureSnapshots,
      'snapshotIntervalMs': config.snapshotIntervalMs,
      'maxSnapshotsPerSession': config.maxSnapshotsPerSession,
      'captureScreenshots': config.captureScreenshots,
      'screenshotIntervalMs': config.screenshotIntervalMs,
      'screenshotQuality': config.screenshotQuality,
      'screenshotMaxWidth': config.screenshotMaxWidth,
      'uploadScreenshotsOnWifiOnly': config.uploadScreenshotsOnWifiOnly,
      'maxScreenshotsPerSession': config.maxScreenshotsPerSession,
      'maxScreenshotsPerMinute': config.maxScreenshotsPerMinute,
      'screenshotHeartbeatMs': config.screenshotHeartbeatMs,
    },
  };
}

/// Refreshes the replay state when the app comes back to the foreground:
/// the native SDK may have started a new session (timeout) with a new
/// sampling decision.
class _Lifecycle with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(Unilitix._refreshReplayState());
    }
  }
}

/// The Unilitix SDK entry point.
///
/// Initialize once in `main()` before `runApp()`. Every method is safe to
/// call at any time: calls made before [init] completes are kept (at most
/// 200, the oldest dropped) and sent in order once it has.
class Unilitix {
  Unilitix._();

  static UnilitixConfig? _config;
  static bool _initialized = false;
  static bool _observerConnected = false;

  static NativeBridge _bridge = NativeBridge();
  static InitGuard _initGuard = _newInitGuard();

  /// Consent as last decided: the native SDK's answer at init, then every
  /// [setConsent].
  static UnilitixConsent? _consent;

  /// A [setConsent] made before init completed; wins over init's answer
  /// (the call itself is sent to the native SDK right after its init).
  static UnilitixConsent? _earlyConsent;

  static String? _sessionId;
  static bool _replaySampled = false;

  /// The plugin asks Dart to report taps (Android: the native tap tracker
  /// would name every Flutter screen after the Activity). On iOS the native
  /// SDK records taps itself, on the route names Dart sends with [screen].
  static bool _dartTaps = false;

  static final CrashTracker _errors = CrashTracker(onReport: _sendError);
  static RageTapDetector? _rage;
  static SnapshotCapture? _snapshots;
  static ScreenshotCapture? _screenshots;
  static PowerContribution? _power;
  static _Lifecycle? _lifecycle;

  static final UnilitixObserver _observer = UnilitixObserver();

  /// The navigator observer for screen tracking.
  /// Add to [MaterialApp.navigatorObservers].
  ///
  /// ```dart
  /// MaterialApp(navigatorObservers: [Unilitix.observer])
  /// ```
  static UnilitixObserver get observer {
    _wireScope();
    return _observer;
  }

  /// Whether [init] has completed successfully.
  static bool get isInitialized => _initialized;

  /// The current SDK configuration.
  static UnilitixConfig? get config => _config;

  static InitGuard _newInitGuard() => InitGuard(onError: (e, st) {
        UnilitixLogger.e(
            'Unilitix.init() failed — the SDK is disabled for this '
            'run of the app',
            e,
            st);
        _teardown();
      });

  /// Connects the observer and the widget wrappers to the SDK. Done as soon
  /// as either is used, so a route pushed before [init] completes is not
  /// lost (it is buffered with the other early calls).
  static void _wireScope() {
    SdkScope.onScreenChange ??= _onScreenChange;
    SdkScope.onTap ??= _onTap;
    SdkScope.onObserverConnected ??= () => _observerConnected = true;
  }

  // ── Init ──────────────────────────────────────────────────────────

  /// Initializes the Unilitix SDK. Call once in [main] before [runApp].
  ///
  /// Starts the native SDK (`setWrapper('flutter', …)` first, then its
  /// `init` with [config]), sends the calls made before it, installs the
  /// Dart error hooks and starts session replay capture.
  ///
  /// Calling [init] more than once is a no-op — the first API key and config
  /// win. Calls made while the first is still running wait for it. [init]
  /// never throws: if the native SDK cannot start, the error is logged in
  /// debug and every call is ignored for this run of the app.
  ///
  /// [consent] is used only when the user has not decided yet on this
  /// device: a decision persisted by [setConsent] on an earlier launch wins.
  ///
  /// ```dart
  /// await Unilitix.init('your_api_key', consent: UnilitixConsent.pending);
  /// // ...after the user accepts:
  /// await Unilitix.setConsent(UnilitixConsent.granted);
  /// ```
  static Future<void> init(
    String apiKey, {
    UnilitixConfig? config,
    UnilitixConsent consent = UnilitixConsent.granted,
  }) {
    if (_initGuard.started) {
      UnilitixLogger.w(
        'Unilitix.init() called more than once — ignoring. '
        'The first API key and config are used.',
      );
    }
    return _initGuard.run(() => _init(apiKey, config, consent));
  }

  static Future<void> _init(
    String apiKey,
    UnilitixConfig? config,
    UnilitixConsent consent,
  ) async {
    final cfg =
        config?.copyWith(apiKey: apiKey) ?? UnilitixConfig(apiKey: apiKey);
    _config = cfg;
    UnilitixLogger.enabled = cfg.debug;
    _wireScope();

    if (kIsWeb) {
      // No native SDK in a browser: 3.0.0 does not support the web.
      debugPrint('[Unilitix] The web is not supported since 3.0.0; '
          'the SDK does nothing in this app.');
      _bridge.disable();
      return;
    }

    // A decision 2.x stored in Dart is handed over once (see LegacyConsent).
    final legacy = await LegacyConsent.read();
    final answer = await _bridge.start(
      nativeInitArguments(cfg, legacy ?? consent),
      first: [
        if (legacy != null)
          PendingNativeCall('setConsent', {'consent': legacy.name}),
      ],
    );
    _applyNativeState(answer, initial: legacy ?? consent);
    if (legacy != null) {
      // The setConsent sent first makes it the native state too.
      _consent = _earlyConsent ?? legacy;
      unawaited(LegacyConsent.clear());
    }
    _dartTaps = answer?['dartTaps'] == true;

    if (cfg.autoTrackCrashes) _errors.install();
    if (cfg.autoTrackRageTaps) {
      _rage = RageTapDetector(onRageTap: (screen, x, y, cx, cy) {
        final hidden = _insidePrivateArea(cx, cy);
        _bridge.send('recordTap', {
          'type': 'RAGE_TAP',
          'screen': screen,
          'x': hidden ? null : cx,
          'y': hidden ? null : cy,
        });
      });
    }
    if (cfg.captureScreenshots) {
      _screenshots = ScreenshotCapture(
        bridge: _bridge,
        intervalMs: cfg.screenshotIntervalMs,
        maxScreenshots: cfg.maxScreenshotsPerSession,
        maxWidth: cfg.screenshotMaxWidth,
        quality: cfg.screenshotQuality,
        maskScreenshots: cfg.maskScreenshots,
        maskImages: cfg.maskImages,
        maskInputs: cfg.maskInputs,
        maskAllText: cfg.maskAllText,
        maxPerMinute: cfg.maxScreenshotsPerMinute,
        heartbeatMs: cfg.screenshotHeartbeatMs,
      );
    }
    if (cfg.captureSnapshots) {
      _snapshots = SnapshotCapture(
        onSnapshot: _sendSnapshot,
        intervalMs: cfg.snapshotIntervalMs,
        maskInputs: cfg.maskInputs,
        maskAllText: cfg.maskAllText,
        maskImages: cfg.maskImages,
      )..onChanged = () => _screenshots?.markDirty();
    }
    _lifecycle = _Lifecycle();
    WidgetsBinding.instance.addObserver(_lifecycle!);

    // Power-outage contribution is Flutter-only (the native cores do not
    // have it); it does nothing unless the app opted in.
    _power = PowerContribution(
      optedIn: cfg.powerOutageContribution,
      consent: () => _consent ?? UnilitixConsent.granted,
      installId: await powerInstallId(),
      apiKey: cfg.apiKey,
      apiUrl: cfg.apiUrl,
      sdkVersion: kUnilitixSdkVersion,
      post: PowerTransport(
        apiKey: cfg.apiKey,
        apiUrl: cfg.apiUrl,
        sdkVersion: kUnilitixSdkVersion,
      ).post,
    );

    _initialized = true;
    final early = _earlyConsent;
    if (early != null) {
      _consent = early;
      _earlyConsent = null;
    }
    _updateReplayCapture();
    unawaited(_power!.start());

    if (cfg.debug) {
      UnilitixLogger.d('SDK initialized  ✅  v$kUnilitixSdkVersion (native '
          'session ${_shortId(_sessionId)}, consent ${consent.name})');
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_observerConnected) {
          UnilitixLogger.w('Observer not connected — add Unilitix.observer '
              'to MaterialApp.navigatorObservers');
        }
      });
    }
  }

  static String _shortId(String? id) =>
      id == null ? '—' : (id.length > 8 ? '${id.substring(0, 8)}…' : id);

  /// Reads `{consent, sessionId, replaySampled}` from the native answer.
  static void _applyNativeState(Map<Object?, Object?>? m,
      {UnilitixConsent? initial}) {
    _consent = _earlyConsent ??
        consentFromWireName(m?['consent']) ??
        _consent ??
        initial;
    final sid = m?['sessionId'];
    final newSession = sid is String && sid != _sessionId;
    if (sid is String || m?.containsKey('sessionId') == true) {
      _sessionId = sid is String ? sid : null;
    }
    _replaySampled = m?['replaySampled'] == true;
    if (newSession) {
      _errors.resetSession();
      _screenshots?.resetSession();
      _snapshots?.resetSession();
    }
  }

  /// Asks the native SDK for the current session and its replay sampling
  /// decision, and starts or stops replay capture to match.
  static Future<void> _refreshReplayState() async {
    if (!_initialized) return;
    final m = await _bridge.query<Map<Object?, Object?>>('replayState');
    if (m == null || !_initialized) return;
    _applyNativeState(m);
    _updateReplayCapture();
  }

  static void _updateReplayCapture() {
    final allowed = _initialized &&
        _replaySampled &&
        (_consent ?? UnilitixConsent.granted) != UnilitixConsent.denied;
    if (allowed) {
      _snapshots?.start();
      _screenshots?.start();
    } else {
      _snapshots?.stop();
      _screenshots?.stop();
    }
  }

  static void _teardown() {
    _initialized = false;
    _bridge.disable();
    _errors.uninstall();
    _snapshots?.stop();
    _screenshots?.stop();
    final l = _lifecycle;
    if (l != null) WidgetsBinding.instance.removeObserver(l);
    _lifecycle = null;
  }

  /// Starts the app. Same as Flutter's [runApp]; kept so 2.x apps compile.
  ///
  /// Dart errors are captured by `FlutterError.onError` and
  /// `PlatformDispatcher.onError`, installed by [init]; no zone is created
  /// (a zone made after `WidgetsFlutterBinding.ensureInitialized()` would
  /// trigger Flutter's "Zone mismatch" assertion).
  static void runApp(Widget app) => _flutterRunApp(app);

  // ── Tracking ──────────────────────────────────────────────────────

  /// Tracks a custom event (`CUSTOM`, `metadata.name` = [event]).
  ///
  /// ```dart
  /// Unilitix.track('button_tapped', {'screen': 'home'});
  /// ```
  static Future<void> track(
    String event, [
    Map<String, dynamic>? properties,
  ]) async {
    _bridge.send('track', {
      'name': event,
      'properties': codecSafe(properties ?? const <String, dynamic>{}),
    });
  }

  /// Identifies the current user with optional traits.
  ///
  /// ```dart
  /// Unilitix.identify('user_123', {'plan': 'pro'});
  /// ```
  static Future<void> identify(
    String userId, [
    Map<String, dynamic>? traits,
  ]) async {
    _bridge.send('identify', {
      'userId': userId,
      'traits': codecSafe(traits ?? const <String, dynamic>{}),
    });
  }

  /// Manually tracks a screen view (`NAVIGATE`). Use when
  /// [Unilitix.observer] cannot see the navigation. A repeat of the current
  /// screen is dropped by the native SDK.
  static Future<void> screen(String screenName) async {
    _onScreenChange(screenName);
  }

  /// Records an error the app caught itself, as a non-fatal `EXCEPTION`
  /// (or a `CRASH` when [fatal] is true). Also the handler to use with
  /// `runZonedGuarded`:
  ///
  /// ```dart
  /// try {
  ///   await payments.charge(card);
  /// } catch (e, st) {
  ///   Unilitix.captureException(e, stackTrace: st);
  /// }
  /// ```
  static void captureException(
    Object error, {
    StackTrace? stackTrace,
    bool fatal = false,
  }) {
    _errors.capture(error, stackTrace ?? StackTrace.current, fatal: fatal);
  }

  /// Records an error described by its parts, for errors that are not Dart
  /// objects (a message from a WebView, an error from another runtime): an
  /// `EXCEPTION`, or a `CRASH` when [fatal] is true, with the contract
  /// fingerprint of [type] and [stackTrace].
  static void recordException(
    String type,
    String message, {
    String? stackTrace,
    bool fatal = false,
  }) {
    _sendError(
        CrashTracker.buildReport(type, message, stackTrace, fatal: fatal));
  }

  static void _sendError(DartErrorReport report) {
    _bridge.send('recordError', report.toChannelArguments());
  }

  /// Adds a breadcrumb to the trail attached to the next crash or exception
  /// report (the native SDK keeps the last 50). Use it for app state that
  /// explains a crash — "payment started", "token refreshed" — never for
  /// personal data. [data] is appended to the message as JSON.
  static void addBreadcrumb(
    String message, {
    String? category,
    Map<String, dynamic>? data,
  }) {
    var text = message;
    if (data != null && data.isNotEmpty) {
      try {
        text = '$message ${jsonEncode(codecSafe(data))}';
      } catch (_) {}
    }
    _bridge.send(
        'addBreadcrumb', {'message': text, 'category': category ?? 'custom'});
  }

  // ── Session ───────────────────────────────────────────────────────

  /// Manually starts a new session.
  static Future<void> startSession() async {
    _bridge.send('startSession');
    unawaited(_refreshReplayState());
  }

  /// Manually ends the current session.
  static Future<void> endSession() async {
    _bridge.send('endSession');
    unawaited(_refreshReplayState());
  }

  // ── Privacy ───────────────────────────────────────────────────────

  /// The current consent state, as last decided: the native SDK's state at
  /// [init] (a persisted decision, else the `consent` passed to [init]),
  /// then every [setConsent]. Before [init]: the decision passed to
  /// [setConsent] early, if any, else [UnilitixConsent.granted].
  static UnilitixConsent get consent =>
      _earlyConsent ?? _consent ?? UnilitixConsent.granted;

  /// Records the user's consent decision; the native SDK persists it and
  /// acts on it immediately:
  ///
  /// * [UnilitixConsent.granted]: uploads resume; everything held while
  ///   pending is sent.
  /// * [UnilitixConsent.pending]: capture continues, uploads stop.
  /// * [UnilitixConsent.denied]: capture stops and everything queued on the
  ///   device is deleted. Same as [optOut].
  ///
  /// May be called before [init]: it is sent right after the native SDK
  /// starts, before any later call.
  static Future<void> setConsent(UnilitixConsent value) async {
    _earlyConsent = _initialized ? null : value;
    _consent = value;
    _bridge.send('setConsent', {'consent': value.name});
    if (_initialized) {
      _updateReplayCapture();
      unawaited(_power?.onConsentChanged());
      unawaited(_refreshReplayState());
    }
  }

  /// Stops all tracking and deletes queued data. Same as
  /// `setConsent(UnilitixConsent.denied)`.
  static Future<void> optOut() => setConsent(UnilitixConsent.denied);

  /// Resumes tracking after [optOut]. Same as
  /// `setConsent(UnilitixConsent.granted)`.
  static Future<void> optIn() => setConsent(UnilitixConsent.granted);

  /// Forgets the user (call on logout): new anonymous id, no user id, new
  /// session.
  static Future<void> reset() async {
    _bridge.send('reset');
    unawaited(_refreshReplayState());
  }

  // ── Flush ─────────────────────────────────────────────────────────

  /// Asks the native SDK to upload what is queued now (subject to consent,
  /// backoff and connectivity).
  static Future<void> flush() async {
    _bridge.send('flush');
  }

  // ── Internal ──────────────────────────────────────────────────────

  static void _onScreenChange(String name) {
    SdkScope.currentScreen = name;
    _screenshots?.markDirty();
    _bridge.send('screen', {'name': name});
  }

  static void _onTap(String screen, double x, double y) {
    _screenshots?.markDirty();
    final cfg = _config;
    if (!_initialized || !_dartTaps || cfg == null || !cfg.autoTrackTaps) {
      return;
    }
    if (_rage?.recordTap(screen, x, y) == true) return; // sent as RAGE_TAP
    // A tap inside a UnilitixPrivate area is recorded without its position:
    // on a PIN pad or card form the coordinates are the secret.
    final hidden = _insidePrivateArea(x, y);
    _bridge.send('recordTap', {
      'type': 'TAP',
      'screen': screen,
      'x': hidden ? null : x,
      'y': hidden ? null : y,
    });
  }

  /// Whether the global logical point ([x], [y]) is inside a mounted
  /// [UnilitixPrivate] subtree.
  static bool _insidePrivateArea(double x, double y) {
    if (PrivacyRegistry.mountedCount == 0) return false;
    final p = Offset(x, y);
    for (final r in PrivacyRegistry.privateRects()) {
      if (r.contains(p)) return true;
    }
    return false;
  }

  static void _sendSnapshot(Map<String, dynamic> snapshot, int approxBytes) {
    try {
      _bridge.send('addSnapshot', {'json': jsonEncode(snapshot)});
    } catch (e) {
      UnilitixLogger.w('Snapshot not sent: $e');
    }
  }

  // ── Testing ───────────────────────────────────────────────────────

  /// The native bridge; for tests.
  @visibleForTesting
  static NativeBridge get debugBridge => _bridge;

  /// The screenshot capturer, when screenshots are on; for tests.
  @visibleForTesting
  static ScreenshotCapture? get debugScreenshots => _screenshots;

  /// The snapshot capturer, when snapshots are on; for tests.
  @visibleForTesting
  static SnapshotCapture? get debugSnapshots => _snapshots;

  /// Asks the native SDK for the replay state now; for tests.
  @visibleForTesting
  static Future<void> debugRefreshReplayState() => _refreshReplayState();

  /// Drops every piece of SDK state, as if the process restarted; for
  /// tests. The next [init] starts from scratch.
  @visibleForTesting
  static void debugReset() {
    _teardown();
    _config = null;
    _observerConnected = false;
    _bridge = NativeBridge();
    _initGuard = _newInitGuard();
    _consent = null;
    _earlyConsent = null;
    _sessionId = null;
    _replaySampled = false;
    _dartTaps = false;
    _errors.resetSession();
    _rage = null;
    _snapshots = null;
    _screenshots = null;
    _power = null;
    UnilitixLogger.enabled = false;
    SdkScope.reset();
  }
}
