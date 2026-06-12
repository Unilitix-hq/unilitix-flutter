import 'package:flutter/services.dart';

/// Africa-first context: battery, carrier, storage.
class AfricaContext {
  static const _channel = MethodChannel('com.unilitix/sdk');

  const AfricaContext();

  /// Battery level 0.0–1.0, via the existing com.unilitix/sdk channel.
  Future<double> get batteryLevel async {
    try {
      final level = await _channel.invokeMethod<double>('getBatteryLevel');
      return level ?? -1.0;
    } on MissingPluginException {
      return -1.0;
    } catch (_) {
      return -1.0;
    }
  }

  /// Mobile carrier name via thin platform channel.
  /// Returns empty string on failure.
  Future<String> get carrierName async {
    try {
      final name = await _channel.invokeMethod<String>('getCarrierName');
      return name ?? '';
    } on MissingPluginException {
      return '';
    } catch (_) {
      return '';
    }
  }

  /// Total internal storage in GB. Not yet implemented — returns -1.0 sentinel.
  Future<double> get totalStorageGb async => -1.0;
}
