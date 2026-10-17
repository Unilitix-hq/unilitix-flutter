/// Unilitix Flutter SDK — mobile UX analytics for African apps.
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

import 'dart:async' show Timer, unawaited;
import 'dart:convert' show jsonDecode, jsonEncode;
import 'dart:math' show Random;

import 'package:flutter/widgets.dart';

import 'src/africa/africa_context.dart';
import 'src/config.dart';
import 'src/core/sdk_scope.dart';
import 'src/events/event.dart';
import 'src/events/event_buffer.dart';
import 'src/session/session_manager.dart';
import 'src/tracking/observer.dart';
import 'src/tracking/rage_tap_detector.dart';
import 'src/capture/snapshot_buffer.dart';
import 'src/capture/snapshot_capture.dart';
import 'src/capture/screenshot_capture.dart';
import 'src/network/api_client.dart';
import 'src/network/network_monitor.dart';
import 'src/storage/event_database.dart';
import 'src/storage/pending_event.dart';
import 'src/storage/pending_screenshot.dart';
import 'src/performance/performance_monitor.dart';
import 'src/crash/crash_tracker.dart';
import 'src/privacy/identity.dart';
import 'src/privacy/opt_manager.dart';
import 'src/flush/flush_scheduler.dart';
import 'src/util/device_info.dart';
import 'src/core/version.dart';
import 'src/util/json_util.dart';
import 'src/logger/logger.dart';
import 'src/generated/sdk_contract.dart';

export 'src/config.dart';
export 'src/tracking/observer.dart';
export 'src/tracking/gesture_tracker.dart';
export 'src/tracking/unilitix_app.dart';
export 'src/tracking/unilitix_widget.dart';
export 'src/tracking/unilitix_material_app.dart';
export 'src/privacy/privacy_mask.dart';
export 'src/privacy/opt_manager.dart' show UnilitixConsent;
export 'src/events/event.dart';

// Top-level alias so Unilitix.runApp can call Flutter's runApp without
// triggering Dart's static-scope resolution, which would make the bare
// identifier `runApp` inside class Unilitix resolve to the static method
// itself and recurse infinitely.
void _flutterRunApp(Widget app) => runApp(app);

/// The Unilitix SDK entry point.
///
/// Initialize once in `main()` before `runApp()`.
class Unilitix {
  Unilitix._();

  static UnilitixConfig? _config;
  static bool _initialized = false;
  static bool _observerConnected = false;
  static final List<Map<String, dynamic>> _breadcrumbs = [];

  static late SessionManager _sessionManager;
  static late EventBuffer _eventBuffer;
  static late FlushScheduler _flushScheduler;
  static late EventDatabase _database;
  static late ApiClient _apiClient;
  static late SnapshotBuffer _snapshotBuffer;
  static late SnapshotCapture _snapshotCapture;
  static late ScreenshotCapture _screenshotCapture;
  static late CrashTracker _crashTracker;
  static late NetworkMonitor _networkMonitor;
  static late Identity _identity;
  static late OptManager _optManager;
  static late PerformanceMonitor _performanceMonitor;
  static late DeviceInfoCollector _deviceInfo;
  static late RageTapDetector _rageTapDetector;
  static late AfricaContext _africaContext;

  // Device info cache — refreshed at most once every 5 minutes to avoid
  // redundant platform channel round-trips on every periodic flush.
  static DateTime? _lastDeviceInfoRefresh;
  static double? _cachedBattery;
  static String? _cachedCarrier;
  static double? _cachedStorage;

  static final UnilitixObserver _observer = UnilitixObserver();

  /// The navigator observer for screen tracking.
  /// Add to [MaterialApp.navigatorObservers].
  ///
  /// ```dart
  /// MaterialApp(navigatorObservers: [Unilitix.observer])
  /// ```
  static UnilitixObserver get observer => _observer;

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _initialized;

  static void _markObserverConnected() => _observerConnected = true;

  /// The current SDK configuration.
  static UnilitixConfig? get config => _config;

  // ── Init ──────────────────────────────────────────────────────────

