import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Device fingerprint collected once at SDK init.
class DeviceInfoCollector {
  String manufacturer = 'unknown';
  String model = 'unknown';
  String osVersion = 'unknown';

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
    } catch (_) {
      // Best-effort
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
