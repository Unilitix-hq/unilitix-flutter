import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import 'image_encode.dart';
import '../logger/logger.dart';
import '../core/sdk_scope.dart';
import '../privacy/privacy_mask.dart';

/// Captures screenshots and encodes them as JPEG.
///
/// Capture is change-driven, not timer-driven: a frame is taken when the UI
/// is marked dirty (navigation, tap, scroll, or the wireframe snapshot's
/// structural hash changing) and at least [intervalMs] has passed since the
/// last one. A quiet screen produces no frames; an idle heartbeat
/// ([heartbeatMs]) keeps long static screens represented in the replay.
///
/// On Android and iOS the native plugin does the image work (downscale,
/// occlusion, JPEG, with JPEG encoding off the main thread) and returns JPEG
/// bytes. Elsewhere
/// the [RepaintBoundary] fallback draws the frame through `dart:ui` and
/// returns PNG.
class ScreenshotCapture with WidgetsBindingObserver {
  final GlobalKey repaintKey;
  final int intervalMs;
  final int maxScreenshots;
  final int maxPerMinute;
  final int heartbeatMs;
  final int maxWidth;
  final int quality;
  final bool maskScreenshots;
  final bool maskImages;
  final bool maskInputs;
  final bool maskAllText;
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
  bool _dirty = true; // first frame of a session is always wanted
  int _lastCaptureMs = 0;
  final List<int> _recentCaptureMs = [];

  static const _nativeChannel = MethodChannel('unilitix/screenshot');

  ScreenshotCapture({
    required this.repaintKey,
    required this.intervalMs,
    required this.maxScreenshots,
    required this.maxWidth,
    required this.quality,
    required this.onCapture,
    this.maxPerMinute = 20,
    this.heartbeatMs = 10000,
    this.maskScreenshots = true,
    this.maskImages = false,
    this.maskInputs = true,
    this.maskAllText = true,
  });

  void start() {
    if (_active) return; // idempotent: consent changes may call this again
    _active = true;
    _lastCaptureMs = 0;
    _dirty = true;
    WidgetsBinding.instance.addObserver(this);
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  void stop() {
    _active = false;
    WidgetsBinding.instance.removeObserver(this);
  }

  void resetOrdinal() {
    _ordinal = 0;
    _recentCaptureMs.clear();
    _dirty = true;
    // Re-anchor the callback chain — session resets happen on foreground resume.
    if (_active) SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  /// Marks the screen as changed; the next frame after [intervalMs] is captured.
  void markDirty() => _dirty = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && _active) {
      _dirty = true;
      SchedulerBinding.instance.addPostFrameCallback(_onFrame);
    }
  }

  void _onFrame(Duration _) {
    if (!_active) return;
    SchedulerBinding.instance.addPostFrameCallback(_onFrame);

    final now = DateTime.now().millisecondsSinceEpoch;
    final since = now - _lastCaptureMs;
    final wanted = (_dirty && since >= intervalMs) || since >= heartbeatMs;
    if (!wanted) return;
    if (!_withinBudget(now)) return;

    _dirty = false;
    _lastCaptureMs = now;
    _capture(); // not awaited — _isCapturing guards re-entrancy
  }

  /// Rolling one-minute budget so a screen that redraws continuously (a
  /// ticker, an animation) cannot flood the session.
  bool _withinBudget(int now) {
    _recentCaptureMs.removeWhere((t) => now - t > 60000);
    if (_recentCaptureMs.length >= maxPerMinute) return false;
    _recentCaptureMs.add(now);
    return true;
  }

  Future<void> _capture() async {
    if (_ordinal >= maxScreenshots) return;
    if (_isCapturing) return;
    _isCapturing = true;
    final ordinal = _ordinal++;

    try {
      // Occlusion regions are read in the same frame the pixels come from.
      final masks = _collectMasks();
      if (masks == null) return; // never upload a frame we could not mask
      final view = SchedulerBinding.instance.platformDispatcher.views.first;
      final dpr = view.devicePixelRatio;

      Uint8List? jpegBytes = await _tryNativeCapture(masks, dpr);
      jpegBytes ??= await _tryDartCapture(masks);
      if (jpegBytes == null) return;

      final screen = SdkScope.currentScreen ?? 'unknown';
      final w = (view.physicalSize.width / dpr).round();
      final h = (view.physicalSize.height / dpr).round();
      await onCapture(jpegBytes, screen, ordinal, w, h,
          DateTime.now().millisecondsSinceEpoch);
    } catch (e) {
      UnilitixLogger.e('Screenshot capture failed', e);
    } finally {
      _isCapturing = false;
    }
  }

  /// Regions painted over before the frame is encoded, in logical pixels:
  /// every [UnilitixPrivate] subtree; every text input when [maskInputs] is
  /// on; every paragraph of text when [maskAllText] is on (minus
  /// [UnilitixUnmasked] subtrees); every image when [maskImages] is on.
  ///
  /// If collection fails the frame is dropped rather than sent unmasked.
  List<ui.Rect>? _collectMasks() {
    if (!maskScreenshots) return const [];
    try {
      final rects = <ui.Rect>[...PrivacyRegistry.privateRects()];
      rects.addAll(
          PrivacyRegistry.textRects(inputs: maskInputs, allText: maskAllText));
      if (maskImages) rects.addAll(PrivacyRegistry.imageRects());
      return rects;
    } catch (e) {
      UnilitixLogger.w('Mask collection failed — frame skipped: $e');
      return null;
    }
  }

  /// Native capture: PixelCopy on Android, drawHierarchy on iOS (through
  /// UnilitixCore, which paints the masks while drawing the downscaled
  /// frame). Either way the plugin returns JPEG.
  Future<Uint8List?> _tryNativeCapture(List<ui.Rect> masks, double dpr) async {
    try {
      return await _nativeChannel.invokeMethod<Uint8List>('captureScreenshot', {
        'maxWidth': maxWidth,
        'quality': quality,
        'scale': dpr,
        'masks': masks.map((r) => [r.left, r.top, r.right, r.bottom]).toList(),
      });
    } catch (_) {
      // MissingPluginException on unsupported platforms, or any native error.
      return null;
    }
  }

  /// RepaintBoundary → `ui.Image`, then downscale, occlusion and PNG encoding
  /// with `dart:ui` alone. An [endOfFrame] barrier lets Impeller drain before
  /// pixel readback.
  Future<Uint8List?> _tryDartCapture(List<ui.Rect> masks) async {
    final boundary =
        repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    ui.Image? uiImage;
    try {
      final view = SchedulerBinding.instance.platformDispatcher.views.first;
      final captureRatio = (view.devicePixelRatio * 0.5).clamp(1.0, 2.0);
      uiImage = await boundary.toImage(pixelRatio: captureRatio);
      await SchedulerBinding.instance.endOfFrame;

      // Masks are in logical px; the image is logical × captureRatio.
      final scaledMasks = masks
          .map((r) => ui.Rect.fromLTRB(
                r.left * captureRatio,
                r.top * captureRatio,
                r.right * captureRatio,
                r.bottom * captureRatio,
              ))
          .toList();
      return await encodeFrameUi(uiImage,
          maxWidth: maxWidth, masks: scaledMasks);
    } catch (e) {
      UnilitixLogger.e('Dart screenshot capture failed', e);
      return null;
    } finally {
      uiImage?.dispose();
    }
  }
}
