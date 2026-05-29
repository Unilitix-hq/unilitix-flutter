/// Unilitix Flutter SDK — pure Dart analytics.
///
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Unilitix.init(config: const UnilitixConfig(apiKey: 'key'));
///   runApp(UnilitixGestureDetector(child: MyApp()));
/// }
/// ```
library unilitix;

import 'package:flutter/widgets.dart';
import 'package:package_info_plus/package_info_plus.dart';

import 'src/config.dart';
import 'src/core/sdk_scope.dart';
import 'src/events/event.dart';
import 'src/events/event_buffer.dart';
import 'src/session/session.dart';
import 'src/session/session_manager.dart';
import 'src/tracking/observer.dart';
import 'src/tracking/rage_tap_detector.dart';
import 'src/capture/snapshot_buffer.dart';
import 'src/capture/snapshot_capture.dart';
import 'src/capture/screenshot_capture.dart';
import 'src/network/api_client.dart';
import 'src/network/network_monitor.dart';
import 'src/storage/event_database.dart';
import 'src/performance/performance_monitor.dart';
import 'src/crash/crash_tracker.dart';
import 'src/privacy/identity.dart';
import 'src/privacy/opt_manager.dart';
import 'src/flush/flush_scheduler.dart';
import 'src/util/device_info.dart';
import 'src/logger/logger.dart';

export 'src/config.dart';
export 'src/tracking/observer.dart';
export 'src/tracking/gesture_tracker.dart';
export 'src/privacy/privacy_mask.dart';
export 'src/events/event.dart';

/// The Unilitix SDK entry point.
///
/// Initialize once in `main()` before `runApp()`.
class Unilitix {
  Unilitix._();

  static const String _sdkVersion = '2.0.0';

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

  static final GlobalKey _repaintKey = GlobalKey();
  static final UnilitixObserver _observer = UnilitixObserver();

  /// The navigator observer — add to [MaterialApp.navigatorObservers].
  static UnilitixObserver get observer => _observer;

  /// Whether [init] has completed successfully.
  static bool get isInitialized => _initialized;

  /// The active [UnilitixConfig].
  static UnilitixConfig? get config => _config;

  // ── Init ──────────────────────────────────────────────────────────

