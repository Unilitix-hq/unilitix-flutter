import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

import '../logger/logger.dart';

/// Device fingerprint collected once at SDK init.
class DeviceInfoCollector {
  String manufacturer = '';
  String model = '';
  String osVersion = '';

  Future<void> collect() async {
    try {
      if (kIsWeb) return;
      if (defaultTargetPlatform == TargetPlatform.android) {
        final info = await DeviceInfoPlugin().androidInfo;
        manufacturer = info.manufacturer;
        model = info.model;
        osVersion = info.version.release;
      } else if (defaultTargetPlatform == TargetPlatform.iOS) {
        final info = await DeviceInfoPlugin().iosInfo;
        manufacturer = 'Apple';
        model = info.utsname.machine;
        osVersion = info.systemVersion;
      }
      UnilitixLogger.d(
          'DeviceInfo collected: manufacturer="$manufacturer" '
          'model="$model" osVersion="$osVersion"');
    } catch (e, stack) {
      UnilitixLogger.e('DeviceInfo collection failed', e, stack);
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
