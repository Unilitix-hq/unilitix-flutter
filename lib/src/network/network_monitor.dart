import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';

/// Wraps connectivity_plus and exposes typed network state.
class NetworkMonitor {
  final void Function(String type) onNetworkChanged;

  StreamSubscription<List<ConnectivityResult>>? _sub;
  List<ConnectivityResult> _current = [ConnectivityResult.none];

  NetworkMonitor({required this.onNetworkChanged});

  void start() {
    _sub = Connectivity().onConnectivityChanged.listen((results) {
      _current = results;
      onNetworkChanged(currentType());
    });
  }

  void stop() {
    _sub?.cancel();
    _sub = null;
  }

  /// Returns "WIFI", "4G", "CELLULAR", "OFFLINE", etc.
  String currentType() {
    if (_current.contains(ConnectivityResult.wifi)) return 'WIFI';
    if (_current.contains(ConnectivityResult.mobile)) return 'CELLULAR';
    if (_current.contains(ConnectivityResult.ethernet)) return 'ETHERNET';
    return 'OFFLINE';
  }

  bool isWifi() => currentType() == 'WIFI';
  bool isOffline() => currentType() == 'OFFLINE';
}