  /// Initialize the SDK. Call once in `main()` before `runApp()`.
  ///
  /// ```dart
  /// await Unilitix.init(
  ///   config: const UnilitixConfig(apiKey: 'your_key'),
  /// );
  /// ```
  static Future<void> init({required UnilitixConfig config}) async {
    if (_initialized) {
      UnilitixLogger.w('init() called more than once — ignoring');
      return;
    }
    _config = config;
    UnilitixLogger.enabled = config.debug;

    if (config.sessionTimeoutSeconds < 60) {
      UnilitixLogger.w(
          'sessionTimeoutSeconds=${config.sessionTimeoutSeconds} is very low');
    }

    _packageInfo = await PackageInfo.fromPlatform();
    _deviceInfo = DeviceInfoCollector();
    await _deviceInfo.collect();

    _identity = Identity();
    await _identity.initialize();

    _optManager = OptManager();
    await _optManager.load();

    _database = EventDatabase(maxOfflineEvents: config.maxOfflineEvents);
    await _database.open();

    _performanceMonitor = PerformanceMonitor()..start();

    _networkMonitor = NetworkMonitor(
      onNetworkChanged: (type) => _sessionManager.onNetworkTypeChanged(type),
    );
    _networkMonitor.start();

    _snapshotBuffer = SnapshotBuffer(capacity: config.maxSnapshotsPerSession);

    _eventBuffer = EventBuffer(
      batchSize: config.flushBatchSize,
      onFlushNeeded: () => _flushScheduler.flush(),
    );

    _apiClient = ApiClient(
      apiKey: config.apiKey,
      apiUrl: config.apiUrl,
      sdkVersion: _sdkVersion,
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
      sessionTimeoutSeconds: config.sessionTimeoutSeconds,
      onSessionStart: (session) {
        _emitEvent(UnilitixEvent(
          type: EventTypes.sessionStart,
          properties: {'sessionId': session.id},
        ));
      },
      onSessionEnd: (session) {
        _emitEvent(UnilitixEvent(
          type: EventTypes.sessionEnd,
          properties: {'sessionId': session.id},
        ));
        _flushScheduler.flush();
      },
      resetScreenshotOrdinal: () {
        _screenshotCapture.resetOrdinal();
        _snapshotBuffer.clear();
      },
    );

    _flushScheduler = FlushScheduler(
      intervalSeconds: config.flushIntervalSeconds,
      buffer: _eventBuffer,
      sessionManager: _sessionManager,
      database: _database,
      apiClient: _apiClient,
      networkMonitor: _networkMonitor,
      performanceMonitor: _performanceMonitor,
      buildSessionPayload: _buildSessionPayload,
      uploadScreenshotsOnWifiOnly: config.uploadScreenshotsOnWifiOnly,
    );

    _screenshotCapture = ScreenshotCapture(
      repaintKey: _repaintKey,
      intervalMs: config.screenshotIntervalMs,
      maxScreenshots: config.maxScreenshotsPerSession,
      maxWidth: config.screenshotMaxWidth,
      onCapture: (bytes, screen, ordinal) {
        UnilitixLogger.d('Screenshot #$ordinal on $screen');
      },
    );

    _snapshotCapture = SnapshotCapture(
      buffer: _snapshotBuffer,
      intervalMs: config.snapshotIntervalMs,
      maskInputs: config.maskInputs,
    );

    _crashTracker = CrashTracker(
      onCrashEvent: (event) {
        _sessionManager.currentSession?.crashed = true;
        _eventBuffer.emit(event);
        _flushScheduler.flush();
      },
      breadcrumbs: _breadcrumbs,
    );

    // Wire up SdkScope callbacks
    SdkScope.onScreenChange = _onScreenChange;
    SdkScope.onTap = _onTap;
    SdkScope.onRageTap = (screen, x, y, cx, cy) {
      _rageTapDetector.recordTap(screen, x, y);
    };

    // Start everything
    _sessionManager.start();
    if (config.autoTrackCrashes) _crashTracker.install();
    _flushScheduler.start();
    if (config.captureSnapshots) _snapshotCapture.start();
    if (config.captureScreenshots) _screenshotCapture.start();

    _initialized = true;

    if (config.debug) {
      final sid = _sessionManager.currentSession?.id ?? '—';
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      UnilitixLogger.d('SDK initialized  ✅  v$_sdkVersion');
      UnilitixLogger.d(
          'Session started  ✅  ${sid.length > 8 ? sid.substring(0, 8) : sid}…');
      UnilitixLogger.d(
          'Observer         ⚠️   not yet — add Unilitix.observer to navigatorObservers');
      UnilitixLogger.d(
          'API key          ${config.apiKey.length > 8 ? "${config.apiKey.substring(0, 4)}****${config.apiKey.substring(config.apiKey.length - 4)}" : "****"}');
      UnilitixLogger.d('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      Future.delayed(const Duration(seconds: 5), () {
        if (!SdkScope.screenEventReceived) {
          UnilitixLogger.w('No screen events detected. Did you add '
              'Unilitix.observer to MaterialApp.navigatorObservers?');
        }
      });
    }
  }

  // ── Tracking ──────────────────────────────────────────────────────

  /// Track a custom event with optional properties.
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
  }

  /// Identify the current user.
  static Future<void> identify(
    String userId, [
    Map<String, dynamic>? traits,
  ]) async {
    _assertInitialized('identify');
    await _identity.setUserId(userId);
    if (traits != null) _identity.setTraits(traits);
    UnilitixLogger.d('Identify: $userId');
  }

  /// Manually track a screen view.
  static Future<void> screen(String screenName) async {
    _assertInitialized('screen');
    _onScreenChange(screenName);
  }

  // ── Session ───────────────────────────────────────────────────────

  /// Start a new session manually.
  static Future<void> startSession() async {
    _assertInitialized('startSession');
    _sessionManager.stop();
    _sessionManager.start();
  }

  /// End the current session manually.
  static Future<void> endSession() async {
    _assertInitialized('endSession');
    _sessionManager.stop();
  }

  // ── Privacy ───────────────────────────────────────────────────────

  /// Stop all tracking and analytics collection.
  static Future<void> optOut() async {
    _assertInitialized('optOut');
    await _optManager.optOut();
    UnilitixLogger.d('Opted out');
  }

  /// Resume tracking after [optOut].
  static Future<void> optIn() async {
    _assertInitialized('optIn');
    await _optManager.optIn();
    UnilitixLogger.d('Opted in');
  }

  /// Reset user identity. Call on logout.
  static Future<void> reset() async {
    _assertInitialized('reset');
    await _identity.reset();
    UnilitixLogger.d('Identity reset');
  }

  // ── Flush ─────────────────────────────────────────────────────────

  /// Immediately flush all queued events.
  static Future<void> flush() async {
    _assertInitialized('flush');
    await _flushScheduler.flush();
    UnilitixLogger.d('Flush complete');
  }

  // ── Internal ──────────────────────────────────────────────────────

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
    final isRage = _rageTapDetector.recordTap(screen, x, y);
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

  static Map<String, dynamic> _buildSessionPayload() {
    final session = _sessionManager.currentSession ?? Session();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final screenSize = view.physicalSize / view.devicePixelRatio;

    return {
      'anonymousId': _identity.anonymousId,
      'userId': _identity.userId,
      'customUserId': _identity.userId,
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
      'sdkVersion': _sdkVersion,
      'networkType': _networkMonitor.currentType(),
      'locale': WidgetsBinding.instance.platformDispatcher.locale.toString(),
      'timezone': DateTime.now().timeZoneName,
      'installId': _identity.installId,
      'batteryLevel': -1.0,
      'startedAt': session.startedAt,
      'endedAt': session.endedAt,
      'durationMs': session.durationMs,
      'foregroundTimeMs': session.foregroundTimeMs,
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
