import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:image/image.dart' as img;

import '../logger/logger.dart';
import '../core/sdk_scope.dart';

/// Captures screenshots and encodes them as JPEG.
///
/// Uses native PixelCopy (Android API 26+) as the primary path — it reads
/// directly from the window compositor and is immune to Impeller/Vulkan
/// DEVICE_LOCAL texture issues.  Falls back to [RepaintBoundary.toImage]
/// with an [endOfFrame] GPU flush barrier when native is unavailable (iOS,
/// Android < 26, or any platform error).
///
/// Scheduling uses [SchedulerBinding.addPostFrameCallback] instead of a
/// [Timer] so captures are always frame-synchronised and stop automatically
/// when the app is backgrounded (no frames → no callbacks).
class ScreenshotCapture with WidgetsBindingObserver {
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
  bool _active = false;
  int _lastCaptureMs = 0;

  static const _nativeChannel = MethodChannel('unilitix/screenshot');

  ScreenshotCapture({
    required this.repaintKey,
    required this.intervalMs,
    required this.maxScreenshots,
    required this.maxWidth,
    required this.quality,
    required this.onCapture,
  });

  void start() {
    _active = true;
    _lastCaptureMs = 0;
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  void stop() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  void resetOrdinal() {
    _ordinal = 0;
    // Re-anchor the callback chain — session resets happen on foreground resume.
    if (_active) SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _active) {
      // The post-frame chain breaks when Flutter stops rendering in background.
      // Re-register on resume so captures continue in the same session.
      SchedulerBinding.instance.addPostFrameCallback(_onFrame);
    }
  }

  void _onFrame(Duration _) {
    if (!_active) return;
    // Re-register before capture so the chain continues even if capture throws.
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);

    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCaptureMs >= intervalMs) {
      _lastCaptureMs = now;
      _capture(); // not awaited — _isCapturing guards re-entrancy
    }
  }

  Future<void> _capture() async {
    if (_ordinal >= maxScreenshots) return;
    if (_isCapturing) return;
    _isCapturing = true;
    final ordinal = _ordinal++;

    try {
      // Stage 1: native PixelCopy — reads from the window compositor, Impeller-safe.
      Uint8List? jpegBytes = await _tryNativeCapture();

      // Stage 2: Dart RepaintBoundary fallback with Impeller endOfFrame flush.
      jpegBytes ??= await _tryDartCapture();

      if (jpegBytes == null) return;

      final screen = SdkScope.currentScreen ?? 'unknown';
      final view = SchedulerBinding.instance.platformDispatcher.views.first;
      final w = (view.physicalSize.width / view.devicePixelRatio).round();
      final h = (view.physicalSize.height / view.devicePixelRatio).round();
      final capturedAt = DateTime.now().millisecondsSinceEpoch;

      await onCapture(jpegBytes, screen, ordinal, w, h, capturedAt);
    } catch (e) {
      UnilitixLogger.e('Screenshot capture failed', e);
    } finally {
      _isCapturing = false;
    }
  }

  /// Calls the Android-native PixelCopy channel (API 26+).
  /// Returns PNG bytes re-encoded as JPEG, or null on any error / unsupported platform.
  Future<Uint8List?> _tryNativeCapture() async {
    try {
      final pngBytes =
          await _nativeChannel.invokeMethod<Uint8List>('captureScreenshot');
      if (pngBytes == null) return null;

      final decoded = img.decodePng(pngBytes);
      if (decoded == null) return null;

      final resized =
          decoded.width > maxWidth ? img.copyResize(decoded, width: maxWidth) : decoded;
      return Uint8List.fromList(img.encodeJpg(resized, quality: quality));
    } catch (_) {
      // MissingPluginException on iOS, null result on Android < 26, or any error.
      return null;
    }
  }

  /// RepaintBoundary → rawRgba → JPEG with an [endOfFrame] GPU flush barrier.
  /// The barrier lets Impeller's Vulkan command buffer drain before pixel readback,
  /// preventing the black frames caused by reading DEVICE_LOCAL GPU texture data.
  Future<Uint8List?> _tryDartCapture() async {
    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    ui.Image? uiImage;
    try {
      final dpr =
          SchedulerBinding.instance.platformDispatcher.views.first.devicePixelRatio;
      // Half device DPR keeps texture size manageable; clamp ensures 1x–2x range.
      final captureRatio = (dpr * 0.5).clamp(1.0, 2.0);

      uiImage = await boundary.toImage(pixelRatio: captureRatio);

      // Flush Impeller's GPU pipeline before reading pixels back to CPU.
      await SchedulerBinding.instance.endOfFrame;

      final byteData =
          await uiImage.toByteData(format: ui.ImageByteFormat.rawRgba);
      if (byteData == null) return null;

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

      return Uint8List.fromList(img.encodeJpg(imgObj, quality: quality));
    } catch (e) {
      UnilitixLogger.e('Dart screenshot capture failed', e);
      return null;
    } finally {
      uiImage?.dispose();
    }
  }
}
