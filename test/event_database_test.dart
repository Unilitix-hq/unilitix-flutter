import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unilitix/src/storage/event_database.dart';
import 'package:unilitix/src/storage/pending_event.dart';

/// Runs the real sqflite code against an in-memory SQLite via
/// `sqflite_common_ffi`, so the queue caps and the write-ahead log are
/// tested as they run on device rather than through mocks.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<EventDatabase> open(
      {int maxEvents = 1000, int maxBytes = 1 << 30}) async {
    final db = EventDatabase(
      maxOfflineEvents: maxEvents,
      maxScreenshotsPerSession: 100,
      maxQueueBytes: maxBytes,
      dbPath: inMemoryDatabasePath,
    );
    await db.open();
    expect(db.isAvailable, isTrue, reason: 'ffi sqlite must open');
    return db;
  }

  PendingEvent batch(int n, {int at = 0, int bytes = 0}) => PendingEvent(
        sessionJson: '{"sessionId":"s"}',
        eventsJson:
            bytes > 0 ? 'x' * bytes : '[${List.filled(n, '{}').join(',')}]',
        eventCount: n,
        createdAt: at,
      );

  group('retry queue caps', () {
    test('evicts oldest batches once the event cap is exceeded', () async {
      final db = await open(maxEvents: 250);
      for (var i = 0; i < 5; i++) {
        await db.insertEvent(batch(100, at: i));
      }
      final stats = await db.queueStats();
      expect(stats.rows, 2, reason: '500 queued, cap 250 → oldest 3 go');
      expect(stats.events, 200);
      final left = await db.getOldestEvents(10);
      expect(left.map((e) => e.createdAt), [3, 4]);
      await db.close();
    });

    test('evicts by bytes independently of event count', () async {
      final db = await open(maxBytes: 2500);
      for (var i = 0; i < 4; i++) {
        await db.insertEvent(batch(1, at: i, bytes: 1000));
      }
      final stats = await db.queueStats();
      expect(stats.bytes, lessThanOrEqualTo(2500));
      expect(stats.rows, 2);
      await db.close();
    });

    test('a single oversized batch does not wedge the queue', () async {
      final db = await open(maxBytes: 100);
      await db.insertEvent(batch(1, at: 0, bytes: 500));
      // Over the cap but it is the only row: kept rather than looping.
      expect((await db.queueStats()).rows, 1);
      await db.insertEvent(batch(1, at: 1, bytes: 50));
      // Now the oversized one is the oldest and goes.
      final left = await db.getOldestEvents(10);
      expect(left.single.createdAt, 1);
      await db.close();
    });

    test('age purge removes rows older than maxQueueAge', () async {
      final db = await open();
      final now = DateTime(2026, 10, 17);
      await db.insertEvent(batch(1,
          at: now.subtract(const Duration(days: 8)).millisecondsSinceEpoch));
      await db.insertEvent(batch(1,
          at: now.subtract(const Duration(days: 1)).millisecondsSinceEpoch));
      await db.deleteEventsOlderThan(now.subtract(EventDatabase.maxQueueAge));
      expect((await db.queueStats()).rows, 1);
      await db.close();
    });
  });

  group('write-ahead log coalescing', () {
    test('inserts are held then written in one batch', () async {
      final db = await open();
      for (var i = 0; i < 20; i++) {
        db.walInsert('s', 'e$i', i, '{"i":$i}');
      }
      expect(db.walPendingCount, 20);
      expect(await db.walCount(), 0, reason: 'nothing on disk yet');
      await db.walFlush();
      expect(db.walPendingCount, 0);
      expect(await db.walCount(), 20);
      await db.close();
    });

    test('the coalesce timer writes without an explicit flush', () async {
      final db = await open();
      db.walInsert('s', 'e1', 0, '{}');
      await Future<void>.delayed(
          EventDatabase.walCoalesceWindow + const Duration(milliseconds: 50));
      expect(await db.walCount(), 1);
      await db.close();
    });

    test('walDelete never runs ahead of a queued insert', () async {
      final db = await open();
      db.walInsert('s', 'e1', 0, '{}');
      await db.walDelete(['e1']);
      expect(await db.walCount(), 0);
      await db.close();
    });

    test('recovery folds held rows into one batch per session with a count',
        () async {
      final db = await open();
      db.walInsert('a', 'e1', 0, '{"n":1}');
      db.walInsert('a', 'e2', 1, '{"n":2}');
      db.walInsert('b', 'e3', 0, '{"n":3}');
      final n = await db.recoverWalToPending();
      expect(n, 3);
      final rows = await db.getOldestEvents(10);
      expect(rows.length, 2);
      expect(rows.map((r) => r.eventCount).toList()..sort(), [1, 2]);
      expect(await db.walCount(), 0);
      await db.close();
    });

    test('purgeAll drops held rows too', () async {
      final db = await open();
      db.walInsert('s', 'e1', 0, '{}');
      await db.purgeAll();
      expect(db.walPendingCount, 0);
      expect(await db.walCount(), 0);
      await db.close();
    });
  });
}
