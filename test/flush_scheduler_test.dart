import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/events/event_buffer.dart';
import 'package:unilitix/src/flush/flush_scheduler.dart';
import 'package:unilitix/src/network/api_client.dart';
import 'package:unilitix/src/network/network_monitor.dart';
import 'package:unilitix/src/network/retry_policy.dart';
import 'package:unilitix/src/performance/performance_monitor.dart';
import 'package:unilitix/src/session/session_manager.dart';
import 'package:unilitix/src/storage/event_database.dart';
import 'package:unilitix/src/storage/pending_event.dart';

/// One request per cycle, scheduler-level backoff, 4xx drops, no session
/// reset on 400, and session upserts only when the record changed — the
/// 2.1.1 reliability contract, exercised end to end through a MockClient
/// and an in-memory SQLite.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  group('ApiClient', () {
    ApiClient client(MockClientHandler h) => ApiClient(
          apiKey: 'k',
          apiUrl: 'https://api.test',
          sdkVersion: 't',
          client: MockClient(h),
        );

    test('makes exactly one request and classifies the status', () async {
      var calls = 0;
      final c = client((req) async {
        calls++;
        return http.Response('', 503, headers: {'retry-after': '7'});
      });
      final r = await c.ingestEvents(sessionId: 's', events: const []);
      expect(calls, 1, reason: 'no in-call retry loop');
      expect(r.ok, isFalse);
      expect(r.retryable, isTrue);
      expect(r.rejected, isFalse);
      expect(r.retryAfterSeconds, 7);
    });

    test('4xx other than 429/401/403 is a permanent rejection', () async {
      for (final s in [400, 404, 413, 422]) {
        final r = await client((_) async => http.Response('bad', s))
            .ingestEvents(sessionId: 's', events: const []);
        expect(r.rejected, isTrue, reason: '$s');
        expect(r.retryable, isFalse, reason: '$s');
      }
      final r429 = await client((_) async => http.Response('', 429))
          .ingestEvents(sessionId: 's', events: const []);
      expect(r429.retryable, isTrue);
      expect(r429.rejected, isFalse);
      final r401 = await client((_) async => http.Response('', 401))
          .ingestEvents(sessionId: 's', events: const []);
      expect(r401.isAuthFailure, isTrue);
      expect(r401.rejected, isFalse);
    });

    test('every transport failure becomes a result, never a throw', () async {
      final errors = <Object>[
        const SocketException('refused'),
        http.ClientException('closed'),
        const HttpException('Connection closed before full header'),
        TimeoutException('t'),
        const HandshakeException('tls'),
      ];
      for (final e in errors) {
        final r = await client((_) async => throw e)
            .ingestSession(const {'sessionId': 's'});
        expect(r.status, isNull, reason: '$e');
        expect(r.retryable, isTrue, reason: '$e');
        expect(r.error, same(e));
      }
    });
  });

  group('RetryPolicy.isRetryable', () {
    test('transient vs permanent', () {
      expect(RetryPolicy.isRetryable(null), isTrue);
      expect(RetryPolicy.isRetryable(500), isTrue);
      expect(RetryPolicy.isRetryable(429), isTrue);
      expect(RetryPolicy.isRetryable(400), isFalse);
      expect(RetryPolicy.isRetryable(200), isFalse);
    });
  });

  group('FlushScheduler', () {
    late DateTime clock;
    late List<http.Request> requests;
    late EventDatabase db;
    late EventBuffer buffer;
    late SessionManager sessions;
    late FlushScheduler scheduler;
    late Future<http.Response> Function(http.Request) respond;
    late Map<String, dynamic> sessionPayload;

    Future<void> build() async {
      clock = DateTime(2026, 10, 17, 12);
      requests = [];
      db = EventDatabase(
        maxOfflineEvents: 1000,
        maxScreenshotsPerSession: 10,
        dbPath: inMemoryDatabasePath,
      );
      await db.open();
      sessions = SessionManager(
        sessionTimeoutSeconds: 1800,
        onSessionStart: (_) {},
        onSessionEnd: (_) {},
        resetScreenshotOrdinal: () {},
      )..start();
      sessionPayload = {
        'sessionId': sessions.currentSession!.id,
        'userId': null
      };
      buffer = EventBuffer(batchSize: 100, onFlushNeeded: () {});
      final api = ApiClient(
        apiKey: 'k',
        apiUrl: 'https://api.test',
        sdkVersion: 't',
        client: MockClient((req) {
          requests.add(req);
          return respond(req);
        }),
      );
      scheduler = FlushScheduler(
        intervalSeconds: 30,
        buffer: buffer,
        sessionManager: sessions,
        database: db,
        apiClient: api,
        networkMonitor: NetworkMonitor(onNetworkChanged: (_) {}),
        performanceMonitor: PerformanceMonitor(),
        buildSessionPayload: () async => sessionPayload,
        uploadScreenshotsOnWifiOnly: true,
        now: () => clock,
      );
    }

    setUp(build);
    tearDown(() async {
      sessions.stop();
      await db.close();
    });

    void emit([int n = 1]) {
      for (var i = 0; i < n; i++) {
        buffer.emit(UnilitixEvent(type: EventTypes.tap));
      }
    }

    List<String> paths() => requests.map((r) => r.url.path).toList();

    test('a 503 opens a backoff window; cycles inside it make no request',
        () async {
      respond = (_) async => http.Response('', 503);
      emit();
      await scheduler.flush();
      expect(paths(), ['/v1/ingest/session']);
      expect(scheduler.consecutiveFailures, 1);
      expect(scheduler.inBackoff, isTrue);
      expect(scheduler.backoffUntil!.difference(clock).inMilliseconds,
          inInclusiveRange(1000, 1200));

      await scheduler.flush();
      await scheduler.flush();
      expect(requests.length, 1, reason: 'still inside the window');

      clock = clock.add(const Duration(seconds: 2));
      await scheduler.flush();
      expect(requests.length, 2);
      expect(scheduler.consecutiveFailures, 2, reason: 'window grows');
    });

    test('Retry-After sets the window exactly', () async {
      respond =
          (_) async => http.Response('', 429, headers: {'retry-after': '45'});
      await scheduler.flush();
      expect(scheduler.backoffUntil, clock.add(const Duration(seconds: 45)));
    });

    test('one success clears the backoff state', () async {
      respond = (_) async => http.Response('', 500);
      await scheduler.flush();
      expect(scheduler.consecutiveFailures, 1);
      clock = clock.add(const Duration(minutes: 1));
      respond = (_) async => http.Response('{}', 200);
      await scheduler.flush();
      expect(scheduler.consecutiveFailures, 0);
      expect(scheduler.inBackoff, isFalse);
    });

    test('events that fail transiently are queued, then retried in order',
        () async {
      respond = (r) async =>
          http.Response('', r.url.path.endsWith('/session') ? 200 : 502);
      emit(3);
      await scheduler.flush();
      expect(paths(), ['/v1/ingest/session', '/v1/ingest/events']);
      final queued = await db.queueStats();
      expect(queued.rows, 1);
      expect(queued.events, 3);
      expect(await db.walCount(), 0, reason: 'WAL rows folded into the batch');

      clock = clock.add(const Duration(minutes: 5));
      respond = (_) async => http.Response('{}', 200);
      await scheduler.flush();
      expect((await db.queueStats()).rows, 0);
      final retried = requests.last;
      expect(retried.url.path, '/v1/ingest/events');
      final body = jsonDecode(utf8.decode(gzip.decode(retried.bodyBytes)));
      expect((body['events'] as List).length, 3);
    });

    test('a 4xx drops the batch instead of queueing it for a week', () async {
      respond = (r) async =>
          http.Response('', r.url.path.endsWith('/session') ? 200 : 422);
      emit(2);
      await scheduler.flush();
      expect((await db.queueStats()).rows, 0);
      expect(await db.walCount(), 0);
      expect(scheduler.inBackoff, isFalse, reason: 'server is healthy');
    });

    test('a queued batch that comes back 4xx on retry is deleted', () async {
      respond = (r) async =>
          http.Response('', r.url.path.endsWith('/session') ? 200 : 503);
      emit();
      await scheduler.flush();
      expect((await db.queueStats()).rows, 1);
      clock = clock.add(const Duration(minutes: 5));
      respond = (r) async =>
          http.Response('', r.url.path.endsWith('/session') ? 200 : 400);
      await scheduler.flush();
      expect((await db.queueStats()).rows, 0);
    });

    test('retry pass stops at the first transient failure', () async {
      respond = (r) async =>
          http.Response('', r.url.path.endsWith('/session') ? 200 : 503);
      for (var i = 0; i < 3; i++) {
        emit();
        clock = clock.add(const Duration(minutes: 6));
        await scheduler.flush();
      }
      expect((await db.queueStats()).rows, 3);
      requests.clear();
      clock = clock.add(const Duration(minutes: 6));
      await scheduler.flush();
      // One session upsert (refresh), one live events batch? No — buffer is
      // empty, so: session, then the first queued batch, then stop.
      expect(paths().where((p) => p.endsWith('/events')).length, 1);
    });

    test('400 on the session record does not reset the session', () async {
      respond = (_) async => http.Response('{"error":"bad"}', 400);
      final before = sessions.currentSession!.id;
      await scheduler.flush();
      expect(sessions.currentSession!.id, before);
      expect(scheduler.inBackoff, isFalse);
      // The identical record is not re-sent every cycle.
      await scheduler.flush();
      expect(requests.length, 1);
      // A changed record is.
      sessionPayload = {...sessionPayload, 'userId': 'u1'};
      await scheduler.flush();
      expect(requests.length, 2);
    });

    test('session is upserted once, then only when it changes or after 5 min',
        () async {
      respond = (_) async => http.Response('{}', 200);
      await scheduler.flush();
      await scheduler.flush();
      await scheduler.flush();
      expect(paths().where((p) => p.endsWith('/session')).length, 1);

      sessionPayload = {...sessionPayload, 'foregroundTimeMs': 9000};
      await scheduler.flush();
      expect(paths().where((p) => p.endsWith('/session')).length, 1,
          reason: 'volatile fields alone do not count');

      sessionPayload = {...sessionPayload, 'userId': 'u1'};
      await scheduler.flush();
      expect(paths().where((p) => p.endsWith('/session')).length, 2);

      clock = clock.add(const Duration(minutes: 6));
      await scheduler.flush();
      expect(paths().where((p) => p.endsWith('/session')).length, 3,
          reason: 'periodic refresh keeps durations current');
    });

    test('409 counts as an acknowledgement', () async {
      respond = (_) async => http.Response('', 409);
      emit();
      await scheduler.flush();
      expect(paths(), ['/v1/ingest/session', '/v1/ingest/events']);
      expect(scheduler.inBackoff, isFalse);
    });

    test('401 latches and stops every later cycle', () async {
      respond = (_) async => http.Response('', 401);
      await scheduler.flush();
      expect(scheduler.authRejected, isTrue);
      clock = clock.add(const Duration(hours: 1));
      await scheduler.flush();
      expect(requests.length, 1);
    });

    test('a corrupt queued row is deleted, not retried forever', () async {
      await db.insertEvent(PendingEvent(
        sessionJson: '{"sessionId":"s"}',
        eventsJson: '[{"truncated"',
        eventCount: 1,
        createdAt: 0,
      ));
      respond = (_) async => http.Response('{}', 200);
      await scheduler.flush();
      expect((await db.queueStats()).rows, 0);
      expect(paths().where((p) => p.endsWith('/events')), isEmpty);
    });
  });
}
