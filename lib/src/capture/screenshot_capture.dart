import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

import '../core/native_bridge.dart';
import '../core/sdk_scope.dart';
import '../logger/logger.dart';
import '../privacy/privacy_mask.dart';

/// Takes masked screenshots for session replay and hands them to the native
/// SDK, which stores, samples, caps and uploads them (3.0.0).
///
/// Dart decides *when* (change-driven: navigation, taps and wireframe
/// changes mark the screen dirty; at most one frame per [intervalMs], a
/// heartbeat every [heartbeatMs] on a static screen, at most [maxPerMinute])
/// and *what to hide* (the masks: [UnilitixPrivate], text, inputs, images,
/// platform views — only the widget tree knows them). The plugin does the
/// pixels: it draws the window with the masks painted in the same pass,
/// downscales and encodes JPEG off the main thread, and keeps the frame
/// natively; no image bytes cross the platform channel.
///
/// Masks are read before the capture and again once the plugin has the
/// frame. If they moved (a scroll or transition in between), the frame
/// could show text beside its mask: it is discarded natively
/// (`discardScreenshot`) and the screen stays dirty. Otherwise it is
/// committed (`commitScreenshot`), which hands it to the native SDK's
/// `captureExternalScreenshot`.
class ScreenshotCapture with WidgetsBindingObserver {
  ScreenshotCapture({
    required this.bridge,
    required this.intervalMs,
    required this.maxWidth,
    required this.quality,
    this.maxScreenshots = 1500,
    this.maxPerMinute = 20,
    this.heartbeatMs = 10000,
    this.maskScreenshots = true,
    this.maskImages = false,
    this.maskInputs = true,
    this.maskAllText = true,
    int Function()? clock,
  }) : _clock = clock ?? _wallClock;

  final NativeBridge bridge;
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
  final int Function() _clock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  int _count = 0;
  bool _isCapturing = false;
  bool _active = false;
  bool _dirty = true;
  int _lastCaptureMs = 0;
  final List<int> _recentCaptureMs = [];

  /// Frames committed in the current session (the native SDK keeps the
  /// authoritative count and cap).
  int get committed => _count;

  bool get isActive => _active;

  void start() {
    if (_active) return;
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

  /// A new native session started.
  void resetSession() {
    _count = 0;
    _recentCaptureMs.clear();
    _dirty = true;
    if (_active) SchedulerBinding.instance.addPostFrameCallback(_onFrame);
  }

  /// Marks the screen as changed; the next frame after [intervalMs] is taken.
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
    final now = _clock();
    final since = now - _lastCaptureMs;
    final wanted = (_dirty && since >= intervalMs) || since >= heartbeatMs;
    if (!wanted || !_withinBudget(now)) return;
    _dirty = false;
    _lastCaptureMs = now;
    unawaited(captureOnce());
  }

  bool _withinBudget(int now) {
    _recentCaptureMs.removeWhere((t) => now - t > 60000);
    if (_recentCaptureMs.length >= maxPerMinute) return false;
    _recentCaptureMs.add(now);
    return true;
  }

  /// Takes one frame now (not waiting for a dirty screen). Returns true
  /// when a frame was committed to the native SDK.
  @visibleForTesting
  Future<bool> captureOnce() async {
    if (_count >= maxScreenshots || _isCapturing) return false;
    _isCapturing = true;
    try {
      final before = collectMasks();
      if (before == null) return false; // never send a frame we could not mask
      final view = SchedulerBinding.instance.platformDispatcher.views.first;
      final dpr = view.devicePixelRatio;
      final capturedAt = _clock();
      final screen = SdkScope.currentScreen;
      final handle = await bridge.query<Map<Object?, Object?>>(
        'captureScreenshot',
        {
          'maxWidth': maxWidth,
          'quality': quality,
          'scale': dpr,
          'masks': [
            for (final r in padMasks(before)) [r.left, r.top, r.right, r.bottom]
          ],
        },
      );
      final id = handle?['id'];
      if (id is! int) return false;

      final after = collectMasks();
      if (after == null || !masksStable(before, after)) {
        _dirty = true;
        bridge.send('discardScreenshot', {'id': id});
        UnilitixLogger.d('Screen moved during capture — frame dropped');
        return false;
      }
      bridge.send('commitScreenshot', {
        'id': id,
        // Viewport in logical pixels (the replay's coordinate space).
        'width': (view.physicalSize.width / dpr).round(),
        'height': (view.physicalSize.height / dpr).round(),
        'timestampMs': capturedAt,
        'screen': screen,
      });
      _count++;
      return true;
    } catch (e) {
      UnilitixLogger.e('Screenshot capture failed', e);
      return false;
    } finally {
      _isCapturing = false;
    }
  }

  /// Logical pixels added on every side of each mask, to cover
  /// anti-aliasing and sub-pixel rounding between layout and the encoder.
  static const double maskPadding = 2.0;

  /// Largest movement, in logical pixels, of any mask edge between the
  /// start and end of a capture for the frame to be kept.
  static const double maskTolerance = 1.0;

  /// [masks], each grown by [maskPadding] on every side.
  @visibleForTesting
  static List<ui.Rect> padMasks(List<ui.Rect> masks) =>
      [for (final r in masks) r.inflate(maskPadding)];

  /// Whether the masks read after a capture match those read before it.
  @visibleForTesting
  static bool masksStable(List<ui.Rect> before, List<ui.Rect> after) {
    if (before.length != after.length) return false;
    for (var i = 0; i < before.length; i++) {
      final a = before[i];
      final b = after[i];
      if ((a.left - b.left).abs() > maskTolerance ||
          (a.top - b.top).abs() > maskTolerance ||
          (a.right - b.right).abs() > maskTolerance ||
          (a.bottom - b.bottom).abs() > maskTolerance) {
        return false;
      }
    }
    return true;
  }

  /// Regions painted over before the frame is encoded, in logical pixels:
  /// every [UnilitixPrivate] subtree; every text input when [maskInputs] is
  /// on; every paragraph of text when [maskAllText] is on (minus
  /// [UnilitixUnmasked] subtrees); every image when [maskImages] is on;
  /// every platform view (WebView, map, video) always. Null when
  /// collection failed: the frame is then not taken.
  @visibleForTesting
  List<ui.Rect>? collectMasks() {
    if (!maskScreenshots) return const [];
    try {
      final rects = <ui.Rect>[...PrivacyRegistry.privateRects()];
      rects.addAll(
          PrivacyRegistry.textRects(inputs: maskInputs, allText: maskAllText));
      if (maskImages) rects.addAll(PrivacyRegistry.imageRects());
      rects.addAll(PrivacyRegistry.platformViewRects());
      return rects;
    } catch (e) {
      UnilitixLogger.w('Mask collection failed — frame skipped: $e');
      return null;
    }
  }
}