  /// Initializes the Unilitix SDK.
  /// Call once in [main] before [runApp].
  ///
  /// Calling [init] more than once is a no-op — the first API key and config win.
  ///
  /// ```dart
  /// await Unilitix.init('your_api_key');
  /// ```
  ///
  /// Apps that must ask before collecting (NDPR, GDPR) start in
  /// [UnilitixConsent.pending]: everything is captured to the on-device queue
  /// but nothing is uploaded until [setConsent] is called with
  /// [UnilitixConsent.granted] (which sends what was held) or
  /// [UnilitixConsent.denied] (which deletes it). A decision persisted from a
  /// previous launch always wins over [consent].
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
  }) async {
    if (_initialized) {
      UnilitixLogger.w(
        'Unilitix.init() called more than once — ignoring. '
        'The first API key and config are used.',
      );
      return;
    }

    final effectiveConfig =
        config?.copyWith(apiKey: apiKey) ?? UnilitixConfig(apiKey: apiKey);
    _config = effectiveConfig;
    UnilitixLogger.enabled = effectiveConfig.debug;

    if (effectiveConfig.sessionTimeoutSeconds < 60) {
      UnilitixLogger.w(
          'sessionTimeoutSeconds=${effectiveConfig.sessionTimeoutSeconds} is very low');
    }

    _deviceInfo = DeviceInfoCollector();
    await _deviceInfo.collect();

    _identity = Identity();
    await _identity.initialize();

    _optManager = OptManager();
    await _optManager.load(initial: consent);

    _database = EventDatabase(
      maxOfflineEvents: effectiveConfig.maxOfflineEvents,
      maxScreenshotsPerSession: effectiveConfig.maxScreenshotsPerSession,
    );
    try {
      await _database.open();
      UnilitixLogger.d('✅ Database opened');
    } catch (e, stack) {
      UnilitixLogger.e('❌ Database failed to open', e, stack);
    }

    _performanceMonitor = PerformanceMonitor()..start();

    _networkMonitor = NetworkMonitor(
      onNetworkChanged: (type) => _sessionManager.onNetworkTypeChanged(type),
      apiUrl: effectiveConfig.apiUrl,
    );
    _networkMonitor.start();

    _africaContext = const AfricaContext();

    _snapshotBuffer =
        SnapshotBuffer(capacity: effectiveConfig.maxSnapshotsPerSession);

    _eventBuffer = EventBuffer(
      batchSize: effectiveConfig.flushBatchSize,
      onFlushNeeded: () => _flushScheduler.flush(),
    );

    _apiClient = ApiClient(
      apiKey: effectiveConfig.apiKey,
      apiUrl: effectiveConfig.apiUrl,
      sdkVersion: kUnilitixSdkVersion,
    );

    _rageTapDetector = RageTapDetector(
      onRageTap: (screen, x, y, cx, cy) {
        _addBreadcrumb('RAGE_TAP', screen);
        _emitEvent(UnilitixEvent(
          type: EventTypes.rageTap,
          screen: screen,
          x: cx,
          y: cy,
        ));
      },
    );

    _sessionManager = SessionManager(
      sessionTimeoutSeconds: effectiveConfig.sessionTimeoutSeconds,
      onSessionStart: (session) {
        _applyReplaySampling(session.id);
        _crashTracker.resetSession();
        if (_optManager.isOptedOut) return;
        _emitEvent(UnilitixEvent(
          type: EventTypes.sessionStart,
          properties: {'sessionId': session.id},
        ));
        unawaited(() async {
          try {
            var payload = await _buildSessionPayload();
            if (payload == null) {
              // Platform may not be ready immediately — retry once.
              await Future.delayed(const Duration(milliseconds: 500));
              payload = await _buildSessionPayload();
            }
            if (payload != null) {
              final withCrash = {...payload, 'crashed': true};
              await _database.savePendingSession(
                  session.id, jsonEncode(withCrash));
            }
          } catch (e) {
            UnilitixLogger.w('Failed to save pending session stub: $e');
          }
        }());
      },
      onSessionEnd: (session) {
        if (_optManager.isOptedOut) return;
        unawaited(() async {
          try {
            final payload = await _buildSessionPayload();
            if (payload != null) {
              // Overwrite the crash stub with the final payload (includes endedAt,
              // durationMs, crashed: false). Survives as a recovery record if the
              // flush below fails; deleted by flushOnSessionEnd on success.
              await _database.savePendingSession(
                  session.id, jsonEncode(payload));
            }
          } catch (e) {
            UnilitixLogger.w(
                'Failed to update pending session stub on end: $e');
          }
          await _flushScheduler.flushOnSessionEnd(session);
        }());
      },
      resetScreenshotOrdinal: () {
        _screenshotCapture.resetOrdinal();
        _snapshotBuffer.clear();
      },
    );

    _flushScheduler = FlushScheduler(
      intervalSeconds: effectiveConfig.flushIntervalSeconds,
      buffer: _eventBuffer,
      sessionManager: _sessionManager,
      database: _database,
      apiClient: _apiClient,
      networkMonitor: _networkMonitor,
      performanceMonitor: _performanceMonitor,
      buildSessionPayload: _buildSessionPayload,
      uploadScreenshotsOnWifiOnly: effectiveConfig.uploadScreenshotsOnWifiOnly,
      snapshotBuffer: _snapshotBuffer,
      isOptedOut: () => _optManager.isOptedOut,
      canUpload: () => _optManager.canUpload,
    );

    _sessionManager.onEventsFlush = () {
      unawaited(_flushScheduler.flushEventsOnly());
    };

    _screenshotCapture = ScreenshotCapture(
      repaintKey: SdkScope.repaintKey,
      intervalMs: effectiveConfig.screenshotIntervalMs,
      maxScreenshots: effectiveConfig.maxScreenshotsPerSession,
      maxWidth: effectiveConfig.screenshotMaxWidth,
      quality: effectiveConfig.screenshotQuality,
      maskScreenshots: effectiveConfig.maskScreenshots,
      maskImages: effectiveConfig.maskImages,
      maskInputs: effectiveConfig.maskInputs,
      maskAllText: effectiveConfig.maskAllText,
      maxPerMinute: effectiveConfig.maxScreenshotsPerMinute,
      heartbeatMs: effectiveConfig.screenshotHeartbeatMs,
      onCapture: (bytes, screenName, ordinal, w, h, capturedAt) async {
        final sessionId = _sessionManager.currentSession?.id ?? '';
        await _database.insertScreenshot(PendingScreenshot(
          sessionId: sessionId,
          ordinal: ordinal,
          screenName: screenName,
          viewportWidth: w,
          viewportHeight: h,
          capturedAt: capturedAt,
          imageBytes: bytes,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
        UnilitixLogger.d('Screenshot #$ordinal stored on $screenName');
      },
    );

    _snapshotCapture = SnapshotCapture(
      buffer: _snapshotBuffer,
      intervalMs: effectiveConfig.snapshotIntervalMs,
      maskInputs: effectiveConfig.maskInputs,
      maskAllText: effectiveConfig.maskAllText,
      maskImages: effectiveConfig.maskImages,
    );
    // A structural change in the widget tree is what makes a screenshot worth
    // taking; taps and navigation mark it dirty directly (below).
    _snapshotCapture.onChanged = () => _screenshotCapture.markDirty();

    _crashTracker = CrashTracker(
      onCrashEvent: (event) {
        if (_optManager.isOptedOut) return;
        _guard('crash', () {
          _sessionManager.currentSession?.crashed = true;
          _attachAndPersist(event); // durable before anything else happens
          _eventBuffer.emit(event);
        });
        // The upload is scheduled on a fresh timer tick rather than awaited here:
        // this callback runs inside the zone error handler, and an exception
        // thrown synchronously from flush() would re-enter it. flushCrash()
        // swallows its own errors and is bounded by a timeout, so the worst
        // case is that the WAL copy is uploaded on the next launch instead.
        Timer.run(() {
          _flushScheduler.flushCrash().catchError((_) {});
        });
      },
      onExceptionEvent: (event) {
        // Non-fatal: recorded, never marks the session crashed, no urgent flush.
        _emitEvent(event); // gated on consent inside
      },
      breadcrumbs: _breadcrumbs,
      database: _database,
    );

    // Wire up SdkScope callbacks
    SdkScope.onScreenChange = _onScreenChange;
    SdkScope.onTap = _onTap;
    SdkScope.onObserverConnected = _markObserverConnected;
    SdkScope.onScroll = (screen, dx, dy) => _guard('scroll', () {
          _screenshotCapture.markDirty();
          _emitEvent(UnilitixEvent(
            type: EventTypes.scroll,
            screen: screen,
            x: dx,
            y: dy,
          ));
        });
    // Start everything
    _sessionManager.start();
    if (effectiveConfig.autoTrackCrashes) _crashTracker.install();
    await _crashTracker.logPendingCrashesIfAny();
    // A native crash (JVM exception, NSException, fatal signal) from the last
    // process is reported now as a fatal CRASH against the session that was
    // running when it happened (its stub is still in pending_sessions), so
    // the crash and its replay stay together. Awaited: the queued batch must
    // exist before session recovery below decides what is worth sending.
    if (!_optManager.isOptedOut) {
      try {
        await _crashTracker.reportNativeCrashIfAny(
          attribute: _attributeNativeCrash,
          report: _queueCrashForSession,
        );
      } catch (e) {
        UnilitixLogger.w('Native crash report failed: $e');
      }
    }
    _flushScheduler.start();
    if (_optManager.isOptedOut) {
      // Denied: anything a previous process left behind must not survive.
      unawaited(_database.purgeAll());
    } else {
      // Events written to the write-ahead log by a previous process that never
      // flushed them become retry batches first, then session stubs are
      // handled. Both are held, not sent, while consent is pending.
      unawaited(_database.recoverWalToPending().then((n) {
        if (n > 0) UnilitixLogger.d('Recovered $n unflushed events from WAL');
      }));
      unawaited(_recoverPendingSessions());
    }
    _startReplayCaptureIfAllowed();

    _initialized = true;

    if (effectiveConfig.debug) {
      final sid = _sessionManager.currentSession?.id ?? '—';
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      UnilitixLogger.d('SDK initialized  ✅  v$kUnilitixSdkVersion');
      UnilitixLogger.d(
          'Session started  ✅  ${sid.length > 8 ? sid.substring(0, 8) : sid}…');
      UnilitixLogger.d(
          'API key          ${effectiveConfig.apiKey.length > 8 ? "${effectiveConfig.apiKey.substring(0, 4)}****${effectiveConfig.apiKey.substring(effectiveConfig.apiKey.length - 4)}" : "****"}');
      UnilitixLogger.d(
          'Device           ${_deviceInfo.manufacturer} ${_deviceInfo.model} (${_deviceInfo.os} ${_deviceInfo.osVersion})');
      UnilitixLogger.d(
          'App              ${_deviceInfo.appName} ${_deviceInfo.appVersion}+${_deviceInfo.buildNumber}');
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!_observerConnected) {
          UnilitixLogger.w(
            'Observer not connected — add Unilitix.observer to MaterialApp.navigatorObservers',
          );
        }
      });
    }
  }

  /// Initializes crash detection and starts the app.
  ///
  /// ```dart
  /// void main() {
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
  ///
  /// Do NOT wrap [MaterialApp] itself — use [MaterialApp.builder] to ensure
  /// screenshots capture fully rendered content.
  static void runApp(Widget app) {
    // CrashTracker.install() already hooks FlutterError.onError and
    // PlatformDispatcher.instance.onError, covering all error paths.
    // runZonedGuarded is NOT used here: it would create a child zone after
    // WidgetsFlutterBinding.ensureInitialized() ran in the parent zone,
    // causing Flutter's "Zone mismatch" assertion on every runApp call.
    _flutterRunApp(app);
  }

  // ── Tracking ──────────────────────────────────────────────────────

  /// Tracks a custom event with optional properties.
  ///
  /// ```dart
  /// Unilitix.track('button_tapped', {'screen': 'home'});
  /// ```
  static Future<void> track(
    String event, [
    Map<String, dynamic>? properties,
  ]) async {
    if (!_ready('track')) return;
    if (_optManager.isOptedOut) return;
    _guard('track', () {
      _addBreadcrumb(EventTypes.custom, SdkScope.currentScreen);
      _emitEvent(UnilitixEvent(
        type: EventTypes.custom,
        screen: SdkScope.currentScreen,
        properties: properties ?? {},
      )..eventName = event);
    });
    // Until 2.1.0 every track() call also fired an immediate POST, so an app
    // tracking in a loop made one request per call. Custom events now ride
    // the normal batch (every `flushIntervalSeconds`, or sooner when
    // `flushBatchSize` is reached); call [flush] for an immediate send.
  }

  /// Identifies the current user with optional traits.
  ///
  /// ```dart
  /// Unilitix.identify('user_123', {'email': 'ada@example.com'});
  /// ```
  static Future<void> identify(
    String userId, [
    Map<String, dynamic>? traits,
  ]) async {
    if (!_ready('identify')) return;
    if (_optManager.isOptedOut) return;
    await _guardAsync('identify', () async {
      await _identity.setUserId(userId, traits: traits);
      if (!_optManager.canUpload) return; // sent when consent is granted
      await _sendIdentify();
    });
  }

  /// Manually tracks a screen view.
  /// Use when [Unilitix.observer] cannot detect navigation automatically.
  static Future<void> screen(String screenName) async {
    if (!_ready('screen')) return;
    _onScreenChange(screenName);
  }

  /// Records an error the app caught itself, as a non-fatal `EXCEPTION`
  /// (or a `CRASH` when [fatal] is true), with the current breadcrumbs.
  ///
  /// ```dart
  /// try {
  ///   await payments.charge(card);
  /// } catch (e, st) {
  ///   Unilitix.captureException(e, stackTrace: st);
  ///   showRetry();
  /// }
  /// ```
  static void captureException(
    Object error, {
    StackTrace? stackTrace,
    bool fatal = false,
  }) {
    if (!_ready('captureException')) return;
    if (_optManager.isOptedOut) return;
    _guard('captureException', () {
      _crashTracker.capture(error, stackTrace ?? StackTrace.current,
          fatal: fatal);
    });
  }

  /// Adds a breadcrumb to the trail attached to the next crash or exception
  /// report. The SDK already records taps, navigation and custom events;
  /// use this for app state that explains a crash — "payment started",
  /// "token refreshed" — never for personal data. The trail keeps the last 50.
  ///
  /// ```dart
  /// Unilitix.addBreadcrumb('checkout started', category: 'flow',
  ///     data: {'items': 3});
  /// ```
  static void addBreadcrumb(
    String message, {
    String? category,
    Map<String, dynamic>? data,
  }) {
    if (!_ready('addBreadcrumb')) return;
    if (_optManager.isOptedOut) return;
    _guard('addBreadcrumb', () {
      _addBreadcrumb(category ?? 'custom', SdkScope.currentScreen,
          message: message, data: data);
    });
  }

  /// Runs [body] so that a bug inside the SDK is logged, never thrown into
  /// the host app — where the SDK's own crash tracker would then record it as
  /// the app crashing. Every public entry point and every framework callback
  /// goes through here or [_guardAsync].
  static void _guard(String what, void Function() body) {
    try {
      body();
    } catch (e, st) {
      UnilitixLogger.e('Unilitix.$what failed inside the SDK', e, st);
    }
  }

  static Future<void> _guardAsync(
      String what, Future<void> Function() body) async {
    try {
      await body();
    } catch (e, st) {
      UnilitixLogger.e('Unilitix.$what failed inside the SDK', e, st);
    }
  }

  // ── Session ───────────────────────────────────────────────────────

  /// Manually starts a new session.
  static Future<void> startSession() async {
    if (!_ready('startSession')) return;
    _guard('startSession', () {
      _sessionManager.stop();
      _sessionManager.start();
    });
  }

  /// Manually ends the current session.
  static Future<void> endSession() async {
    if (!_ready('endSession')) return;
    _guard('endSession', _sessionManager.stop);
  }

  // ── Privacy ───────────────────────────────────────────────────────

  /// The current consent state.
  static UnilitixConsent get consent =>
      _initialized ? _optManager.consent : UnilitixConsent.granted;

  /// Records the user's consent decision and acts on it immediately.
  ///
  /// * [UnilitixConsent.granted]: uploads resume; everything held while
  ///   pending (events, sessions, replay, identity) is sent.
  /// * [UnilitixConsent.pending]: capture continues, uploads stop, nothing is
  ///   deleted.
  /// * [UnilitixConsent.denied]: capture stops, memory buffers and the whole
  ///   on-device queue are purged, and nothing captured afterwards leaves the
  ///   device. Same as [optOut].
  static Future<void> setConsent(UnilitixConsent value) async {
    if (!_ready('setConsent')) return;
    await _guardAsync('setConsent', () => _applyConsent(value));
  }

  static Future<void> _applyConsent(UnilitixConsent value) async {
    final before = _optManager.consent;
    await _optManager.set(value);
    switch (value) {
      case UnilitixConsent.denied:
        _snapshotCapture.stop();
        _screenshotCapture.stop();
        _snapshotBuffer.clear();
        _eventBuffer.clear();
        await _database.purgeAll();
        UnilitixLogger.d(
            'Consent denied — capture stopped, local queue purged');
      case UnilitixConsent.pending:
        _startReplayCaptureIfAllowed();
        UnilitixLogger.d('Consent pending — collecting, not uploading');
      case UnilitixConsent.granted:
        _startReplayCaptureIfAllowed();
        if (before != UnilitixConsent.granted) {
          // Release everything that was held.
          if (_identity.userId != null) unawaited(_sendIdentify());
          unawaited(_recoverPendingSessions());
          unawaited(_flushScheduler.flush());
        }
        UnilitixLogger.d('Consent granted');
    }
  }

  /// Stops all tracking and analytics collection. Same as
  /// `setConsent(UnilitixConsent.denied)`.
  static Future<void> optOut() => setConsent(UnilitixConsent.denied);

  /// Resumes tracking after [optOut]. Same as
  /// `setConsent(UnilitixConsent.granted)`.
  static Future<void> optIn() => setConsent(UnilitixConsent.granted);

  /// Resets user identity and clears stored IDs. Call on logout.
  static Future<void> reset() async {
    if (!_ready('reset')) return;
    await _guardAsync('reset', () async {
      await _identity.reset();
      UnilitixLogger.d('Identity reset');
    });
  }

  // ── Flush ─────────────────────────────────────────────────────────

  /// Immediately flushes all queued events to the backend.
  static Future<void> flush() async {
    if (!_ready('flush')) return;
    await _guardAsync('flush', () async {
      await _flushScheduler.flush();
      UnilitixLogger.d('Flush complete');
    });
  }

  // ── Internal ──────────────────────────────────────────────────────

  static Future<void> _recoverPendingSessions() async {
    if (!_optManager.canUpload) return; // held until consent is granted
    try {
      final sessions = await _database.getPendingSessions();
      if (sessions.isEmpty) return;

      for (final s in sessions) {
        final id = s['id'] as String?;
        final raw = s['session_json'] as String?;
        if (id == null || raw == null) continue;
        try {
          final payload = jsonDecode(raw) as Map<String, dynamic>;

          final startedAtStr = payload['startedAt'] as String?;
          final startedAt =
              startedAtStr != null ? DateTime.tryParse(startedAtStr) : null;
          final age = startedAt != null
              ? DateTime.now().difference(startedAt)
              : const Duration(days: 999);

          // Check for unsent events before deciding whether to discard.
          final hasPendingEvents =
              await _database.hasPendingEventsForSession(id);

          // Recovery rules:
          // 1. Always recover if session has unsent events (offline recovery).
          // 2. Always recover a session that did not end cleanly (the start
          //    sentinel still says crashed: true) — a crash found a week
          //    later is still a crash the dashboard should count.
          // 3. Recover if session is < 30 minutes old (recent kill).
          // 4. Discard if old, ended cleanly, and nothing unsent.
          final crashed = payload['crashed'] == true;
          if (!hasPendingEvents && !crashed && age.inMinutes >= 30) {
            await _database.deletePendingSession(id);
            UnilitixLogger.d(
                'Discarding stale session $id (${age.inMinutes}m old, no pending events)');
            continue;
          }

          UnilitixLogger.d(
              'Recovering session $id (${age.inMinutes}m old, hasPendingEvents: $hasPendingEvents)');
          final r = await _apiClient.ingestSession(payload);
          if (r.ok || r.status == 409) {
            await _database.deletePendingSession(id);
            UnilitixLogger.d('Recovered session $id');
          } else if (r.rejected) {
            // The server will never take this record; stop re-sending it.
            await _database.deletePendingSession(id);
            UnilitixLogger.w(
                'Discarding session $id rejected with ${r.status}');
          } else if (r.isAuthFailure || r.retryable) {
            break; // same outcome for every other stub this launch
          }
        } on FormatException catch (e) {
          // Corrupt session_json — will never succeed, discard immediately.
          UnilitixLogger.d('Discarding corrupt session $id (invalid JSON): $e');
          await _database.deletePendingSession(id);
        } on TypeError catch (e) {
          // Malformed payload structure — discard so it stops retrying.
          UnilitixLogger.d('Discarding malformed session $id (type error): $e');
          await _database.deletePendingSession(id);
        } catch (e) {
          // Transient error (network, timeout) — leave in DB for next cycle.
          UnilitixLogger.e('Failed to recover session $id', e);
        }
      }
    } catch (e) {
      UnilitixLogger.e('_recoverPendingSessions failed', e);
    }
  }

  static void _onScreenChange(String name) {
    if (_optManager.isOptedOut) return;
    _guard('screen', () {
      SdkScope.currentScreen = name;
      _screenshotCapture.markDirty();
      _addBreadcrumb(EventTypes.navigate, name);
      _emitEvent(UnilitixEvent(
        type: EventTypes.navigate,
        screen: name,
      ));
    });
  }

  static void _onTap(String screen, double x, double y) {
    if (_optManager.isOptedOut) return;
    _guard('tap', () {
      _screenshotCapture.markDirty();
      if (_config?.autoTrackTaps != true) return;
      bool isRage = false;
      if (_config?.autoTrackRageTaps == true) {
        isRage = _rageTapDetector.recordTap(screen, x, y);
      }
      if (!isRage) {
        _addBreadcrumb(EventTypes.tap, screen);
        _emitEvent(UnilitixEvent(
          type: EventTypes.tap,
          screen: screen,
          x: x,
          y: y,
        ));
      }
    });
  }

  static void _emitEvent(UnilitixEvent event) {
    if (_optManager.isOptedOut) return;
    _guard('emit', () {
      _attachAndPersist(event);
      _eventBuffer.emit(event);
    });
  }

  /// Assigns the per-session sequence number and writes the event to the
  /// on-device write-ahead log before it is buffered in memory, so a process
  /// kill between now and the next flush loses nothing.
  static void _attachAndPersist(UnilitixEvent event) {
    final session =
        _sessionManager.currentSession ?? _sessionManager.lastEndedSession;
    if (session == null) return;
    event.seq ??= session.takeSeq();
    _database.walInsert(
      session.id,
      event.id,
      event.seq,
      jsonEncode(event.toJson()),
    );
  }

  /// Whether replay (wireframes and screenshots) is captured for the current
  /// session, decided once per session from `replaySampleRate`.
  static bool _replaySampled = true;
  static final _random = Random();

  static void _applyReplaySampling(String sessionId) {
    final rate = _config?.replaySampleRate ?? 1.0;
    _replaySampled = rate >= 1.0 || (rate > 0 && _random.nextDouble() < rate);
    if (_initialized) _startReplayCaptureIfAllowed();
  }

  /// Starts or stops replay capture according to consent and sampling.
  static void _startReplayCaptureIfAllowed() {
    final cfg = _config;
    if (cfg == null) return;
    final allowed = !_optManager.isOptedOut && _replaySampled;
    if (allowed) {
      if (cfg.captureSnapshots) _snapshotCapture.start();
      if (cfg.captureScreenshots) _screenshotCapture.start();
    } else {
      _snapshotCapture.stop();
      _screenshotCapture.stop();
    }
  }

  static Future<void> _sendIdentify() async {
    final userId = _identity.userId;
    if (userId == null) return;
    try {
      final r = await _apiClient.identify(
        anonymousId: _identity.anonymousId,
        customUserId: userId,
        traits: _identity.userTraits,
      );
      if (r.ok) {
        UnilitixLogger.d('Identify: $userId');
      } else {
        // Not queued: the next session upsert carries userId, and identify()
        // is called again on the next login.
        UnilitixLogger.w('identify failed: ${r.describe()}');
      }
    } catch (e) {
      // Never let an SDK error surface in the host app.
      UnilitixLogger.w('identify failed: $e');
    }
  }

  static void _addBreadcrumb(String type, String? screen,
      {String? message, Map<String, dynamic>? data}) {
    _breadcrumbs.add({
      'type': type,
      'screen': screen,
      if (message != null) 'message': message,
      if (data != null) 'data': data,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_breadcrumbs.length > SdkContract.maxBreadcrumbs) {
      _breadcrumbs.removeAt(0);
    }
  }

  /// Picks the session a native crash belongs to: the pending stub with the
  /// latest `startedAt` at or before the marker's timestamp, excluding the
  /// session that just started. No timestamp → the most recent stub.
  static Future<CrashAttribution> _attributeNativeCrash(int? tsMs) async {
    final current = _sessionManager.currentSession?.id;
    String? best;
    DateTime? bestStart;
    for (final s in await _database.getPendingSessions()) {
      final id = s['id'] as String?;
      final raw = s['session_json'] as String?;
      if (id == null || raw == null || id == current) continue;
      DateTime? started;
      try {
        final payload = jsonDecode(raw) as Map<String, dynamic>;
        started = DateTime.tryParse(payload['startedAt'] as String? ?? '');
      } catch (_) {
        continue;
      }
      if (started == null) continue;
      if (tsMs != null && started.millisecondsSinceEpoch > tsMs) continue;
      if (bestStart == null || started.isAfter(bestStart)) {
        best = id;
        bestStart = started;
      }
    }
    return CrashAttribution(best);
  }

  /// Queues a crash event straight into the retry queue under [sessionId]
  /// (a session that is no longer live), so it is uploaded with the next
  /// flush and the stub is recovered because it now has pending events.
  static Future<void> _queueCrashForSession(
      String sessionId, UnilitixEvent event) async {
    await _database.insertEvent(PendingEvent(
      sessionJson: jsonEncode({'sessionId': sessionId}),
      eventsJson: jsonEncode([event.toJson()]),
      eventCount: 1,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      networkAtCapture: _networkMonitor.currentType(),
    ));
  }

  static Future<void> _refreshDeviceInfoIfNeeded() async {
    final now = DateTime.now();
    if (_lastDeviceInfoRefresh != null &&
        now.difference(_lastDeviceInfoRefresh!) < const Duration(minutes: 5)) {
      return;
    }
    _cachedBattery = await _africaContext.batteryLevel;
    _cachedCarrier = await _africaContext.carrierName;
    _cachedStorage = await _africaContext.totalStorageGb;
    _lastDeviceInfoRefresh = now;
  }

  static Future<Map<String, dynamic>?> _buildSessionPayload() async {
    // Prefer the active session; fall back to the most recently ended session
    // (the case when a flush fires right after _endCurrentSession nulls it).
    final session =
        _sessionManager.currentSession ?? _sessionManager.lastEndedSession;
    if (session == null) return null;

    await _refreshDeviceInfoIfNeeded();

    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenSize = view.physicalSize / view.devicePixelRatio;
    final orientation =
        screenSize.width > screenSize.height ? 'landscape' : 'portrait';

    return {
      'anonymousId': _identity.anonymousId,
      'userId': _identity.userId,
      'deviceType': 'phone',
      'manufacturer': _deviceInfo.manufacturer,
      'deviceModel': _deviceInfo.model,
      'os': _deviceInfo.os,
      'osVersion': _deviceInfo.osVersion,
      'screenWidth': screenSize.width.toInt(),
      'screenHeight': screenSize.height.toInt(),
      'screenDensity': view.devicePixelRatio,
      'appVersion': _deviceInfo.appVersion,
      'buildNumber': _deviceInfo.buildNumber,
      'packageName': _deviceInfo.packageName,
      'sdkVersion': kUnilitixSdkVersion,
      'networkType': _networkMonitor.currentType(),
      // Null (omitted) rather than sentinels: '' and -1 skew dashboards.
      if (_cachedCarrier != null && _cachedCarrier!.isNotEmpty)
        'carrierName': _cachedCarrier,
      'orientation': orientation,
      'locale': WidgetsBinding.instance.platformDispatcher.locale.toString(),
      'timezone': _deviceInfo.timezone,
      'installId': _identity.installId,
      if (_cachedBattery != null && _cachedBattery! >= 0)
        'batteryLevel': _cachedBattery,
      if (_cachedStorage != null && _cachedStorage! > 0)
        'totalStorageGb': _cachedStorage,
      'startedAt': JsonUtil.toRfc3339(session.startedAt),
      if (session.endedAt != null) ...{
        'endedAt': JsonUtil.toRfc3339(session.endedAt!),
        'durationMs': session.durationMs,
      },
      'foregroundTimeMs': _sessionManager.currentForegroundTimeMs,
      'backgroundTimeMs': session.backgroundTimeMs,
      'crashed': session.crashed,
      'capturedOffline': session.offlineEventCount > 0,
      'offlineEventCount': session.offlineEventCount,
      'onlineEventCount': session.onlineEventCount,
      'networkTransitions': session.networkTransitions,
      'sessionId': session.id,
      // User traits travel once, via /identify — not on every session upsert.
    };
  }

  /// Runtime guard (not assert-only): a call before [init] in a release build
  /// is logged and ignored instead of throwing a LateInitializationError.
  static bool _ready(String method) {
    if (_initialized) return true;
    assert(
      _initialized,
      'Unilitix.$method() called before Unilitix.init(). '
      'Call Unilitix.init() in main() before runApp().',
    );
    UnilitixLogger.w('Unilitix.$method() called before init() — ignored');
    return false;
  }
}
