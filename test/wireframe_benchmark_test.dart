import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/capture/snapshot_capture.dart';

/// Performance budget of the sliced wireframe walk (2.7.4, kept in 3.0.0):
/// on a large tree the walk must finish in bounded time and never hold the
/// UI isolate for long, so frames and input are handled in between.
void main() {
  /// About 6000 elements: 600 list rows of icon, texts and a button.
  Widget largeTree() => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 600; i++)
                  Row(
                    children: [
                      const Icon(Icons.payments),
                      Expanded(child: Text('Payment $i')),
                      Text('NGN ${i * 100}'),
                      TextButton(onPressed: () {}, child: const Text('Open')),
                    ],
                  ),
              ],
            ),
          ),
        ),
      );

  /// Generous for slow CI runners in debug (JIT) mode; a regression to an
  /// unsliced or quadratic walk blows through both.
  const totalBudget = Duration(seconds: 5);
  const longestBlockBudget = Duration(milliseconds: 100);

  testWidgets('a large tree is walked in short slices within budget',
      (tester) async {
    await tester.pumpWidget(largeTree());
    final root = tester.binding.rootElement!;
    final capture = SnapshotCapture(
      onSnapshot: (_, __) {},
      intervalMs: 1000,
      maskInputs: true,
    );

    final result = await tester.runAsync(() async {
      // A zero-delay timer that measures how long the event loop is held.
      var longest = Duration.zero;
      final gap = Stopwatch()..start();
      final probe = Timer.periodic(Duration.zero, (_) {
        if (gap.elapsed > longest) longest = gap.elapsed;
        gap.reset();
      });
      final total = Stopwatch()..start();
      final walk = await capture.walk(root);
      total.stop();
      probe.cancel();
      return (walk, total.elapsed, longest);
    });

    final (walk, total, longest) = result!;
    expect(walk, isNotNull);
    expect(walk!.yields, greaterThan(0), reason: 'the walk was sliced');
    expect(total, lessThan(totalBudget));
    expect(longest, lessThan(longestBlockBudget),
        reason: 'the walk gives the event loop back every '
            '${capture.sliceBudget.inMilliseconds} ms');
    // Same output as the reference recursive walk.
    expect(
        jsonEncode(walk.children), jsonEncode(capture.walkSync(root).children));
    // ignore: avoid_print
    print('wireframe walk: ${total.inMilliseconds} ms, ${walk.yields} yields, '
        'longest block ${longest.inMilliseconds} ms, '
        '~${walk.approxBytes ~/ 1024} KB');
  });
}
