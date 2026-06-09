import 'dart:async';

import 'package:flutter/widgets.dart';

import 'session.dart';
import '../logger/logger.dart';

/// Manages session lifecycle using [WidgetsBindingObserver].
class SessionManager with WidgetsBindingObserver {
  final int sessionTimeoutSeconds;
  final void Function(Session session) onSessionStart;
  final void Function(Session session) onSessionEnd;
  final void Function() resetScreenshotOrdinal;

  /// Called on [AppLifecycleState.paused] to drain in-flight events before the
  /// app goes dark. Does not end the session or send a session record.
  void Function()? onEventsFlush;

  Session? _currentSession;
  Session? _lastEndedSession;
  DateTime? _backgroundedAt;
  DateTime? _lastForegroundedAt;
  Timer? _backgroundTimer;
  String _networkSentinel = 'INITIAL';

  Session? get currentSession => _currentSession;

  /// The most recently completed session. Non-null immediately after
  /// [_endCurrentSession] runs, so [_buildSessionPayload] can still
  /// read its fields after [_currentSession] is nulled.
  Session? get lastEndedSession => _lastEndedSession;

  /// Live total foreground time for the current session.
  /// Includes the in-progress foreground window not yet committed by a pause.
  int get currentForegroundTimeMs {
    final s = _currentSession;
    if (s == null) return _lastEndedSession?.foregroundTimeMs ?? 0;
    if (_backgroundedAt != null) return s.foregroundTimeMs;
    final fg = _lastForegroundedAt;
    return s.foregroundTimeMs +
        (fg != null
            ? DateTime.now().millisecondsSinceEpoch - fg.millisecondsSinceEpoch
            : 0);
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
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    WidgetsBinding.instance.removeObserver(this);
    if (_currentSession != null) _endCurrentSession();
  }

  /// Forcibly ends the current session and starts a fresh one.
  /// Called when the server rejects a session payload (400/409).
  void resetSession() {
    _backgroundTimer?.cancel();
    _backgroundTimer = null;
    if (_currentSession != null) _endCurrentSession();
    _startNewSession();
  }

  void _startNewSession() {
    _currentSession = Session();
    _lastForegroundedAt =
        DateTime.fromMillisecondsSinceEpoch(_currentSession!.startedAt);
    _networkSentinel = 'INITIAL';
    resetScreenshotOrdinal();
    UnilitixLogger.d('Session started: ${_currentSession!.id}');
    onSessionStart(_currentSession!);
  }

  void _endCurrentSession() {
    final s = _currentSession;
    if (s == null) return;
    _commitForegroundWindow();
    s.endedAt = DateTime.now().millisecondsSinceEpoch;
    _lastEndedSession = s;
    UnilitixLogger.d('Session ended: ${s.id} (${s.durationMs} ms)');
    onSessionEnd(s);
    _currentSession = null;
  }

  /// Commits the current open foreground window into [Session.foregroundTimeMs].
  void _commitForegroundWindow() {
    final s = _currentSession;
    final fg = _lastForegroundedAt;
    if (s != null && _backgroundedAt == null && fg != null) {
      s.foregroundTimeMs +=
          DateTime.now().millisecondsSinceEpoch - fg.millisecondsSinceEpoch;
    }
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
        _commitForegroundWindow();
        _backgroundedAt = DateTime.now();
        _lastForegroundedAt = null;
        onEventsFlush?.call(); // drain events on background, no session POST
        // End the session after the timeout elapses in the background.
        _backgroundTimer = Timer(
          Duration(seconds: sessionTimeoutSeconds),
          () {
            if (_currentSession != null) _endCurrentSession();
          },
        );
        break;

      case AppLifecycleState.detached:
        // App being killed — cancel pending timer and end session immediately.
        _backgroundTimer?.cancel();
        _backgroundTimer = null;
        if (_currentSession != null) _endCurrentSession();
        break;

      case AppLifecycleState.resumed:
        // Guard: only act if we are actually returning from background.
        if (_backgroundedAt == null) break;
        final bg = _backgroundedAt!;
        _backgroundedAt = null;

        if (_backgroundTimer?.isActive == true) {
          // Within timeout — cancel the timer and continue the same session.
          _backgroundTimer?.cancel();
          _backgroundTimer = null;
          _lastForegroundedAt = DateTime.now();
          _currentSession?.backgroundTimeMs +=
              DateTime.now().millisecondsSinceEpoch -
                  bg.millisecondsSinceEpoch;
        } else {
          // Timer already fired or was never started — start a fresh session.
          _backgroundTimer = null;
          _startNewSession();
        }
        break;

      default:
        break;
    }
  }
}
