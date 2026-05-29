import 'package:flutter/widgets.dart';

import 'session.dart';
import '../logger/logger.dart';

/// Manages session lifecycle using [WidgetsBindingObserver].
class SessionManager with WidgetsBindingObserver {
  final int sessionTimeoutSeconds;
  final void Function(Session session) onSessionStart;
  final void Function(Session session) onSessionEnd;
  final void Function() resetScreenshotOrdinal;

  Session? _currentSession;
  int? _backgroundedAt;
  String _networkSentinel = 'INITIAL';

  Session? get currentSession => _currentSession;

  SessionManager({
    required this.sessionTimeoutSeconds,
    required this.onSessionStart,
    required this.onSessionEnd,
    required this.resetScreenshotOrdinal,
  });

  void start() {
    WidgetsBinding.instance.addObserver(this);
    _startNewSession();
  }

  void stop() {
    WidgetsBinding.instance.removeObserver(this);
    if (_currentSession != null) _endCurrentSession();
  }

  void _startNewSession() {
    _currentSession = Session();
    _networkSentinel = 'INITIAL';
    resetScreenshotOrdinal();
    UnilitixLogger.d('Session started: ${_currentSession!.id}');
    onSessionStart(_currentSession!);
  }

  void _endCurrentSession() {
    final s = _currentSession!;
    s.endedAt = DateTime.now().millisecondsSinceEpoch;
    UnilitixLogger.d('Session ended: ${s.id} (${s.durationMs} ms)');
    onSessionEnd(s);
    _currentSession = null;
  }

  /// Call when the network type changes (from [NetworkMonitor]).
  void onNetworkTypeChanged(String type) {
    if (_networkSentinel == 'INITIAL') {
      _networkSentinel = type;
      return;
    }
    if (type != _networkSentinel) {
      _networkSentinel = type;
      _currentSession?.networkTransitions++;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (state == AppLifecycleState.paused) {
      _backgroundedAt = now;
    } else if (state == AppLifecycleState.resumed) {
      final bg = _backgroundedAt;
      if (bg != null) {
        final bgDuration = now - bg;
        _backgroundedAt = null;
        if (bgDuration > sessionTimeoutSeconds * 1000) {
          if (_currentSession != null) _endCurrentSession();
          _startNewSession();
        } else {
          _currentSession?.backgroundTimeMs += bgDuration;
        }
      }
    }
  }
}
