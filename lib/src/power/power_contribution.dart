import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../logger/logger.dart';
import '../network/api_client.dart';
import '../privacy/opt_manager.dart';
import '../util/ids.dart';
import 'h3.dart';
import 'power_signals.dart';

/// Which implementation runs on this platform.
enum PowerPlatformKind { android, ios, unsupported }

PowerPlatformKind currentPowerPlatform() {
  if (kIsWeb) return PowerPlatformKind.unsupported;
  switch (defaultTargetPlatform) {
    case TargetPlatform.android:
      return PowerPlatformKind.android;
    case TargetPlatform.iOS:
      return PowerPlatformKind.ios;
    default:
      return PowerPlatformKind.unsupported;
  }
}

/// A coarse location fix. Used on the device to compute the H3 cell; never
/// stored and never sent.
class PowerLocation {
  final double lat;
  final double lng;

  /// When the fix was taken (epoch ms).
  final int timeMs;

  const PowerLocation(this.lat, this.lng, this.timeMs);
}

/// The native side of power-outage contribution. Every call swallows
/// platform errors: a missing or failing plugin must never reach the app.
class PowerChannel {
  static const MethodChannel _channel = MethodChannel('com.unilitix/sdk');

  const PowerChannel();

  Future<T?> _invoke<T>(String method, [Object? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } catch (e) {
      UnilitixLogger.w('$method failed: ${e.runtimeType}');
      return null;
    }
  }

  /// Android: enables (receiver, periodic upload) or disables and deletes.
  Future<void> configureAndroid(Map<String, Object?> args) =>
      _invoke<void>('powerConfigure', args);

  /// Android: records a charging sample, then uploads the log natively.
  Future<String?> uploadNowAndroid() => _invoke<String>('powerUploadNow');

  /// iOS: starts or stops battery-state change notifications.
  Future<void> setMonitoringIos(bool enabled) =>
      _invoke<void>('powerSetMonitoring', {'enabled': enabled});

  /// iOS: whether the device is plugged in (charging or full); null if unknown.
  Future<bool?> isChargingIos() => _invoke<bool>('powerIsCharging');

  /// iOS: the system's cached location, only if the app already holds
  /// when-in-use or always authorization. Never prompts.
  Future<PowerLocation?> coarseLocationIos() async {
    final m = await _invoke<Map<Object?, Object?>>('powerCoarseLocation');
    if (m == null) return null;
    final lat = m['lat'];
    final lng = m['lng'];
    final t = m['timeMs'];
    if (lat is! num || lng is! num || t is! num) return null;
    return PowerLocation(lat.toDouble(), lng.toDouble(), t.toInt());
  }

  /// iOS: battery-state changes pushed by the plugin while monitoring.
  void setChargingListenerIos(void Function(bool charging)? listener) {
    _channel.setMethodCallHandler(listener == null
        ? null
        : (call) async {
            if (call.method == 'powerChargingChanged' &&
                call.arguments is bool) {
              listener(call.arguments as bool);
            }
            return null;
          });
  }
}

/// Power-outage contribution (opt-in, `UnilitixConfig.powerOutageContribution`).
///
/// Collects only while the app opted in AND consent is granted; in every other
/// state it stops and deletes what it held (pending holds nothing for this
/// feature). Sends `{cell, device, events}` to `POST /v1/signals/power`, where
/// `cell` is an H3 resolution-7 cell computed here from a coarse location the
/// app already has permission for, and `device` is a daily-rotating salted
/// hash. Without a usable location nothing is sent.
///
/// Android records plug/unplug natively (broadcast receiver, no Flutter
/// engine) and uploads natively (WorkManager every 15 min, and on every
/// foreground via [PowerChannel.uploadNowAndroid]). iOS has no background
/// charging signal, so it records samples at foreground and background and
/// transitions while in the foreground, queued here and uploaded on
/// foreground.
class PowerContribution with WidgetsBindingObserver {
  static const String _saltKey = 'unilitix_power_salt';
  static const String _queueKey = 'unilitix_power_queue';

  /// `UnilitixConfig.powerOutageContribution`.
  final bool optedIn;
  final UnilitixConsent Function() consent;
  final String installId;
  final String apiKey;
  final String apiUrl;
  final String sdkVersion;
  final Future<ApiResult> Function(Map<String, dynamic> body) post;
  final PowerChannel channel;
  final PowerPlatformKind platform;
  final DateTime Function() _clock;
  final bool _observeLifecycle;

  final PowerSignalQueue _queue = PowerSignalQueue();
  Future<void> _applying = Future.value();
  bool _observing = false;
  bool _monitoring = false;
  bool _uploading = false;
  bool? _lastCharging;

  PowerContribution({
    required this.optedIn,
    required this.consent,
    required this.installId,
    required this.apiKey,
    required this.apiUrl,
    required this.sdkVersion,
    required this.post,
    this.channel = const PowerChannel(),
    PowerPlatformKind? platform,
    DateTime Function()? clock,
    bool observeLifecycle = true,
  })  : platform = platform ?? currentPowerPlatform(),
        _clock = clock ?? DateTime.now,
        _observeLifecycle = observeLifecycle;

  /// Collecting and uploading is allowed right now.
  bool get active =>
      optedIn &&
      consent() == UnilitixConsent.granted &&
      platform != PowerPlatformKind.unsupported;

  @visibleForTesting
  PowerSignalQueue get queue => _queue;

  /// Applies the current opt-in and consent. Call once after init.
  Future<void> start() => _apply();

  /// Call after every consent change.
  Future<void> onConsentChanged() => _apply();

  /// Serialised so quick consent toggles apply in order.
  Future<void> _apply() {
    final next = _applying.then((_) => _guard(_applyNow));
    _applying = next;
    return next;
  }

