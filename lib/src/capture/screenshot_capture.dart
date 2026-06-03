import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../logger/logger.dart';
import '../core/sdk_scope.dart';

/// Captures screenshots via [RepaintBoundary.toImage] and encodes as JPEG.
class ScreenshotCapture {
  final GlobalKey repaintKey;
  final int intervalMs;
  final int maxScreenshots;
  final int maxWidth;
  final int quality;
  final Future<void> Function(
    Uint8List bytes,
    String screenName,
    int ordinal,
    int viewportWidth,
    int viewportHeight,
    int capturedAt,
  ) onCapture;

  int _ordinal = 0;
  bool _isCapturing = false;
  Timer? _timer;

  ScreenshotCapture({
    required this.repaintKey,
    required this.intervalMs,
    required this.maxScreenshots,
    required this.maxWidth,
    required this.quality,
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
    if (_isCapturing) return;
    _isCapturing = true;

    // Increment before any await to avoid ordinal races.
    final ordinal = _ordinal++;

    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) {
      _isCapturing = false;
      return;
    }

    ui.Image? uiImage;
    try {
      uiImage = await boundary.toImage(pixelRatio: 1.0);
      final byteData =
          await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return;

      final rawBytes = byteData.buffer.asUint8List();
      var imgObj = img.Image.fromBytes(
        width: uiImage.width,
        height: uiImage.height,
        bytes: rawBytes.buffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );

      if (imgObj.width > maxWidth) {
        imgObj = img.copyResize(imgObj, width: maxWidth);
      }

      final jpegBytes = Uint8List.fromList(
        img.encodeJpg(imgObj, quality: quality),
      );

      final screen = SdkScope.currentScreen ?? 'unknown';
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final w = (view.physicalSize.width / view.devicePixelRatio).round();
      final h = (view.physicalSize.height / view.devicePixelRatio).round();
      final capturedAt = DateTime.now().millisecondsSinceEpoch;

      await onCapture(jpegBytes, screen, ordinal, w, h, capturedAt);
    } catch (e) {
      UnilitixLogger.e('Screenshot capture failed', e);
    } finally {
      uiImage?.dispose();
      _isCapturing = false;
    }
  }
}
