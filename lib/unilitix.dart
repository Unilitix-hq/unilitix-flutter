/// Unilitix Flutter SDK
///
/// One-line integration:
/// ```dart
/// void main() async {
///   WidgetsFlutterBinding.ensureInitialized();
///   await Unilitix.init('your_api_key');
///   runApp(MyApp());
/// }
/// ```
library unilitix;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

part 'src/config.dart';
part 'src/observer.dart';
part 'src/logger.dart';

/// The Unilitix SDK.
///
/// Initialize once in `main()` before `runApp()`.
class Unilitix {
  Unilitix._();

  static const MethodChannel _channel = MethodChannel('com.unilitix/sdk');

  static bool _initialized = false;
  static UnilitixConfig _config = const UnilitixConfig();
  static late UnilitixObserver _observer;
  static bool _observerAttached = false;
  static bool _screenEventReceived = false;

  // ── Init ──────────────────────────────────────────────

  /// Initialize the Unilitix SDK.
  ///
  /// Call this in `main()` before `runApp()`:
  /// ```dart
  /// await Unilitix.init('your_api_key');
  /// ```
  ///
  /// All features are enabled by default. Pass a [config]
  /// to customize behaviour.
  static Future<void> init(
    String apiKey, {
    UnilitixConfig config = const UnilitixConfig(),
  }) async {
    if (_initialized) {
      _log('Already initialized — skipping');
      return;
    }

    _config = config;
    UnilitixLogger.enabled = config.debug || kDebugMode;

    _log('Initializing Unilitix SDK v1.0.2...');

    try {
      await _channel.invokeMethod<void>('init', {
        'apiKey': apiKey,
        'endpoint': config.endpoint,
        'debug': config.debug,
        'autoTrackScreens': config.autoTrackScreens,
        'autoTrackTaps': config.autoTrackTaps,
        'autoTrackCrashes': config.autoTrackCrashes,
        'autoTrackRageTaps': config.autoTrackRageTaps,
        'flushIntervalSeconds': config.flushIntervalSeconds,
        'sessionTimeoutSeconds': config.sessionTimeoutSeconds,
        'maskInputs': config.maskInputs,
        'sampleRate': config.sampleRate,
      });

      _observer = UnilitixObserver._();
      _initialized = true;

      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
      _log('SDK initialized  ✅');
      _log('Session started  ✅');
      _log(
        _observerAttached
            ? 'Observer         ✅'
            : 'Observer         ⚠️  not yet — add Unilitix.observer '
                'to MaterialApp.navigatorObservers',
      );
      _log('API key:         ${_obscureKey(apiKey)}');
      _log('Endpoint:        ${config.endpoint}');
      _log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');

      if (UnilitixLogger.enabled) {
        Future.delayed(const Duration(seconds: 5), () {
          if (!_screenEventReceived) {
            _log(
              '⚠️  No screen events detected. Did you add '
              'Unilitix.observer to MaterialApp.navigatorObservers?',
              isError: true,
            );
          }
        });
      }
    } on PlatformException catch (e) {
      _log('✗ Init failed: ${e.message}', isError: true);
      rethrow;
    }
  }

  // ── Tracking ──────────────────────────────────────────

  /// Track a custom event with optional properties.
  ///
  /// ```dart
  /// Unilitix.track('purchase_completed', {
  ///   'amount': 5000,
  ///   'currency': 'NGN',
  ///   'product': 'pro_plan',
  /// });
  /// ```
  static Future<void> track(
    String event, [
    Map<String, dynamic> properties = const {},
  ]) async {
    _assertInitialized('track');
    _log('→ Event: $event $properties');
    try {
      await _channel.invokeMethod<void>('track', {
        'event': event,
        'properties': properties,
      });
    } on PlatformException catch (e) {
      _log('✗ track failed: ${e.message}', isError: true);
    }
  }

  /// Identify the current user.
  ///
  /// Call after login with the user's ID and any traits:
  /// ```dart
  /// Unilitix.identify('user_123', {
  ///   'name': 'Tosin',
  ///   'plan': 'pro',
  ///   'country': 'Nigeria',
  /// });
  /// ```
  static Future<void> identify(
    String userId, [
    Map<String, dynamic> traits = const {},
  ]) async {
    _assertInitialized('identify');
    _log('→ Identify: $userId $traits');
    try {
      await _channel.invokeMethod<void>('identify', {
        'userId': userId,
        'traits': traits,
      });
    } on PlatformException catch (e) {
      _log('✗ identify failed: ${e.message}', isError: true);
    }
  }

