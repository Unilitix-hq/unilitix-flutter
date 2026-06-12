import 'dart:io';
import 'package:flutter/scheduler.dart';

import '../events/event.dart';

/// Tracks frame drops and memory usage.
class PerformanceMonitor {
  int _frameDropCount = 0;

  void start() {
    try {
      SchedulerBinding.instance.addTimingsCallback(_onTimings);
    } catch (_) {
      // Not available on all platforms (e.g. web, some embedders).
    }
  }

  void stop() {
    try {
      SchedulerBinding.instance.removeTimingsCallback(_onTimings);
    } catch (_) {}
  }

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      final frameDurationMs = t.totalSpan.inMicroseconds / 1000.0;
      if (frameDurationMs > 32) _frameDropCount++;
    }
  }

  int consumeFrameDrops() {
    final drops = _frameDropCount;
    _frameDropCount = 0;
    return drops;
  }

  /// Returns current memory usage in MB using [ProcessInfo.currentRss].
  /// This is the resident set size (physical RAM allocated to the process),
  /// not the Dart heap size — on iOS this may be significantly higher than
  /// heap-only metrics.
  double get memoryUsageMb {
    try {
      return ProcessInfo.currentRss / (1024 * 1024);
    } catch (_) {
      return 0.0; // Not supported on web or some platforms.
    }
  }

  /// Attaches performance metrics to [event] in place.
  void enrichEvent(UnilitixEvent event) {
    event.memoryUsageMb = double.parse(memoryUsageMb.toStringAsFixed(1));
    event.frameDrops = consumeFrameDrops();
    // CPU % is not available in Dart — send 0.0
    event.cpuUsagePct = 0.0;
  }
}
