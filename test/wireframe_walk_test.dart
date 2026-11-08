import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/capture/snapshot_capture.dart';
import 'package:unilitix/src/capture/widget_kind.dart';
import 'package:unilitix/src/privacy/privacy_mask.dart';

/// 2.7.4: the wireframe walk runs in time-boxed slices on the UI isolate.
/// It must produce exactly what the old single recursive walk produced, give
/// the event loop back between slices, and give up when a frame lands
/// mid-walk.
void main() {
  Widget sample() => MaterialApp(
        home: Scaffold(
          appBar: AppBar(title: const Text('Wallet')),
          body: Column(
            children: [
              const Padding(
                padding: EdgeInsets.all(8),
                child: Text('Balance'),
              ),
              const UnilitixPrivate(child: Text('NGN 120,000')),
              Row(
                children: [
                  ElevatedButton(onPressed: () {}, child: const Text('Send')),
                  const SizedBox(width: 8),
                  IconButton(onPressed: () {}, icon: const Icon(Icons.add)),
                ],
              ),
              const SizedBox(width: 0, height: 10, child: Text('hidden')),
              const Expanded(
                child:
                    TextField(decoration: InputDecoration(hintText: 'Amount')),
              ),
            ],
          ),
        ),
      );

  SnapshotCapture capture(Duration budget) => SnapshotCapture(
        onSnapshot: (_, __) {},
        intervalMs: 1000,
        maskInputs: true,
        // Real text in the output, so the private and zero-size checks
        // below look at characters rather than redaction bullets.
        maskAllText: false,
        sliceBudget: budget,
      );

  testWidgets('sliced walk matches the recursive walk node for node',
      (tester) async {
    await tester.pumpWidget(sample());
    await tester.pumpAndSettle();
    final root = tester.binding.rootElement!;

    final reference = capture(const Duration(days: 1)).walkSync(root);
    final oneSlice = await tester
        .runAsync(() => capture(const Duration(days: 1)).walk(root));
    final sliced =
        await tester.runAsync(() => capture(Duration.zero).walk(root));

    expect(reference.children, isNotEmpty);
    expect(oneSlice, isNotNull);
    expect(sliced, isNotNull);
    expect(jsonEncode(oneSlice!.children), jsonEncode(reference.children));
    expect(jsonEncode(sliced!.children), jsonEncode(reference.children));
    expect(oneSlice.hash, reference.hash);
    expect(sliced.hash, reference.hash);
    expect(sliced.approxBytes, reference.approxBytes);

    expect(oneSlice.yields, 0, reason: 'fits in one slice');
    expect(sliced.yields, greaterThan(10),
        reason: 'a zero budget yields before every element');

    final json = jsonEncode(sliced.children);
    expect(json, contains('"type":"masked"'));
    expect(json, isNot(contains('120,000')));
    expect(json, isNot(contains('hidden')),
        reason: 'zero-size subtrees are skipped');
    expect(json, contains('"type":"ElevatedButton"'));
    expect(json, contains('Balance'));
  });

  testWidgets('the size estimate is close to the encoded size', (tester) async {
    await tester.pumpWidget(sample());
    await tester.pumpAndSettle();
    final walk =
        capture(const Duration(days: 1)).walkSync(tester.binding.rootElement!);
    final real = utf8.encode(jsonEncode(walk.children)).length;
    expect(walk.approxBytes, greaterThan(real * 0.6));
    expect(walk.approxBytes, lessThan(real * 2));
  });

  testWidgets(
      'a frame drawn mid-walk abandons it; a busy screen still '
      'completes after three tries', (tester) async {
    await tester.pumpWidget(sample());
    await tester.pumpAndSettle();
    final root = tester.binding.rootElement!;
    final c = capture(Duration.zero);

    Future<WireframeWalk?> walkWithFrame() async {
      final pending = c.walk(root); // yields before its first element
      SnapshotCapture.debugNoteFrame();
      return pending;
    }

    for (var i = 0; i < 3; i++) {
      expect(await tester.runAsync(walkWithFrame), isNull,
          reason: 'attempt $i is abandoned');
    }
    final fourth = await tester.runAsync(walkWithFrame);
    expect(fourth, isNotNull, reason: 'tolerant after three abandons');
    expect(jsonEncode(fourth!.children), jsonEncode(c.walkSync(root).children));

    // A clean walk resets the counter: the next interrupted one is dropped.
    expect(await tester.runAsync(walkWithFrame), isNull);
  });

  test('widgetKind caches by runtime type and still answers by type', () {
    const a = Text('a');
    const b = Text('b');
    expect(widgetKind(a), 'Text');
    final size = widgetKindCacheSize;
    expect(widgetKind(b), 'Text');
    expect(widgetKindCacheSize, size, reason: 'same type, no new entry');
    expect(widgetKind(const Center(child: a)), 'Center');
    expect(widgetKind(const Align(child: a)), 'Align');
    expect(widgetKind(const UnilitixPrivate(child: a)), 'UnilitixPrivate');
  });
}
