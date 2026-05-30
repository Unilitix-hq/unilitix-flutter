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
  Session? _lastEndedSession;
  int? _backgroundedAt;
  int _foregroundedAt = 0;
  String _networkSentinel = 'INITIAL';

  Session? get currentSession => _currentSession;

  /// The most recently completed session. Non-null immediately after
  /// [_endCurrentSession] runs, so [_buildSessionPayload] can still
  /// read its fields after [_currentSession] is nulled.
  Session? get lastEndedSession => _lastEndedSession;

  /// Live total foreground time for the current session.
  /// Includes the in-progress foreground window that has not yet been
  /// committed by a `paused` event.
  int get currentForegroundTimeMs {
    final s = _currentSession;
    if (s == null) return _lastEndedSession?.foregroundTimeMs ?? 0;
    if (_backgroundedAt != null) return s.foregroundTimeMs;
    return s.foregroundTimeMs +
        (DateTime.now().millisecondsSinceEpoch - _foregroundedAt);
  }

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
    _foregroundedAt = _currentSession!.startedAt;
    _networkSentinel = 'INITIAL';
    resetScreenshotOrdinal();
    UnilitixLogger.d('Session started: ${_currentSession!.id}');
    onSessionStart(_currentSession!);
  }

  void _endCurrentSession() {
    final s = _currentSession!;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Capture the current foreground window if the app is not backgrounded.
    if (_backgroundedAt == null && _foregroundedAt > 0) {
      s.foregroundTimeMs += now - _foregroundedAt;
    }

    s.endedAt = now;
    _lastEndedSession = s;
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
    if (state == AppLifecycleState.paused) {
      final now = DateTime.now().millisecondsSinceEpoch;
      _currentSession?.foregroundTimeMs += now - _foregroundedAt;
      _backgroundedAt = now;
    } else if (state == AppLifecycleState.resumed) {
      final now = DateTime.now().millisecondsSinceEpoch;
      final bg = _backgroundedAt;
      if (bg != null) {
        final bgDuration = now - bg;
        _backgroundedAt = null;
        _foregroundedAt = now;
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
