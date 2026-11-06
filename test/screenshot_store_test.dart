import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unilitix/src/capture/screenshot_capture.dart';
import 'package:unilitix/src/storage/event_database.dart';
import 'package:unilitix/src/storage/pending_screenshot.dart';

/// 2.7.4: stored screenshots are bounded by age and bytes, read in pages,
/// and found for every session; masks are padded and checked for movement.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final now = DateTime.now();

  Future<EventDatabase> open({int maxBytes = 1 << 30}) async {
    final db = EventDatabase(
      maxOfflineEvents: 1000,
      maxScreenshotsPerSession: 1000,
      maxScreenshotBytes: maxBytes,
      dbPath: inMemoryDatabasePath,
    );
    await db.open();
    expect(db.isAvailable, isTrue);
    return db;
  }

  PendingScreenshot shot(String session, int ordinal,
          {required DateTime at, int bytes = 100}) =>
      PendingScreenshot(
        sessionId: session,
        ordinal: ordinal,
        screenName: '/s',
        viewportWidth: 1,
        viewportHeight: 1,
        capturedAt: at.millisecondsSinceEpoch,
        imageBytes: Uint8List(bytes),
        createdAt: at.millisecondsSinceEpoch,
      );

  group('screenshot store', () {
    test('frames older than 7 days are purged', () async {
      final db = await open();
      await db.insertScreenshot(
          shot('a', 0, at: now.subtract(const Duration(days: 3))));
      await db.insertScreenshot(
          shot('b', 0, at: now.subtract(const Duration(hours: 1))));
      expect(await db.screenshotCount(), 2);
      await db.enforceScreenshotLimits(now: now.add(const Duration(days: 5)));
      final left = await db.getOldestPendingScreenshots(limit: 10);
      expect(left.single.sessionId, 'b');
      await db.close();
    });

    test('the byte cap deletes the oldest frames first', () async {
      final db = await open(maxBytes: 1000);
      for (var i = 0; i < 25; i++) {
        await db.insertScreenshot(
            shot('s', i, at: now.add(Duration(seconds: i)), bytes: 100));
      }
      expect(await db.screenshotBytes(), lessThanOrEqualTo(1000));
      final left = await db.getOldestPendingScreenshots(limit: 100);
      expect(left.map((s) => s.ordinal), List.generate(10, (i) => 15 + i));
      await db.close();
    });

    test('pages across sessions, oldest first', () async {
      final db = await open();
      await db.insertScreenshot(
          shot('new', 0, at: now.add(const Duration(minutes: 2))));
      await db.insertScreenshot(shot('old', 0, at: now));
      await db.insertScreenshot(
          shot('old', 1, at: now.add(const Duration(minutes: 1))));
      final page = await db.getOldestPendingScreenshots(limit: 2);
      expect(
          page.map((s) => '${s.sessionId}#${s.ordinal}'), ['old#0', 'old#1']);
      final perSession = await db.getPendingScreenshots('old', limit: 1);
      expect(perSession.single.ordinal, 0);
      await db.close();
    });
  });

  group('screenshot masks', () {
    test('every mask is padded by 2 px', () {
      final padded =
          ScreenshotCapture.padMasks([const Rect.fromLTRB(10, 20, 30, 40)]);
      expect(padded.single, const Rect.fromLTRB(8, 18, 32, 42));
    });

    test('masks that held still keep the frame', () {
      const a = [Rect.fromLTRB(0, 0, 100, 20), Rect.fromLTRB(0, 50, 80, 70)];
      const b = [
        Rect.fromLTRB(0.5, 0, 100, 20.9),
        Rect.fromLTRB(0, 50, 80, 70)
      ];
      expect(ScreenshotCapture.masksStable(a, b), isTrue);
    });

    test('a mask that moved more than 1 px drops the frame', () {
      const a = [Rect.fromLTRB(0, 100, 100, 120)];
      const scrolled = [Rect.fromLTRB(0, 96, 100, 116)];
      expect(ScreenshotCapture.masksStable(a, scrolled), isFalse);
    });

    test('a mask that appeared or vanished drops the frame', () {
      const a = [Rect.fromLTRB(0, 0, 10, 10)];
      expect(ScreenshotCapture.masksStable(a, const []), isFalse);
      expect(ScreenshotCapture.masksStable(const [], a), isFalse);
    });
  });
}
