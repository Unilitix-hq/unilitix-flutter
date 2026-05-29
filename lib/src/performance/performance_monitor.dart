import 'dart:io';
import 'package:flutter/scheduler.dart';

import '../events/event.dart';

/// Tracks frame drops and memory usage.
class PerformanceMonitor {
  int _frameDropCount = 0;

  void start() {
    SchedulerBinding.instance.addTimingsCallback(_onTimings);
  }

  void stop() {
    SchedulerBinding.instance.removeTimingsCallback(_onTimings);
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

  double get memoryUsageMb {
    // ProcessInfo.currentRss is available in the Dart VM on both platforms.
    return ProcessInfo.currentRss / (1024 * 1024);
  }

  /// Attaches performance metrics to [event] in place.
  void enrichEvent(UnilitixEvent event) {
    event.memoryUsageMb = double.parse(memoryUsageMb.toStringAsFixed(1));
    event.frameDrops = consumeFrameDrops();
    // CPU % is not available in Dart — send 0.0
    event.cpuUsagePct = 0.0;
  }
}
