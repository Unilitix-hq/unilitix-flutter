import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/privacy/privacy_mask.dart';

/// Regression tests for the 2.1.0 screenshot masking fix: text inputs and
/// paragraphs must produce occlusion rectangles for pixel screenshots.
void main() {
  Widget host(Widget child) => MaterialApp(
        home: Scaffold(body: Center(child: child)),
      );

  bool covers(List<Rect> rects, Finder finder, WidgetTester t) {
    final box = t.renderObject<RenderBox>(finder);
    final target = box.localToGlobal(Offset.zero) & box.size;
    return rects.any((r) => r.contains(target.center));
  }

  testWidgets('a TextField is occluded when maskInputs is on', (tester) async {
    await tester.pumpWidget(host(const SizedBox(
      width: 200,
      child: TextField(decoration: InputDecoration(hintText: 'BVN')),
    )));
    await tester.pumpAndSettle();

    final rects = PrivacyRegistry.textRects(inputs: true, allText: false);
    expect(rects, isNotEmpty);
    expect(covers(rects, find.byType(EditableText), tester), isTrue);
  });

  testWidgets('a TextField is NOT exempted by UnilitixUnmasked',
      (tester) async {
    await tester.pumpWidget(host(const SizedBox(
      width: 200,
      child: UnilitixUnmasked(child: TextField()),
    )));
    await tester.pumpAndSettle();

    final rects = PrivacyRegistry.textRects(inputs: true, allText: true);
    expect(covers(rects, find.byType(EditableText), tester), isTrue);
  });

  testWidgets('maskAllText occludes Text; UnilitixUnmasked exempts it',
      (tester) async {
    await tester.pumpWidget(host(const Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('Balance: NGN 1,200,000'),
        UnilitixUnmasked(child: Text('Checkout')),
      ],
    )));
    await tester.pumpAndSettle();

    final rects = PrivacyRegistry.textRects(inputs: true, allText: true);
    expect(covers(rects, find.text('Balance: NGN 1,200,000'), tester), isTrue);
    expect(covers(rects, find.text('Checkout'), tester), isFalse);
  });

  testWidgets('with both flags off nothing is collected', (tester) async {
    await tester.pumpWidget(host(const Text('hello')));
    await tester.pumpAndSettle();
    expect(PrivacyRegistry.textRects(inputs: false, allText: false), isEmpty);
  });
}
