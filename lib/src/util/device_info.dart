import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../logger/logger.dart';

/// Device and app fingerprint collected once at SDK init, over the SDK's own
/// `com.unilitix/sdk` channel.
///
/// Until 2.1.0 this came from `device_info_plus` and `package_info_plus`,
/// which pulled two more plugins (and their Kotlin/Swift, Gradle and CocoaPods
/// weight) into every host app for six strings. The plugin the SDK already
/// ships answers `getDeviceInfo` and `getPackageInfo` instead. On web and
/// desktop (no plugin) the fields stay empty and the payload omits them.
class DeviceInfoCollector {
  static const _channel = MethodChannel('com.unilitix/sdk');

  String manufacturer = '';
  String model = '';
  String osVersion = '';

  /// IANA zone id (`Africa/Lagos`), or the platform abbreviation (`WAT`)
  /// when the plugin is not available. Dashboards bucket by this, and
  /// abbreviations collide (`CST` is three zones).
  String timezone = '';

  String appName = '';
  String appVersion = '';
  String buildNumber = '';
  String packageName = '';

  Future<void> collect() async {
    timezone = DateTime.now().timeZoneName;
    if (kIsWeb) return;
    try {
      final d =
          await _channel.invokeMapMethod<String, dynamic>('getDeviceInfo');
      if (d != null) {
        manufacturer = _str(d['manufacturer']);
        model = _str(d['model']);
        if (model.isEmpty) model = _str(d['brand']);
        osVersion = _str(d['osVersion']);
        final tz = _str(d['timezone']);
        if (tz.isNotEmpty) timezone = tz;
      }
    } on MissingPluginException {
      // Desktop or a host that did not register the plugin: fields stay empty.
    } catch (e) {
      UnilitixLogger.w('getDeviceInfo failed: ${e.runtimeType}');
    }
    try {
      final p =
          await _channel.invokeMapMethod<String, dynamic>('getPackageInfo');
      if (p != null) {
        appName = _str(p['appName']);
        appVersion = _str(p['version']);
        buildNumber = _str(p['buildNumber']);
        packageName = _str(p['packageName']);
      }
    } on MissingPluginException {
      // As above.
    } catch (e) {
      UnilitixLogger.w('getPackageInfo failed: ${e.runtimeType}');
    }
    if (manufacturer.isEmpty) manufacturer = _defaultManufacturer;
    UnilitixLogger.d('DeviceInfo: $manufacturer $model ($os $osVersion) '
        'app=$packageName $appVersion+$buildNumber tz=$timezone');
  }

  static String _str(Object? v) => v == null ? '' : v.toString();

  String get _defaultManufacturer {
    if (kIsWeb) return '';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
      case TargetPlatform.macOS:
        return 'Apple';
      default:
        return '';
    }
  }

  String get os {
    if (kIsWeb) return 'Web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return 'Android';
      case TargetPlatform.iOS:
        return 'iOS';
      case TargetPlatform.macOS:
        return 'macOS';
      case TargetPlatform.windows:
        return 'Windows';
      case TargetPlatform.linux:
        return 'Linux';
      default:
        return 'Unknown';
    }
  }
}