  /// Manually track a screen view.
  ///
  /// Only needed if you're NOT using [Unilitix.observer].
  /// ```dart
  /// Unilitix.screen('HomeScreen');
  /// ```
  static Future<void> screen(String screenName) async {
    _assertInitialized('screen');
    _screenEventReceived = true;
    _log('→ Screen: $screenName');
    try {
      await _channel.invokeMethod<void>('screen', {
        'screenName': screenName,
      });
    } on PlatformException catch (e) {
      _log('✗ screen failed: ${e.message}', isError: true);
    }
  }

  // ── Session ───────────────────────────────────────────

  /// Manually start a new session.
  /// Sessions are managed automatically — only call this
  /// if you need explicit control.
  static Future<void> startSession() async {
    _assertInitialized('startSession');
    _log('→ Starting session');
    try {
      await _channel.invokeMethod<void>('startSession');
    } on PlatformException catch (e) {
      _log('✗ startSession failed: ${e.message}', isError: true);
    }
  }

  /// Manually end the current session.
  static Future<void> endSession() async {
    _assertInitialized('endSession');
    _log('→ Ending session');
    try {
      await _channel.invokeMethod<void>('endSession');
    } on PlatformException catch (e) {
      _log('✗ endSession failed: ${e.message}', isError: true);
    }
  }

  // ── Privacy ───────────────────────────────────────────

  /// Stop all tracking. Call when user opts out of analytics.
  /// ```dart
  /// Unilitix.optOut();
  /// ```
  static Future<void> optOut() async {
    _assertInitialized('optOut');
    _log('→ Opted out');
    try {
      await _channel.invokeMethod<void>('optOut');
    } on PlatformException catch (e) {
      _log('✗ optOut failed: ${e.message}', isError: true);
    }
  }

  /// Resume tracking after [optOut].
  static Future<void> optIn() async {
    _assertInitialized('optIn');
    _log('→ Opted in');
    try {
      await _channel.invokeMethod<void>('optIn');
    } on PlatformException catch (e) {
      _log('✗ optIn failed: ${e.message}', isError: true);
    }
  }

  /// Reset user identity. Call on logout.
  /// ```dart
  /// Unilitix.reset();
  /// ```
  static Future<void> reset() async {
    _assertInitialized('reset');
    _log('→ Reset identity');
    try {
      await _channel.invokeMethod<void>('reset');
    } on PlatformException catch (e) {
      _log('✗ reset failed: ${e.message}', isError: true);
    }
  }

  // ── Flush ─────────────────────────────────────────────

  /// Immediately send all queued events to Unilitix.
  /// Events are flushed automatically — only call this
  /// if you need guaranteed delivery (e.g. before app exit).
  static Future<void> flush() async {
    _assertInitialized('flush');
    _log('→ Flushing events');
    try {
      await _channel.invokeMethod<void>('flush');
      _log('✓ Flush complete');
    } on PlatformException catch (e) {
      _log('✗ flush failed: ${e.message}', isError: true);
    }
  }

  // ── Navigator Observer ────────────────────────────────

  /// Add to your [MaterialApp] for automatic screen tracking:
  /// ```dart
  /// MaterialApp(
  ///   navigatorObservers: [Unilitix.observer],
  /// )
  /// ```
  static UnilitixObserver get observer {
    assert(
      _initialized,
      'Call Unilitix.init() before accessing Unilitix.observer.',
    );
    return _observer;
  }

  // ── Helpers ───────────────────────────────────────────

  static void _assertInitialized(String method) {
    assert(
      _initialized,
      'Unilitix.$method() called before Unilitix.init(). '
      'Call Unilitix.init() in main() before runApp().',
    );
  }

  static void _log(String msg, {bool isError = false}) {
    if (isError) {
      UnilitixLogger.error(msg);
    } else {
      UnilitixLogger.log(msg);
    }
  }

  static String _obscureKey(String key) {
    if (key.length <= 8) return '****';
    return '${key.substring(0, 4)}****${key.substring(key.length - 4)}';
  }

  /// Whether the SDK has been successfully initialized.
  static bool get isInitialized => _initialized;

  /// The active [UnilitixConfig] set during [init].
  static UnilitixConfig get config => _config;
}
