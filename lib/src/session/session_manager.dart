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

  /// Open foreground window. A monotonic [Stopwatch] rather than wall-clock
  /// differences: a clock change (NTP sync, timezone, manual) used to add or
  /// subtract hours from `foregroundTimeMs`.
  final Stopwatch _foreground = Stopwatch();
  Timer? _backgroundTimer;
  String _networkSentinel = 'INITIAL';

  Session? get currentSession => _currentSession;

  bool get isBackgrounded => _backgroundedAt != null;

  /// The most recently completed session. Non-null immediately after
  /// [_endCurrentSession] runs, so [_buildSessionPayload] can still
  /// read its fields after [_currentSession] is nulled.
  Session? get lastEndedSession => _lastEndedSession;

  /// Live total foreground time for the current session.
  /// Includes the in-progress foreground window not yet committed by a pause.
  int get currentForegroundTimeMs {
    final s = _currentSession;
    if (s == null) return _lastEndedSession?.foregroundTimeMs ?? 0;
    return s.foregroundTimeMs + _foreground.elapsedMilliseconds;
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
    _backgroundedAt =
        null; // clear background state so new session starts clean
    if (_currentSession != null) _endCurrentSession();
    _startNewSession();
  }

  void _startNewSession() {
    _currentSession = Session();
    _foreground
      ..reset()
      ..start();
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
    if (s != null && _foreground.isRunning) {
      s.foregroundTimeMs += _foreground.elapsedMilliseconds;
    }
    _foreground
      ..stop()
      ..reset();
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

        _backgroundTimer?.cancel();
        _backgroundTimer = null;

        // Decide on wall-clock time, not on whether the timer fired: iOS (and
        // Android in Doze) suspend the isolate, so a Dart Timer may still look
        // "active" hours later and would otherwise keep one session open forever.
        final awayMs = DateTime.now().difference(bg).inMilliseconds;
        final expired =
            _currentSession == null || awayMs >= sessionTimeoutSeconds * 1000;
        if (!expired) {
          _foreground
            ..reset()
            ..start();
          _currentSession?.backgroundTimeMs += awayMs;
        } else {
          if (_currentSession != null) _endCurrentSession();
          _startNewSession();
        }
        break;

      default:
        break;
    }
  }
}
