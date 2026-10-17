import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

/// Network monitor with zero third-party dependencies.
/// Uses platform channels on Android/iOS, http connectivity check as fallback.
class NetworkMonitor {
  final void Function(String type) onNetworkChanged;

  static const _channel = EventChannel('com.unilitix/network');

  // Reachability probe, used ONLY on web/desktop where no native channel
  // exists. It goes to the Unilitix API itself (a host the app already talks
  // to) so the SDK never contacts a third party on the integrator's behalf.
  // On Android/iOS the native EventChannel is the sole source: an error on
  // it degrades to UNKNOWN rather than to polling.
  final String apiUrl;
  String get _pollUrl => '$apiUrl/health';
  StreamSubscription? _sub;
  String _current = 'UNKNOWN';
  Timer? _pollTimer;

  NetworkMonitor({
    required this.onNetworkChanged,
    this.apiUrl = 'https://api.unilitix.com',
  });

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
        onError: (_) {
          // Native channel failed on a mobile platform: report UNKNOWN once
          // rather than start a polling loop that wakes the radio every 30 s.
          if (kIsWeb) {
            _startPolling();
          } else if (_current != 'UNKNOWN') {
            _current = 'UNKNOWN';
            onNetworkChanged(_current);
          }
        },
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
    _pollTimer?.cancel(); // never stack timers
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) async {
      final type = await _checkConnectivity();
      if (type != _current) {
        _current = type;
        onNetworkChanged(_current);
      }
    });
  }

  Future<String> _checkConnectivity() async {
    try {
      final response = await http
          .get(Uri.parse(_pollUrl))
          .timeout(const Duration(seconds: 5));
      // Reachable, but the link type is unknowable from a browser/desktop.
      return response.statusCode < 300 ? 'UNKNOWN' : 'OFFLINE';
    } catch (_) {
      return 'OFFLINE';
    }
  }

  static String _parseNativeType(String raw) {
    final r = raw.toUpperCase();
    if (r.contains('WIFI')) return 'WIFI';
    if (r.contains('LTE') || r.contains('4G')) return '4G';
    if (r.contains('3G') || r.contains('HSPA')) return '3G';
    if (r.contains('2G') || r.contains('EDGE') || r.contains('GPRS')) {
      return '2G';
    }
    if (r.contains('CELLULAR') || r.contains('MOBILE')) return 'CELLULAR';
    if (r.contains('ETHERNET')) return 'ETHERNET';
    if (r.contains('NONE') || r.contains('OFFLINE')) return 'OFFLINE';
    return 'UNKNOWN';
  }

  String currentType() => _current;

  /// True on Wi-Fi, and on web/desktop where links are not metered the way
  /// mobile data is, so `uploadScreenshotsOnWifiOnly` does not block uploads there.
  bool isWifi() => _current == 'WIFI' || (kIsWeb && _current != 'OFFLINE');
  bool isOffline() => _current == 'OFFLINE';
}
