/// Unilitix Flutter SDK — mobile UX analytics for African apps.
///
/// ## Setup
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Unilitix.init('YOUR_API_KEY');
///   Unilitix.runApp(UnilitixWidget(child: MyApp()));
/// }
///
/// // In your MaterialApp:
/// // MaterialApp(
/// //   navigatorObservers: [Unilitix.observer],
/// // )
/// ```
library unilitix;

import 'dart:async' show runZonedGuarded, unawaited;
import 'dart:convert' show jsonDecode, jsonEncode;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

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

export 'src/config.dart';
export 'src/tracking/observer.dart';
export 'src/tracking/gesture_tracker.dart';
export 'src/tracking/unilitix_app.dart';
export 'src/tracking/unilitix_widget.dart';
export 'src/tracking/unilitix_material_app.dart';
export 'src/privacy/privacy_mask.dart';
export 'src/events/event.dart';

/// The Unilitix SDK entry point.
///
/// Initialize once in `main()` before `runApp()`.
class Unilitix {
  Unilitix._();

  static UnilitixConfig? _config;
  static bool _initialized = false;
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
  static late PackageInfo _packageInfo;
  static late RageTapDetector _rageTapDetector;
  static late AfricaContext _africaContext;

  static final GlobalKey _repaintKey = GlobalKey();
  static final UnilitixObserver _observer = UnilitixObserver();

  /// The navigator observer for screen tracking.
  /// Add to [MaterialApp.navigatorObservers].
  ///
  /// ```dart
  /// MaterialApp(navigatorObservers: [Unilitix.observer])
  /// ```
  static UnilitixObserver get observer => _observer;

  /// The repaint boundary key used by [UnilitixWidget].
  static GlobalKey get repaintKey => _repaintKey;

  /// Whether the SDK has been initialized.
  static bool get isInitialized => _initialized;

  /// The current SDK configuration.
  static UnilitixConfig? get config => _config;

  // ── Init ──────────────────────────────────────────────────────────

  /// Initializes the Unilitix SDK.
  /// Call once in [main] before [runApp].
  ///
  /// ```dart
  /// await Unilitix.init('your_api_key');
  /// ```
  static Future<void> init(
    String apiKey, {
    UnilitixConfig? config,
  }) async {
    final effectiveConfig = config != null
        ? UnilitixConfig(
            apiKey: apiKey,
            apiUrl: config.apiUrl,
            autoTrackTaps: config.autoTrackTaps,
            autoTrackCrashes: config.autoTrackCrashes,
            autoTrackRageTaps: config.autoTrackRageTaps,
            flushIntervalSeconds: config.flushIntervalSeconds,
            flushBatchSize: config.flushBatchSize,
            maxOfflineEvents: config.maxOfflineEvents,
            sessionTimeoutSeconds: config.sessionTimeoutSeconds,
            debug: config.debug,
            maskInputs: config.maskInputs,
            captureSnapshots: config.captureSnapshots,
            snapshotIntervalMs: config.snapshotIntervalMs,
            maxSnapshotsPerSession: config.maxSnapshotsPerSession,
            captureScreenshots: config.captureScreenshots,
            screenshotIntervalMs: config.screenshotIntervalMs,
            screenshotQuality: config.screenshotQuality,
            screenshotMaxWidth: config.screenshotMaxWidth,
            uploadScreenshotsOnWifiOnly: config.uploadScreenshotsOnWifiOnly,
            maxScreenshotsPerSession: config.maxScreenshotsPerSession,
          )
        : UnilitixConfig(apiKey: apiKey);

    if (_initialized) {
      UnilitixLogger.w('init() called more than once — ignoring');
      return;
    }
    _config = effectiveConfig;
    UnilitixLogger.enabled = effectiveConfig.debug;

    if (effectiveConfig.sessionTimeoutSeconds < 60) {
      UnilitixLogger.w(
          'sessionTimeoutSeconds=${effectiveConfig.sessionTimeoutSeconds} is very low');
    }

    _packageInfo = await PackageInfo.fromPlatform();
    _deviceInfo = DeviceInfoCollector();
    await _deviceInfo.collect();

    _identity = Identity();
    await _identity.initialize();

    _optManager = OptManager();
    await _optManager.load();

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
    );
    _networkMonitor.start();

