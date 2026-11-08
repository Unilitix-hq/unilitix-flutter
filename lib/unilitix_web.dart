import 'package:flutter/services.dart';
import 'package:flutter_web_plugins/flutter_web_plugins.dart';

/// Web registration of the Unilitix plugin.
///
/// Since 3.0.0 the SDK is a wrapper over the native Android and iOS SDKs and
/// does nothing in a browser: `Unilitix.init` prints a debug warning and
/// every call is ignored. This stub only keeps apps that also build for the
/// web compiling; every channel call answers null.
class UnilitixPluginWeb {
  static void registerWith(Registrar registrar) {
    final channel = MethodChannel(
      'com.unilitix/sdk',
      const StandardMethodCodec(),
      registrar,
    );
    channel.setMethodCallHandler((call) async => null);
  }
}
