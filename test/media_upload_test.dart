import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unilitix/src/capture/snapshot_buffer.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/events/event_buffer.dart';
import 'package:unilitix/src/flush/flush_scheduler.dart';
import 'package:unilitix/src/network/api_client.dart';
import 'package:unilitix/src/network/network_monitor.dart';
import 'package:unilitix/src/performance/performance_monitor.dart';
import 'package:unilitix/src/session/session_manager.dart';
import 'package:unilitix/src/storage/event_database.dart';
import 'package:unilitix/src/storage/pending_screenshot.dart';

/// 2.7.4: bounded wireframe buffer and chunked uploads, screenshots of
/// earlier sessions, and 402 handled as a pause rather than a rejection.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Map<String, dynamic> snapshot(int i, {int textLength = 1000}) => {
        'ordinal': i,
        'hierarchy': {
          'type': 'Root',
          'children': [
            {'type': 'Text', 'text': 'x' * textLength},
          ],
        },
      };

  group('SnapshotBuffer', () {
    test('estimateJsonBytes tracks the encoded size', () {
      final s = {
        ...snapshot(1),
        'nested': [
          1,
          2.5,
          true,
          null,
          {'t': '•••'}
        ],
      };
      final real = utf8.encode(jsonEncode(s)).length;
      final est = estimateJsonBytes(s);
      expect(est, inInclusiveRange((real * 0.9).floor(), (real * 1.1).ceil()));
    });

    test('drops the oldest once the byte cap is passed', () {
      final b = SnapshotBuffer(capacity: 1000, maxBytes: 10000);
      for (var i = 0; i < 30; i++) {
        b.add(snapshot(i), approxBytes: 1000);
      }
      expect(b.length, 10);
      expect(b.bytes, 10000);
      expect(b.drain().first['ordinal'], 20, reason: 'oldest went first');
    });

    test('the count cap still applies', () {
      final b = SnapshotBuffer(capacity: 3);
      for (var i = 0; i < 5; i++) {
        b.add(snapshot(i, textLength: 1));
      }
      expect(b.drain().map((s) => s['ordinal']), [2, 3, 4]);
    });

    test('takeChunk respects bytes and count, and always takes one', () {
      final b = SnapshotBuffer(capacity: 1000, maxBytes: 1 << 30);
      for (var i = 0; i < 10; i++) {
        b.add(snapshot(i), approxBytes: 100);
      }
      expect(b.takeChunk(maxBytes: 350, maxCount: 50).length, 3);
      expect(b.takeChunk(maxBytes: 1 << 20, maxCount: 4).length, 4);
      b.add(snapshot(99), approxBytes: 5000);
      final rest = b.takeChunk(maxBytes: 1000, maxCount: 50);
      expect(rest.length, 3, reason: 'stops before the 5 KB one');
      final big = b.takeChunk(maxBytes: 10, maxCount: 50);
      expect(big.single.data['ordinal'], 99, reason: 'oversized is not stuck');
      expect(b.length, 0);
      expect(b.bytes, 0);
    });

    test('requeueFront restores order and re-applies the caps', () {
      final b = SnapshotBuffer(capacity: 1000, maxBytes: 500);
      for (var i = 0; i < 5; i++) {
        b.add(snapshot(i), approxBytes: 100);
      }
      final chunk = b.takeChunk(maxBytes: 250, maxCount: 50); // 0, 1
      b.add(snapshot(5), approxBytes: 100);
      b.add(snapshot(6), approxBytes: 100);
      b.requeueFront(chunk);
      // 0..6 = 700 bytes > 500: the two oldest (the re-queued ones) go.
      expect(b.drain().map((s) => s['ordinal']), [2, 3, 4, 5, 6]);
    });
  });

  group('ApiResult 402', () {
    test('is neither rejected nor retryable nor auth', () {
      const r = ApiResult(status: 402);
      expect(r.isPaymentRequired, isTrue);
      expect(r.rejected, isFalse);
      expect(r.retryable, isFalse);
      expect(r.isAuthFailure, isFalse);
      expect(const ApiResult(status: 400).rejected, isTrue);
    });
  });

  group('FlushScheduler media and 402', () {
    late DateTime clock;
    late List<http.Request> requests;
    late EventDatabase db;
    late EventBuffer buffer;
    late SessionManager sessions;
    late SnapshotBuffer snapshots;
    late FlushScheduler scheduler;
    late Future<http.Response> Function(http.Request) respond;

    setUp(() async {
      clock = DateTime(2026, 11, 6, 12);
      requests = [];
      respond = (_) async => http.Response('{}', 200);
      db = EventDatabase(
        maxOfflineEvents: 1000,
        maxScreenshotsPerSession: 100,
        dbPath: inMemoryDatabasePath,
      );
      await db.open();
      sessions = SessionManager(
        sessionTimeoutSeconds: 1800,
        onSessionStart: (_) {},
        onSessionEnd: (_) {},
        resetScreenshotOrdinal: () {},
      )..start();
      buffer = EventBuffer(batchSize: 100, onFlushNeeded: () {});
      snapshots = SnapshotBuffer(capacity: 1500);
      scheduler = FlushScheduler(
        intervalSeconds: 30,
        buffer: buffer,
        sessionManager: sessions,
        database: db,
        apiClient: ApiClient(
          apiKey: 'k',
          apiUrl: 'https://api.test',
          sdkVersion: 't',
          client: MockClient((req) {
            requests.add(req);
            return respond(req);
          }),
        ),
        networkMonitor: NetworkMonitor(onNetworkChanged: (_) {}),
        performanceMonitor: PerformanceMonitor(),
        buildSessionPayload: () async =>
            {'sessionId': sessions.currentSession!.id},
        uploadScreenshotsOnWifiOnly: false,
        snapshotBuffer: snapshots,
        now: () => clock,
      );
    });

    tearDown(() async {
      sessions.stop();
      await db.close();
    });

    Iterable<http.Request> to(String suffix) =>
        requests.where((r) => r.url.path.endsWith(suffix));

    Map<String, dynamic> body(http.Request r) =>
        jsonDecode(utf8.decode(gzip.decode(r.bodyBytes)))
            as Map<String, dynamic>;

    /// Media stages run in the background of flush(); wait for them.
    Future<void> settle(bool Function() done) async {
      for (var i = 0; i < 200 && !done(); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 25));
      }
    }

    test('a wireframe backlog goes up in bounded chunks, in order', () async {
      // 120 snapshots of ~5 KB: 600 KB, more than one request may carry.
      for (var i = 0; i < 120; i++) {
        snapshots.add(snapshot(i, textLength: 5000));
      }
      int sent() => to('/snapshots')
          .fold(0, (n, r) => n + (body(r)['snapshots'] as List).length);
      await scheduler.flush();
      await settle(() => sent() == 120);

      final calls = to('/snapshots').toList();
      expect(calls.length, greaterThanOrEqualTo(3));
      final ordinals = <int>[];
      for (final c in calls) {
        final list = body(c)['snapshots'] as List;
        expect(
            list.length, lessThanOrEqualTo(FlushScheduler.snapshotChunkCount));
        expect(utf8.decode(gzip.decode(c.bodyBytes)).length,
            lessThan(FlushScheduler.snapshotChunkBytes * 1.2));
        ordinals.addAll(list.map((s) => (s as Map)['ordinal'] as int));
      }
      expect(ordinals, List.generate(120, (i) => i));
    });

    test('a failed chunk is re-queued at the front', () async {
      for (var i = 0; i < 5; i++) {
        snapshots.add(snapshot(i));
      }
      respond = (r) async => r.url.path.endsWith('/snapshots')
          ? http.Response('', 503)
          : http.Response('{}', 200);
      await scheduler.flush();
      await settle(() => to('/snapshots').isNotEmpty && snapshots.length == 5);
      expect(snapshots.drain().map((s) => s['ordinal']), [0, 1, 2, 3, 4]);
    });

    test('screenshots of an earlier session are uploaded', () async {
      await db.insertScreenshot(PendingScreenshot(
        sessionId: 'earlier-session',
        ordinal: 0,
        screenName: '/home',
        viewportWidth: 360,
        viewportHeight: 640,
        capturedAt: clock.millisecondsSinceEpoch,
        imageBytes: Uint8List.fromList([0xFF, 0xD8, 0xFF, 1, 2, 3]),
        createdAt: DateTime.now().millisecondsSinceEpoch,
      ));
      respond = (r) async {
        if (r.url.path.endsWith('/screenshots/init')) {
          return http.Response(
              jsonEncode({
                'slots': [
                  {
                    'ordinal': 0,
                    'presignedUrl': 'https://bucket.test/0',
                    'r2Key': 'k0',
                  }
                ]
              }),
              200);
        }
        return http.Response('{}', 200);
      };
      await scheduler.flush();
      await settle(() => to('/screenshots/confirm').isNotEmpty);

      final init = to('/screenshots/init').single;
      expect(body(init)['sessionId'], 'earlier-session');
      expect(requests.where((r) => r.url.host == 'bucket.test'), hasLength(1));
      expect(await db.screenshotCount(), 0);
    });

    test('402 keeps the batch and pauses for 15 minutes', () async {
      respond = (r) async => r.url.path.endsWith('/events')
          ? http.Response('', 402)
          : http.Response('{}', 200);
      buffer.emit(UnilitixEvent(type: EventTypes.tap));
      await scheduler.flush();

      expect((await db.queueStats()).rows, 1, reason: 'kept, not dropped');
      expect(scheduler.backoffUntil, clock.add(ApiResult.paymentBackoff));
      expect(scheduler.consecutiveFailures, 0);

      final before = requests.length;
      clock = clock.add(const Duration(minutes: 10));
      await scheduler.flush();
      expect(requests.length, before, reason: 'still paused');

      clock = clock.add(const Duration(minutes: 6));
      respond = (_) async => http.Response('{}', 200);
      await scheduler.flush();
      expect((await db.queueStats()).rows, 0, reason: 'sent after the pause');
    });

    test('402 honours Retry-After', () async {
      respond =
          (_) async => http.Response('', 402, headers: {'retry-after': '3600'});
      await scheduler.flush();
      expect(scheduler.backoffUntil, clock.add(const Duration(hours: 1)));
    });

    test('402 on a retry does not spend the batch retry budget', () async {
      respond = (r) async => r.url.path.endsWith('/events')
          ? http.Response('', 503)
          : http.Response('{}', 200);
      buffer.emit(UnilitixEvent(type: EventTypes.tap));
      await scheduler.flush();
      expect((await db.queueStats()).rows, 1);

      clock = clock.add(const Duration(minutes: 10));
      respond = (r) async => r.url.path.endsWith('/events')
          ? http.Response('', 402)
          : http.Response('{}', 200);
      await scheduler.flush();
      final rows = await db.getOldestEvents(10);
      expect(rows.single.retryCount, 0);
    });
  });
}