  Future<void> _applyNow() async {
    if (platform == PowerPlatformKind.unsupported) return;
    final prefs = await _prefs();
    if (!active) {
      // Nothing was ever enabled on this install: nothing to undo, no
      // platform call. This is the path for every app that does not opt in.
      final hadState = prefs != null &&
          (prefs.containsKey(_saltKey) || prefs.containsKey(_queueKey));
      if (!hadState && !_observing && !_monitoring) return;
      await _teardown(prefs);
      return;
    }

    final salt = await _salt(prefs);
    if (salt == null) return; // storage unavailable: do not collect
    _observe(true);
    if (platform == PowerPlatformKind.android) {
      await channel.configureAndroid({
        'enabled': true,
        'apiKey': apiKey,
        'apiUrl': apiUrl,
        'installId': installId,
        'salt': salt,
        'sdkVersion': sdkVersion,
      });
      await channel.uploadNowAndroid();
    } else {
      _queue.replaceAll(prefs?.getStringList(_queueKey) ?? const []);
      if (!_monitoring) {
        _monitoring = true;
        channel.setChargingListenerIos(_onChargingChanged);
        await channel.setMonitoringIos(true);
      }
      await _sampleIos();
      await _uploadIos();
    }
  }

  /// Stops collection and deletes the queue and the salt (so a later opt-in
  /// starts with a device id unlinkable to this one).
  Future<void> _teardown(SharedPreferences? prefs) async {
    _observe(false);
    if (platform == PowerPlatformKind.android) {
      await channel.configureAndroid({'enabled': false});
    } else if (_monitoring) {
      _monitoring = false;
      channel.setChargingListenerIos(null);
      await channel.setMonitoringIos(false);
    }
    _queue.clear();
    _lastCharging = null;
    try {
      await prefs?.remove(_queueKey);
      await prefs?.remove(_saltKey);
    } catch (_) {}
  }

  void _observe(bool on) {
    if (!_observeLifecycle || on == _observing) return;
    _observing = on;
    if (on) {
      WidgetsBinding.instance.addObserver(this);
    } else {
      WidgetsBinding.instance.removeObserver(this);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!active) return;
    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_guard(() async {
          if (platform == PowerPlatformKind.android) {
            await channel.uploadNowAndroid();
          } else {
            await _sampleIos();
            await _uploadIos();
          }
        }));
      case AppLifecycleState.paused:
        if (platform == PowerPlatformKind.ios) unawaited(_guard(_sampleIos));
      default:
        break;
    }
  }

  Future<void> _guard(Future<void> Function() body) async {
    try {
      await body();
    } catch (e) {
      UnilitixLogger.w('power contribution: ${e.runtimeType}');
    }
  }

  // ── iOS queue ──────────────────────────────────────────────────────

  Future<void> _sampleIos() async {
    final charging = await channel.isChargingIos();
    if (charging == null || !active) return;
    _lastCharging = charging;
    _queue.add(PowerSignal.sample(_nowMs(), charging: charging));
    await _persist();
  }

  void _onChargingChanged(bool charging) {
    if (!active) return;
    final previous = _lastCharging;
    _lastCharging = charging;
    // charging -> full also notifies; only a plug change is a transition.
    if (previous == null || previous == charging) return;
    final now = _nowMs();
    _queue
        .add(charging ? PowerSignal.connect(now) : PowerSignal.disconnect(now));
    unawaited(_persist());
  }

  @visibleForTesting
  void debugChargingChanged(bool charging) => _onChargingChanged(charging);

  @visibleForTesting
  Future<void> debugUpload() => _uploadIos();

  Future<void> _uploadIos() async {
    if (_uploading || !active) return;
    _uploading = true;
    try {
      final now = _clock();
      final nowMs = now.millisecondsSinceEpoch;
      _queue.prune(nowMs);
      await _persist();
      final batches = _queue.batches(nowMs);
      if (batches.isEmpty) return;

      final loc = await channel.coarseLocationIos();
      if (loc == null ||
          nowMs - loc.timeMs > PowerLimits.maxLocationAge.inMilliseconds) {
        return; // no cell, nothing for the map; kept until 48 h old
      }
      final cell = latLngToCell(loc.lat, loc.lng, PowerLimits.h3Resolution);
      final salt = await _salt(await _prefs());
      if (cell == null || salt == null) return;
      final device = powerDeviceHash(installId, salt, now);

      for (final batch in batches) {
        if (!active) return;
        final r = await post(powerRequestBody(cell, device, batch));
        if (r.ok || r.rejected) {
          // Delivered, or a 4xx that resending can never fix.
          _queue.remove(batch);
          await _persist();
        } else {
          break; // retryable or auth failure: kept for the next foreground
        }
      }
    } finally {
      _uploading = false;
    }
  }

  // ── Storage ────────────────────────────────────────────────────────

  int _nowMs() => _clock().millisecondsSinceEpoch;

  Future<SharedPreferences?> _prefs() async {
    try {
      return await SharedPreferences.getInstance();
    } catch (_) {
      return null;
    }
  }

  Future<String?> _salt(SharedPreferences? prefs) async {
    if (prefs == null) return null;
    try {
      var salt = prefs.getString(_saltKey);
      if (salt == null || salt.isEmpty) {
        salt = generateUuidV4();
        await prefs.setString(_saltKey, salt);
      }
      return salt;
    } catch (_) {
      return null;
    }
  }

  Future<void> _persist() async {
    if (platform != PowerPlatformKind.ios || !active) return;
    final prefs = await _prefs();
    try {
      await prefs?.setStringList(_queueKey, _queue.lines);
    } catch (_) {}
  }
}
