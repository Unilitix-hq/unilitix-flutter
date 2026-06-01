import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web stub for the Unilitix SDK platform channel.
///
/// The core SDK is pure Dart and works on all platforms. This stub
/// handles the single native call (getCarrierName) by returning an
/// empty string — carrier detection is not available in browsers.
class UnilitixPluginWeb {
  static void registerWith(Registrar registrar) {
    final channel = MethodChannel(
      'com.unilitix/sdk',
      const StandardMethodCodec(),
      registrar,
    );
    channel.setMethodCallHandler((call) async {
      if (call.method == 'getCarrierName') return '';
      throw PlatformException(
        code: 'Unimplemented',
        message: '${call.method} is not implemented on web.',
      );
    });
  }
}
