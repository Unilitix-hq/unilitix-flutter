import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/services.dart';

import '../network/network_monitor.dart';

/// Africa-first context: battery, carrier, storage.
class AfricaContext {
  final NetworkMonitor networkMonitor;
  final _battery = Battery();

  static const _channel = MethodChannel('com.unilitix/sdk');

  AfricaContext({required this.networkMonitor});

  /// Battery level 0.0–1.0.
  Future<double> get batteryLevel async {
    try {
      return (await _battery.batteryLevel) / 100.0;
    } catch (_) {
      return -1.0;
    }
  }

  Future<BatteryState> get batteryState async {
    try {
      return await _battery.batteryState;
    } catch (_) {
      return BatteryState.unknown;
    }
  }

  String get networkType => networkMonitor.currentType();

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

  /// Total internal storage in GB. Android only — returns -1.0 sentinel
  /// on all other platforms until a platform channel is wired.
  Future<double> get totalStorageGb async {
    try {
      if (defaultTargetPlatform == TargetPlatform.android) {
        // StatFs requires a platform channel; return sentinel value
        return -1.0;
      }
      return -1.0;
    } catch (_) {
      return -1.0;
    }
  }
}