    _africaContext = AfricaContext(networkMonitor: _networkMonitor);

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
        _emitEvent(UnilitixEvent(
          type: EventTypes.sessionStart,
          properties: {'sessionId': session.id},
        ));
        unawaited(_database.savePendingSession(
          session.id,
          jsonEncode({'sessionId': session.id, 'startedAt': session.startedAt, 'crashed': true}),
        ));
      },
      onSessionEnd: (session) {
        unawaited(() async {
          await _flushScheduler.flushOnSessionEnd();
          await _database.deletePendingSession(session.id);
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
    );

    _sessionManager.onEventsFlush = () {
      unawaited(_flushScheduler.flushEventsOnly());
    };

    _screenshotCapture = ScreenshotCapture(
      repaintKey: _repaintKey,
      intervalMs: effectiveConfig.screenshotIntervalMs,
      maxScreenshots: effectiveConfig.maxScreenshotsPerSession,
      maxWidth: effectiveConfig.screenshotMaxWidth,
      quality: effectiveConfig.screenshotQuality,
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
    );

    _crashTracker = CrashTracker(
      onCrashEvent: (event) {
        _sessionManager.currentSession?.crashed = true;
        _eventBuffer.emit(event);
        _flushScheduler.flush();
      },
      breadcrumbs: _breadcrumbs,
      database: _database,
    );

    // Wire up SdkScope callbacks
    SdkScope.onScreenChange = _onScreenChange;
    SdkScope.onTap = _onTap;
    SdkScope.onScroll = (screen, dx, dy) {
      _emitEvent(UnilitixEvent(
        type: EventTypes.scroll,
        screen: screen,
        x: dx,
        y: dy,
      ));
    };
    // Start everything
    _sessionManager.start();
    if (effectiveConfig.autoTrackCrashes) _crashTracker.install();
    await _crashTracker.logPendingCrashesIfAny();
    _flushScheduler.start();
    unawaited(_recoverPendingSessions());
    if (effectiveConfig.captureSnapshots) _snapshotCapture.start();
    if (effectiveConfig.captureScreenshots) _screenshotCapture.start();

    _initialized = true;

    if (effectiveConfig.debug) {
      final sid = _sessionManager.currentSession?.id ?? '—';
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      UnilitixLogger.d('SDK initialized  ✅  v$kUnilitixSdkVersion');
      UnilitixLogger.d(
          'Session started  ✅  ${sid.length > 8 ? sid.substring(0, 8) : sid}…');
      UnilitixLogger.d(
          'Observer         ⚠️   not yet — use UnilitixMaterialApp instead of MaterialApp');
      UnilitixLogger.d(
          'API key          ${effectiveConfig.apiKey.length > 8 ? "${effectiveConfig.apiKey.substring(0, 4)}****${effectiveConfig.apiKey.substring(effectiveConfig.apiKey.length - 4)}" : "****"}');
      UnilitixLogger.d(
          'Device           ${_deviceInfo.manufacturer} ${_deviceInfo.model} (${_deviceInfo.os} ${_deviceInfo.osVersion})');
      UnilitixLogger.d(
          'App              ${_packageInfo.appName} ${_packageInfo.version}+${_packageInfo.buildNumber}');
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      Future.delayed(const Duration(seconds: 5), () {
        if (!SdkScope.observerAttached && !SdkScope.screenEventReceived) {
          UnilitixLogger.w(
            'Screen tracking not detected. Replace MaterialApp with UnilitixMaterialApp:\n'
            '  UnilitixMaterialApp(home: HomeScreen())',
          );
        }
      });
    }
  }

  /// Wraps [runApp] with crash detection via [runZonedGuarded].
  /// Use instead of Flutter's [runApp].
  ///
  /// ```dart
  /// Unilitix.runApp(UnilitixWidget(child: MyApp()));
  /// ```
  static void runApp(Widget app) {
    runZonedGuarded(
      () => runApp(app),
      (error, stack) => _crashTracker.recordZoneError(error, stack),
    );
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
    _assertInitialized('track');
    if (_optManager.isOptedOut) return;
    _addBreadcrumb(EventTypes.custom, SdkScope.currentScreen);
    _emitEvent(UnilitixEvent(
      type: EventTypes.custom,
      screen: SdkScope.currentScreen,
      properties: properties ?? {},
    )..eventName = event);
    // Flush immediately so custom events appear in dashboard without delay
    unawaited(_flushScheduler.flushNow());
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
    _assertInitialized('identify');
    if (_optManager.isOptedOut) return;
    await _identity.setUserId(userId, traits: traits);
    await _apiClient.identify(
      anonymousId: _identity.anonymousId,
      customUserId: userId,
      traits: traits,
    );
    UnilitixLogger.d('Identify: $userId');
  }

  /// Manually tracks a screen view.
  /// Use when [Unilitix.observer] cannot detect navigation automatically.
  static Future<void> screen(String screenName) async {
    _assertInitialized('screen');
    _onScreenChange(screenName);
  }

  // ── Session ───────────────────────────────────────────────────────

  /// Manually starts a new session.
  static Future<void> startSession() async {
    _assertInitialized('startSession');
    _sessionManager.stop();
    _sessionManager.start();
  }

  /// Manually ends the current session.
  static Future<void> endSession() async {
    _assertInitialized('endSession');
    _sessionManager.stop();
  }

  // ── Privacy ───────────────────────────────────────────────────────

  /// Stops all tracking and analytics collection.
  static Future<void> optOut() async {
    _assertInitialized('optOut');
    await _optManager.optOut();
    UnilitixLogger.d('Opted out');
  }

  /// Resumes tracking after [optOut].
  static Future<void> optIn() async {
    _assertInitialized('optIn');
    await _optManager.optIn();
    UnilitixLogger.d('Opted in');
  }

  /// Resets user identity and clears stored IDs. Call on logout.
  static Future<void> reset() async {
    _assertInitialized('reset');
    await _identity.reset();
    UnilitixLogger.d('Identity reset');
  }

  // ── Flush ─────────────────────────────────────────────────────────

  /// Immediately flushes all queued events to the backend.
  static Future<void> flush() async {
    _assertInitialized('flush');
    await _flushScheduler.flush();
    UnilitixLogger.d('Flush complete');
  }

  // ── Internal ──────────────────────────────────────────────────────

  static Future<void> _recoverPendingSessions() async {
    try {
      final sessions = await _database.getPendingSessions();
      for (final s in sessions) {
        final id = s['id'] as String?;
        final raw = s['session_json'] as String?;
        if (id == null || raw == null) continue;
        try {
          final payload = jsonDecode(raw) as Map<String, dynamic>;
          final ok = await _apiClient.ingestSession(payload);
          if (ok) {
            await _database.deletePendingSession(id);
            UnilitixLogger.d('Recovered session $id');
          }
        } catch (e) {
          UnilitixLogger.e('Failed to recover session $id', e);
        }
      }
    } catch (e) {
      UnilitixLogger.e('_recoverPendingSessions failed', e);
    }
  }

  static void _onScreenChange(String name) {
    if (_optManager.isOptedOut) return;
    SdkScope.currentScreen = name;
    _addBreadcrumb(EventTypes.navigate, name);
    _emitEvent(UnilitixEvent(
      type: EventTypes.navigate,
      screen: name,
    ));
  }

  static void _onTap(String screen, double x, double y) {
    if (_optManager.isOptedOut) return;
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
  }

  static void _emitEvent(UnilitixEvent event) {
    if (_optManager.isOptedOut) return;
    _eventBuffer.emit(event);
  }

  static void _addBreadcrumb(String type, String? screen) {
    _breadcrumbs.add({
      'type': type,
      'screen': screen,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    });
    if (_breadcrumbs.length > 50) _breadcrumbs.removeAt(0);
  }

  static Future<Map<String, dynamic>?> _buildSessionPayload() async {
    // Prefer the active session; fall back to the most recently ended session
    // (the case when a flush fires right after _endCurrentSession nulls it).
    final session =
        _sessionManager.currentSession ?? _sessionManager.lastEndedSession;
    if (session == null) return null;
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenSize = view.physicalSize / view.devicePixelRatio;
    final batteryLvl = await _africaContext.batteryLevel;
    final carrier = await _africaContext.carrierName;
    final storageGb = await _africaContext.totalStorageGb;
    final orientation =
        screenSize.width > screenSize.height ? 'landscape' : 'portrait';

    UnilitixLogger.d(
        'BUILD PAYLOAD deviceModel="${_deviceInfo.model}" '
        'manufacturer="${_deviceInfo.manufacturer}" '
        'appVersion="${_packageInfo.version}" '
        'buildNumber="${_packageInfo.buildNumber}"');

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
      'appVersion': _packageInfo.version,
      'buildNumber': _packageInfo.buildNumber,
      'packageName': _packageInfo.packageName,
      'sdkVersion': kUnilitixSdkVersion,
      'networkType': _networkMonitor.currentType(),
      'carrierName': carrier,
      'orientation': orientation,
      'locale': WidgetsBinding.instance.platformDispatcher.locale.toString(),
      'timezone': DateTime.now().timeZoneName,
      'installId': _identity.installId,
      'batteryLevel': batteryLvl,
      'totalStorageGb': storageGb,
      'startedAt': JsonUtil.toRfc3339(session.startedAt),
      'endedAt':
          session.endedAt != null ? JsonUtil.toRfc3339(session.endedAt!) : null,
      'durationMs': session.durationMs,
      'foregroundTimeMs': _sessionManager.currentForegroundTimeMs,
      'backgroundTimeMs': session.backgroundTimeMs,
      'crashed': session.crashed,
      'capturedOffline': session.offlineEventCount > 0,
      'offlineEventCount': session.offlineEventCount,
      'onlineEventCount': session.onlineEventCount,
      'networkTransitions': session.networkTransitions,
      'sessionId': session.id,
      'sessionData': _identity.userTraits,
    };
  }

  static void _assertInitialized(String method) {
    assert(
      _initialized,
      'Unilitix.$method() called before Unilitix.init(). '
      'Call Unilitix.init() in main() before runApp().',
    );
  }
}
