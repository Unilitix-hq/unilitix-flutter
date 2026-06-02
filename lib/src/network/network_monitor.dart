import 'dart:async';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Network monitor with zero third-party dependencies.
/// Uses platform channels on Android/iOS, http connectivity check as fallback.
class NetworkMonitor {
  final void Function(String type) onNetworkChanged;

  static const _channel = EventChannel('com.unilitix/network');
  StreamSubscription? _sub;
  String _current = 'UNKNOWN';
  Timer? _pollTimer;

  NetworkMonitor({required this.onNetworkChanged});

  void start() {
    // Try native EventChannel first (Android/iOS)
    try {
      _sub = _channel.receiveBroadcastStream().listen(
        (event) {
          final type = _parseNativeType(event?.toString() ?? '');
          if (type != _current) {
            _current = type;
            onNetworkChanged(_current);
          }
        },
        onError: (_) => _startPolling(),
      );
    } on MissingPluginException {
      // Web/desktop — fall back to polling
      _startPolling();
    }
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
    _pollTimer?.cancel();
    _pollTimer = null;
  }

  /// Polling fallback for web/desktop using an http reachability check.
  void _startPolling() {
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final type = await _checkConnectivity();
      if (type != _current) {
        _current = type;
        onNetworkChanged(_current);
      }
    });
  }

  static Future<String> _checkConnectivity() async {
    try {
      final response = await http
          .get(Uri.parse('https://clients3.google.com/generate_204'))
          .timeout(const Duration(seconds: 5));
      return response.statusCode == 204 ? 'WIFI' : 'OFFLINE';
    } catch (_) {
      return 'OFFLINE';
    }
  }

  static String _parseNativeType(String raw) {
    final r = raw.toUpperCase();
    if (r.contains('WIFI'))      return 'WIFI';
    if (r.contains('LTE') || r.contains('4G'))  return '4G';
    if (r.contains('3G') || r.contains('HSPA')) return '3G';
    if (r.contains('2G') || r.contains('EDGE') || r.contains('GPRS')) return '2G';
    if (r.contains('CELLULAR') || r.contains('MOBILE')) return 'CELLULAR';
    if (r.contains('ETHERNET')) return 'ETHERNET';
    if (r.contains('NONE') || r.contains('OFFLINE')) return 'OFFLINE';
    return 'UNKNOWN';
  }

  String currentType() => _current;
  bool isWifi() => _current == 'WIFI';
  bool isOffline() => _current == 'OFFLINE';
}
