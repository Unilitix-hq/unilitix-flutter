import 'package:flutter/widgets.dart';

import 'session.dart';
import '../logger/logger.dart';

/// Manages session lifecycle using [WidgetsBindingObserver].
class SessionManager with WidgetsBindingObserver {
  final int sessionTimeoutSeconds;
  final void Function(Session session) onSessionStart;
  final void Function(Session session) onSessionEnd;
  final void Function() resetScreenshotOrdinal;

  /// Called when the app enters the background (paused). Wire to flush pending events.
  void Function()? onBackground;

  Session? _currentSession;
  Session? _lastEndedSession;
  int? _backgroundedAt;
  int? _lastForegroundedAt;
  String _networkSentinel = 'INITIAL';

  Session? get currentSession => _currentSession;

  /// The most recently completed session. Non-null immediately after
  /// [_endCurrentSession] runs, so [_buildSessionPayload] can still
  /// read its fields after [_currentSession] is nulled.
  Session? get lastEndedSession => _lastEndedSession;

  /// Live total foreground time for the current session.
  /// Includes the in-progress foreground window that has not yet been
  /// committed by a [AppLifecycleState.paused] event.
  int get currentForegroundTimeMs {
    final s = _currentSession;
    if (s == null) return _lastEndedSession?.foregroundTimeMs ?? 0;
    if (_backgroundedAt != null) return s.foregroundTimeMs;
    return s.foregroundTimeMs +
        (DateTime.now().millisecondsSinceEpoch -
            (_lastForegroundedAt ?? s.startedAt));
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
    _lastForegroundedAt = _currentSession!.startedAt;
    _networkSentinel = 'INITIAL';
    resetScreenshotOrdinal();
    UnilitixLogger.d('Session started: ${_currentSession!.id}');
    onSessionStart(_currentSession!);
  }

  void _endCurrentSession() {
    final s = _currentSession!;
    final now = DateTime.now().millisecondsSinceEpoch;

    // Capture in-progress foreground window if not currently backgrounded.
    if (_backgroundedAt == null && _lastForegroundedAt != null) {
      s.foregroundTimeMs += now - _lastForegroundedAt!;
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
    switch (state) {
      case AppLifecycleState.paused:
        final now = DateTime.now().millisecondsSinceEpoch;
        if (_currentSession != null) {
          _currentSession!.foregroundTimeMs +=
              now - (_lastForegroundedAt ?? _currentSession!.startedAt);
        }
        _backgroundedAt = now;
        _lastForegroundedAt = null;
        if (_currentSession != null) _endCurrentSession();
        onBackground?.call(); // triggers flushOnSessionEnd
        break;

      case AppLifecycleState.detached:
        // App being killed — end session and flush everything.
        if (_currentSession != null) {
          _endCurrentSession();
        }
        break;

      case AppLifecycleState.resumed:
        _backgroundedAt = null;
        _lastForegroundedAt = DateTime.now().millisecondsSinceEpoch;
        // Always start a new session on resume — previous session was ended on pause.
        _startNewSession();
        break;

      default:
        break;
    }
  }
}
