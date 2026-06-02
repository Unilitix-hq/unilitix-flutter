import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web stub for the Unilitix SDK platform channel.
///
/// The core SDK is pure Dart and works on all platforms. This stub
/// handles native calls that have no meaningful browser equivalent.
class UnilitixPluginWeb {
  static void registerWith(Registrar registrar) {
    final channel = MethodChannel(
      'com.unilitix/sdk',
      const StandardMethodCodec(),
      registrar,
    );
    channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'getCarrierName': return '';
        case 'getBatteryLevel': return -1.0;
        default: throw PlatformException(
          code: 'Unimplemented',
          message: '${call.method} not implemented on web',
        );
      }
    });
  }
}
