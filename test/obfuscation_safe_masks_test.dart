import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/capture/widget_kind.dart';
import 'package:unilitix/src/privacy/privacy_mask.dart';

/// 2.7.3: masks and wireframes decided by type, not by runtimeType names
/// (which `--obfuscate` mangles), and platform views always masked.
class _FakeController extends PlatformViewController {
  _FakeController(this.viewId);

  @override
  final int viewId;

  @override
  Future<void> dispatchPointerEvent(PointerEvent event) async {}

  @override
  Future<void> clearFocus() async {}

  @override
  Future<void> dispose() async {}
}

Widget _fakePlatformView() => PlatformViewLink(
      viewType: 'test/webview',
      surfaceFactory: (context, controller) => PlatformViewSurface(
        controller: controller,
        hitTestBehavior: PlatformViewHitTestBehavior.opaque,
        gestureRecognizers: const <Factory<OneSequenceGestureRecognizer>>{},
      ),
      onCreatePlatformView: (params) {
        params.onPlatformViewCreated(params.id);
        return _FakeController(params.id);
      },
    );

void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  group('widgetKind', () {
    test('subclasses are named before their parents', () {
      expect(widgetKind(const Center()), 'Center');
      expect(widgetKind(const Align()), 'Align');
      expect(widgetKind(Expanded(child: Container())), 'Expanded');
      expect(widgetKind(const Row()), 'Row');
      expect(widgetKind(const Column()), 'Column');
      expect(widgetKind(InkWell(onTap: () {})), 'InkWell');
      expect(widgetKind(const AlertDialog()), 'AlertDialog');
      expect(widgetKind(const VerticalDivider()), 'VerticalDivider');
    });

    test('factory constructors keep their family name', () {
      // ElevatedButton.icon builds a private subclass whose runtimeType is
      // not "ElevatedButton"; the type check still matches.
      final b = ElevatedButton.icon(
          onPressed: () {},
          icon: const Icon(Icons.add),
          label: const Text('x'));
      expect(widgetKind(b), 'ElevatedButton');
    });

    test('UnilitixPrivate and platform views are recognised by type', () {
      expect(widgetKind(const UnilitixPrivate(child: SizedBox())),
          'UnilitixPrivate');
      expect(widgetKind(_fakePlatformView()), kPlatformViewKind);
    });

    test('unknown widgets fall back to their runtime type', () {
      expect(widgetKind(const _Custom()), '_Custom');
    });
  });

  test('isImageWidget matches image widgets by type', () {
    const img = AssetImage('not-loaded.png');
    expect(PrivacyRegistry.isImageWidget(const Image(image: img)), isTrue);
    expect(PrivacyRegistry.isImageWidget(const RawImage()), isTrue);
    expect(
        PrivacyRegistry.isImageWidget(
            const FadeInImage(placeholder: img, image: img)),
        isTrue);
    expect(PrivacyRegistry.isImageWidget(const CircleAvatar()), isTrue);
    expect(PrivacyRegistry.isImageWidget(const Text('x')), isFalse);
  });

  testWidgets('a platform view is always in the screenshot masks',
      (tester) async {
    await tester.pumpWidget(host(SizedBox(
      width: 300,
      height: 200,
      child: _fakePlatformView(),
    )));
    await tester.pump();

    final rects = PrivacyRegistry.platformViewRects();
    expect(rects, hasLength(1));
    expect(rects.single.width, 300);
    expect(rects.single.height, 200);
  });

  testWidgets('no platform view, no platform-view masks', (tester) async {
    await tester.pumpWidget(host(const Text('hello')));
    expect(PrivacyRegistry.platformViewRects(), isEmpty);
  });
}

class _Custom extends StatelessWidget {
  const _Custom();

  @override
  Widget build(BuildContext context) => const SizedBox();
}
