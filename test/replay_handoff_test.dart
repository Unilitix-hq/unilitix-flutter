import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/capture/screenshot_capture.dart';
import 'package:unilitix/src/core/native_bridge.dart';
import 'package:unilitix/src/core/sdk_scope.dart';
import 'package:unilitix/unilitix.dart';

import 'support/fake_native.dart';

/// Session replay in 3.0.0: Dart finds the masks and walks the widget tree;
/// the plugin draws the frame and the native SDK stores and uploads both.
/// No image bytes cross the platform channel.
void main() {
  late FakeNative native;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Unilitix.debugReset();
    native = FakeNative()..install();
  });

  tearDown(() {
    Unilitix.debugReset();
    native.uninstall();
  });

  Widget wallet() => const MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Text('Balance'),
              UnilitixPrivate(
                child: SizedBox(
                    width: 200, height: 40, child: Text('NGN 120,000')),
              ),
              UnilitixUnmasked(child: Text('Send money')),
            ],
          ),
        ),
      );

  Future<NativeBridge> startedBridge() async {
    final bridge = NativeBridge();
    await bridge.start({'apiKey': 'k'});
    native.clear();
    return bridge;
  }

  testWidgets('a frame is drawn natively with the masks, then committed',
      (tester) async {
    await tester.pumpWidget(wallet());
    final bridge = await startedBridge();
    SdkScope.currentScreen = '/wallet';
    final capture = ScreenshotCapture(
        bridge: bridge, intervalMs: 0, maxWidth: 480, quality: 30);

    expect(await capture.captureOnce(), isTrue);

    final request = native.single('captureScreenshot');
    expect(request['maxWidth'], 480);
    expect(request['quality'], 30);
    final masks = (request['masks'] as List)
        .map((m) => (m as List).cast<double>())
        .map((m) => ui.Rect.fromLTRB(m[0], m[1], m[2], m[3]))
        .toList();
    final private = tester.getRect(find.byType(UnilitixPrivate));
    expect(masks.any((r) => r.contains(private.center)), isTrue,
        reason: 'the private subtree is painted over');
    expect(masks.any((r) => r.contains(tester.getCenter(find.text('Balance')))),
        isTrue,
        reason: 'maskAllText');
    expect(
        masks.any((r) => r.contains(tester.getCenter(find.text('Send money')))),
        isFalse,
        reason: 'UnilitixUnmasked is exempt');

    final commit = native.single('commitScreenshot');
    expect(commit['id'], 1);
    expect(commit['screen'], '/wallet');
    expect(commit['width'], 800, reason: 'logical viewport of the test view');
    expect(commit['height'], 600);
    expect(commit['timestampMs'], isA<int>());
    expect(native.pendingFrames, isEmpty);
    expect(native.named('discardScreenshot'), isEmpty);
  });

  testWidgets('a frame whose masks moved during the capture is discarded',
      (tester) async {
    await tester.pumpWidget(wallet());
    final bridge = await startedBridge();
    final capture = _MovingMasks(bridge);

    expect(await capture.captureOnce(), isFalse);
    expect(native.single('discardScreenshot'), {'id': 1});
    expect(native.named('commitScreenshot'), isEmpty);
    expect(native.pendingFrames, isEmpty);
  });

  testWidgets('no frame without a native capture', (tester) async {
    await tester.pumpWidget(wallet());
    final bridge = await startedBridge();
    native.screenshotsAvailable = false;
    final capture = ScreenshotCapture(
        bridge: bridge, intervalMs: 0, maxWidth: 480, quality: 30);
    expect(await capture.captureOnce(), isFalse);
    expect(native.named('commitScreenshot'), isEmpty);
  });

  testWidgets('wireframe snapshots go to addSnapshot, masked', (tester) async {
    await Unilitix.init('k',
        config: const UnilitixConfig(
          apiKey: 'k',
          autoTrackCrashes: false,
          captureScreenshots: false,
        ));
    await tester.pumpWidget(wallet());
    await Unilitix.screen('/wallet');
    native.clear();

    await tester.runAsync(() => Unilitix.debugSnapshots!.captureNow());

    final json = native.single('addSnapshot')['json'] as String;
    final snapshot = jsonDecode(json) as Map<String, dynamic>;
    expect(snapshot['screenName'], '/wallet');
    expect(snapshot['viewportWidth'], 800);
    expect(snapshot.containsKey('ordinal'), isFalse,
        reason: 'the native SDK numbers snapshots');
    expect(json, contains('"type":"masked"'));
    expect(json, isNot(contains('120,000')));
    expect(json, isNot(contains('Balance')), reason: 'maskAllText redacts');
    expect(json, contains('•••••••'));

    // An unchanged tree is not sent again.
    native.clear();
    await tester.runAsync(() => Unilitix.debugSnapshots!.captureNow());
    expect(native.named('addSnapshot'), isEmpty);
    Unilitix.debugReset();
  });

  testWidgets('a tap inside UnilitixPrivate is sent without its position',
      (tester) async {
    await Unilitix.init('k',
        config: const UnilitixConfig(
          apiKey: 'k',
          autoTrackCrashes: false,
          autoTrackRageTaps: false,
          captureScreenshots: false,
          captureSnapshots: false,
        ));
    await tester.pumpWidget(MaterialApp(
      builder: (context, child) => UnilitixWidget(child: child!),
      home: const Scaffold(
        body: Column(
          children: [
            UnilitixPrivate(child: SizedBox(width: 300, height: 200)),
            SizedBox(width: 300, height: 200),
          ],
        ),
      ),
    ));
    native.clear();

    await tester.tapAt(const Offset(50, 50));
    await tester.tapAt(const Offset(50, 300));

    final taps = native.named('recordTap').map((c) => c.arguments).toList();
    expect(taps, [
      {'type': 'TAP', 'screen': 'unknown', 'x': null, 'y': null},
      {'type': 'TAP', 'screen': 'unknown', 'x': 50.0, 'y': 300.0},
    ]);
    Unilitix.debugReset();
  });
}

/// Masks that move between the reads before and after the capture.
class _MovingMasks extends ScreenshotCapture {
  _MovingMasks(NativeBridge bridge)
      : super(bridge: bridge, intervalMs: 0, maxWidth: 480, quality: 30);

  var _reads = 0;

  @override
  List<ui.Rect>? collectMasks() => [
        ui.Rect.fromLTWH(0, 10.0 * _reads++, 100, 20),
      ];
}
