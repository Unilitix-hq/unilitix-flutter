import 'dart:math';

/// Rage-tap detector — exact port of the Android algorithm.
///
/// Fires [onRageTap] when 3+ taps occur within 100 px and 1 s.
class RageTapDetector {
  static const int _windowMs = 1000;
  static const double _radiusPx = 100.0;
  static const int _minTaps = 3;

  final void Function(
    String screen,
    double x,
    double y,
    double centroidX,
    double centroidY,
  ) onRageTap;

  final List<_Tap> _taps = [];

  RageTapDetector({required this.onRageTap});

  /// Returns true if this tap triggered a rage-tap event.
  bool recordTap(String screen, double x, double y) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _taps.removeWhere((t) => now - t.time > _windowMs);
    _taps.add(_Tap(screen: screen, x: x, y: y, time: now));

    final cluster = _findCluster(x, y);
    if (cluster.length >= _minTaps) {
      final cx =
          cluster.map((t) => t.x).reduce((a, b) => a + b) / cluster.length;
      final cy =
          cluster.map((t) => t.y).reduce((a, b) => a + b) / cluster.length;
      onRageTap(screen, x, y, cx, cy);
      _taps.clear();
      return true;
    }
    return false;
  }

  List<_Tap> _findCluster(double x, double y) {
    return _taps.where((t) => _distance(t.x, t.y, x, y) <= _radiusPx).toList();
  }

  double _distance(double ax, double ay, double bx, double by) {
    final dx = ax - bx;
    final dy = ay - by;
    return sqrt(dx * dx + dy * dy);
  }
}

class _Tap {
  final String screen;
  final double x;
  final double y;
  final int time;
  const _Tap({
    required this.screen,
    required this.x,
    required this.y,
    required this.time,
  });
}
