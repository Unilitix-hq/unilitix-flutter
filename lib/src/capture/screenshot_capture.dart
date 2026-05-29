import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

import '../logger/logger.dart';
import '../core/sdk_scope.dart';

/// Captures screenshots via [RepaintBoundary.toImage].
class ScreenshotCapture {
  final GlobalKey repaintKey;
  final int intervalMs;
  final int maxScreenshots;
  final int maxWidth;
  final Future<void> Function(
    Uint8List bytes,
    String screenName,
    int ordinal,
    int viewportWidth,
    int viewportHeight,
    int capturedAt,
  ) onCapture;

  int _ordinal = 0;
  Timer? _timer;

  ScreenshotCapture({
    required this.repaintKey,
    required this.intervalMs,
    required this.maxScreenshots,
    required this.maxWidth,
    required this.onCapture,
  });

  void start() {
    _timer = Timer.periodic(
      Duration(milliseconds: intervalMs),
      (_) => _capture(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void resetOrdinal() => _ordinal = 0;

  Future<void> _capture() async {
    if (_ordinal >= maxScreenshots) return;

    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return;

    try {
      final image = await boundary.toImage(pixelRatio: 1.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData == null) return;

      final bytes = byteData.buffer.asUint8List();
      final screen = SdkScope.currentScreen ?? 'unknown';
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final w = (view.physicalSize.width / view.devicePixelRatio).round();
      final h = (view.physicalSize.height / view.devicePixelRatio).round();
      final capturedAt = DateTime.now().millisecondsSinceEpoch;

      await onCapture(bytes, screen, _ordinal, w, h, capturedAt);
      _ordinal++;
      image.dispose();
    } catch (e) {
      UnilitixLogger.e('Screenshot capture failed', e);
    }
  }
}
