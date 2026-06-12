import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/unilitix.dart';
import 'package:unilitix/src/capture/snapshot_buffer.dart';
import 'package:unilitix/src/core/sdk_scope.dart';
import 'package:unilitix/src/events/event_buffer.dart';
import 'package:unilitix/src/network/retry_policy.dart';
import 'package:unilitix/src/privacy/identity.dart';
import 'package:unilitix/src/session/session.dart';
import 'package:unilitix/src/session/session_manager.dart';
import 'package:unilitix/src/tracking/rage_tap_detector.dart';
import 'package:unilitix/src/util/json_util.dart';

void main() {
  // ── UnilitixConfig ─────────────────────────────────────────────────────────

  group('UnilitixConfig', () {
    test('accepts required apiKey', () {
      const c = UnilitixConfig(apiKey: 'my-key');
      expect(c.apiKey, 'my-key');
    });

    test('all default values', () {
      const c = UnilitixConfig(apiKey: 'k');
      expect(c.apiUrl, 'https://api.unilitix.com');
      expect(c.autoTrackTaps, true);
      expect(c.autoTrackCrashes, true);
      expect(c.autoTrackRageTaps, true);
      expect(c.flushIntervalSeconds, 30);
      expect(c.flushBatchSize, 100);
      expect(c.maxOfflineEvents, 1000);
      expect(c.sessionTimeoutSeconds, 1800);
      expect(c.debug, false);
      expect(c.maskInputs, true);
      expect(c.captureSnapshots, true);
      expect(c.snapshotIntervalMs, 1000);
      expect(c.maxSnapshotsPerSession, 200);
      expect(c.captureScreenshots, true);
      expect(c.screenshotIntervalMs, 1000);
      expect(c.screenshotQuality, 30);
      expect(c.screenshotMaxWidth, 480);
      expect(c.uploadScreenshotsOnWifiOnly, true);
      expect(c.maxScreenshotsPerSession, 300);
    });

    test('custom values override defaults', () {
      const c = UnilitixConfig(
        apiKey: 'k',
        sessionTimeoutSeconds: 600,
        flushIntervalSeconds: 60,
        debug: true,
        captureScreenshots: false,
        screenshotQuality: 80,
        screenshotMaxWidth: 720,
        uploadScreenshotsOnWifiOnly: false,
      );
      expect(c.sessionTimeoutSeconds, 600);
      expect(c.flushIntervalSeconds, 60);
      expect(c.debug, true);
      expect(c.captureScreenshots, false);
      expect(c.screenshotQuality, 80);
      expect(c.screenshotMaxWidth, 720);
      expect(c.uploadScreenshotsOnWifiOnly, false);
    });

    test('const construction works', () {
      const c1 = UnilitixConfig(apiKey: 'a');
      const c2 = UnilitixConfig(apiKey: 'a');
      expect(identical(c1, c2), true);
    });
  });

  // ── EventTypes ─────────────────────────────────────────────────────────────

  group('EventTypes constants', () {
    test('all values match backend schema', () {
      expect(EventTypes.tap, 'TAP');
      expect(EventTypes.navigate, 'NAV');
      expect(EventTypes.rageTap, 'RAGE_TAP');
      expect(EventTypes.crash, 'CRASH');
      expect(EventTypes.custom, 'CUSTOM');
      expect(EventTypes.sessionStart, 'SESSION_START');
      expect(EventTypes.sessionEnd, 'SESSION_END');
    });
  });

  // ── UnilitixEvent.toJson ───────────────────────────────────────────────────

  group('UnilitixEvent.toJson()', () {
    test('TAP: type, screen, x, y, timestamp all present', () {
      final e = UnilitixEvent(
          type: EventTypes.tap, screen: '/home', x: 100.0, y: 200.0);
      final j = e.toJson();
      expect(j['type'], 'TAP');
      expect(j['screen'], '/home');
      expect(j['x'], 100.0);
      expect(j['y'], 200.0);
      expect(j['timestamp'], isA<String>());
    });

    test('NAV: screen present, x/y absent', () {
      final e = UnilitixEvent(type: EventTypes.navigate, screen: '/profile');
      final j = e.toJson();
      expect(j['type'], 'NAV');
      expect(j['screen'], '/profile');
      expect(j.containsKey('x'), false);
      expect(j.containsKey('y'), false);
    });

    test('RAGE_TAP: type correct', () {
      final e = UnilitixEvent(
          type: EventTypes.rageTap, screen: '/home', x: 50.0, y: 60.0);
      expect(e.toJson()['type'], 'RAGE_TAP');
    });

    test('SESSION_START: type correct', () {
      final e = UnilitixEvent(
          type: EventTypes.sessionStart,
          properties: {'sessionId': 'abc-123'});
      expect(e.toJson()['type'], 'SESSION_START');
    });

    test('SESSION_END: type correct', () {
      expect(
          UnilitixEvent(type: EventTypes.sessionEnd).toJson()['type'],
          'SESSION_END');
    });

    test('CRASH: serializes exceptionType, exceptionMessage, stackTrace, breadcrumbs', () {
      final e = UnilitixEvent(type: EventTypes.crash, screen: '/home')
        ..exceptionType = 'NullCheckFailure'
        ..exceptionMessage = 'Null check operator used on a null value'
        ..stackTrace = '#0 main (main.dart:10:3)'
        ..breadcrumbs = [
          {'type': 'TAP', 'screen': '/home', 'timestamp': 0}
        ];
      final j = e.toJson();
      expect(j['type'], 'CRASH');
      expect(j['exceptionType'], 'NullCheckFailure');
      expect(j['exceptionMessage'], 'Null check operator used on a null value');
      expect(j['stackTrace'], contains('#0'));
      expect((j['breadcrumbs'] as List).length, 1);
    });

    test('CRASH: does not include metadata or properties keys', () {
      final e = UnilitixEvent(type: EventTypes.crash)
        ..exceptionType = 'Error';
      final j = e.toJson();
      expect(j.containsKey('metadata'), false);
      expect(j.containsKey('properties'), false);
    });

    test('CUSTOM: metadata.name set, properties at top level', () {
      final e = UnilitixEvent(
        type: EventTypes.custom,
        properties: {'amount': 5000, 'currency': 'NGN'},
      )..eventName = 'purchase_completed';
      final j = e.toJson();
      expect(j['type'], 'CUSTOM');
      expect((j['metadata'] as Map)['name'], 'purchase_completed');
      expect((j['properties'] as Map)['amount'], 5000);
      expect((j['properties'] as Map)['currency'], 'NGN');
    });

    test('CUSTOM: empty properties map omits properties key', () {
      final e = UnilitixEvent(type: EventTypes.custom)..eventName = 'ping';
      final j = e.toJson();
      expect(j.containsKey('properties'), false);
      expect((j['metadata'] as Map)['name'], 'ping');
    });

    test('capturedOffline defaults to false', () {
      final e = UnilitixEvent(type: EventTypes.tap);
      expect(e.toJson()['capturedOffline'], false);
    });

    test('capturedOffline can be set to true', () {
      final e = UnilitixEvent(type: EventTypes.tap)..capturedOffline = true;
      expect(e.toJson()['capturedOffline'], true);
    });

    test('networkAtCapture defaults to UNKNOWN', () {
      final e = UnilitixEvent(type: EventTypes.tap);
      expect(e.toJson()['networkAtCapture'], 'UNKNOWN');
    });

    test('networkAtCapture is forwarded', () {
      final e = UnilitixEvent(type: EventTypes.tap)..networkAtCapture = 'WIFI';
      expect(e.toJson()['networkAtCapture'], 'WIFI');
    });

    test('performance metrics included when set', () {
      final e = UnilitixEvent(type: EventTypes.tap)
        ..memoryUsageMb = 42.5
        ..cpuUsagePct = 12.3
        ..frameDrops = 3;
      final j = e.toJson();
      expect(j['memoryUsageMb'], 42.5);
      expect(j['cpuUsagePct'], 12.3);
      expect(j['frameDrops'], 3);
    });

    test('performance metrics absent when null', () {
      final e = UnilitixEvent(type: EventTypes.tap);
      final j = e.toJson();
      expect(j.containsKey('memoryUsageMb'), false);
      expect(j.containsKey('cpuUsagePct'), false);
      expect(j.containsKey('frameDrops'), false);
    });

    test('timestamp is RFC3339 UTC string', () {
      final e = UnilitixEvent(type: EventTypes.tap);
      final ts = e.toJson()['timestamp'] as String;
      expect(ts,
          matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z$')));
    });

    test('toMap() equals toJson()', () {
      final e = UnilitixEvent(type: EventTypes.tap, screen: '/a', x: 1, y: 2);
      expect(e.toMap(), equals(e.toJson()));
    });
  });

  // ── RageTapDetector ────────────────────────────────────────────────────────

  group('RageTapDetector', () {
    late List<String> fired;
    late RageTapDetector detector;

    setUp(() {
      fired = [];
      detector = RageTapDetector(
        onRageTap: (screen, _, __, ___, ____) => fired.add(screen),
      );
    });

    test('single tap returns false and does not fire', () {
      expect(detector.recordTap('/home', 100, 100), false);
      expect(fired, isEmpty);
    });

    test('two taps return false and do not fire', () {
      detector.recordTap('/home', 100, 100);
      expect(detector.recordTap('/home', 102, 102), false);
      expect(fired, isEmpty);
    });

    test('three taps within 100px radius trigger rage, return true', () {
      detector.recordTap('/home', 100, 100);
      detector.recordTap('/home', 102, 102);
      final result = detector.recordTap('/home', 104, 104);
      expect(result, true);
      expect(fired, ['/home']);
    });

    test('rage clears history — next tap alone does not re-trigger', () {
      detector.recordTap('/home', 100, 100);
      detector.recordTap('/home', 102, 102);
      detector.recordTap('/home', 104, 104); // rage fired, history cleared
      expect(detector.recordTap('/home', 106, 106), false);
      expect(fired.length, 1);
    });

    test('taps beyond 100px radius do not cluster', () {
      detector.recordTap('/home', 0, 0);
      detector.recordTap('/home', 200, 0); // 200px away
      expect(detector.recordTap('/home', 400, 0), false);
      expect(fired, isEmpty);
    });

    test('callback receives correct screen name', () {
      detector.recordTap('/checkout', 50, 50);
      detector.recordTap('/checkout', 52, 52);
      detector.recordTap('/checkout', 54, 54);
      expect(fired.first, '/checkout');
    });

    test('callback receives centroid of cluster', () {
      double? cx, cy;
      final d = RageTapDetector(
        onRageTap: (_, __, ___, centX, centY) {
          cx = centX;
          cy = centY;
        },
      );
      d.recordTap('/h', 100, 100);
      d.recordTap('/h', 110, 110);
      d.recordTap('/h', 120, 120);
      // centroid = ((100+110+120)/3, (100+110+120)/3) = (110, 110)
      expect(cx, closeTo(110, 0.1));
      expect(cy, closeTo(110, 0.1));
    });

    test('exactly 100px away is within radius (boundary)', () {
      // Distance = 100px exactly — should be within _radiusPx = 100.0
      detector.recordTap('/home', 0, 0);
      detector.recordTap('/home', 100, 0); // exactly 100px
      expect(detector.recordTap('/home', 50, 0), true);
    });
  });

  // ── RetryPolicy ────────────────────────────────────────────────────────────

  group('RetryPolicy', () {
    test('maxRetries is 5', () => expect(RetryPolicy.maxRetries, 5));
    test('maxDelayMs is 5 minutes (300000)', () => expect(RetryPolicy.maxDelayMs, 300000));

    // ── delayFor ──────────────────────────────────────────────────────────────

    test('exponential backoff: attempt 0→~1s, 1→~2s, 2→~4s, 3→~8s (±20% jitter)', () {
      // base * [1.0, 1.2) due to jitter
      expect(RetryPolicy.delayFor(0).inMilliseconds, inInclusiveRange(1000, 1199));
      expect(RetryPolicy.delayFor(1).inMilliseconds, inInclusiveRange(2000, 2399));
      expect(RetryPolicy.delayFor(2).inMilliseconds, inInclusiveRange(4000, 4799));
      expect(RetryPolicy.delayFor(3).inMilliseconds, inInclusiveRange(8000, 9599));
    });

    test('retryAfterSeconds is honoured when provided', () {
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 10).inSeconds, 10);
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 30).inSeconds, 30);
    });

    test('retryAfterSeconds is clamped to [1, 60] seconds', () {
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 0).inSeconds, 1);
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: -5).inSeconds, 1);
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 999).inSeconds, 60);
    });

    test('delay is capped at maxDelayMs regardless of attempt', () {
      expect(RetryPolicy.delayFor(20).inMilliseconds, RetryPolicy.maxDelayMs);
      expect(RetryPolicy.delayFor(19).inMilliseconds, RetryPolicy.maxDelayMs);
    });

    test('attempt 100 does not overflow — returns maxDelayMs', () {
      final delay = RetryPolicy.delayFor(100);
      expect(delay.inMilliseconds, RetryPolicy.maxDelayMs);
    });

    test('negative attempt is clamped to 0 — returns ~1s (±20% jitter)', () {
      expect(RetryPolicy.delayFor(-1).inMilliseconds, inInclusiveRange(1000, 1199));
    });

    // ── shouldRetry ───────────────────────────────────────────────────────────

    test('shouldRetry: false for 4xx non-429', () {
      for (final code in [400, 401, 403, 404, 422]) {
        expect(RetryPolicy.shouldRetry(attempt: 1, statusCode: code), false,
            reason: 'HTTP $code should not be retried');
      }
    });

    test('shouldRetry: true for 429', () {
      expect(RetryPolicy.shouldRetry(attempt: 1, statusCode: 429), true);
    });

    test('shouldRetry: true for 5xx within retry limit', () {
      expect(RetryPolicy.shouldRetry(attempt: 1, statusCode: 500), true);
      expect(RetryPolicy.shouldRetry(attempt: 5, statusCode: 503), true);
    });

    test('shouldRetry: false when attempt > maxRetries', () {
      expect(RetryPolicy.shouldRetry(attempt: 6, statusCode: 500), false);
    });

    test('shouldRetry: true for null statusCode (network error)', () {
      expect(RetryPolicy.shouldRetry(attempt: 1, statusCode: null), true);
    });
  });

  // ── JsonUtil ───────────────────────────────────────────────────────────────

  group('JsonUtil.toRfc3339', () {
    test('Unix epoch produces 1970-01-01T00:00:00.000Z', () {
      expect(JsonUtil.toRfc3339(0), '1970-01-01T00:00:00.000Z');
    });

    test('known timestamp is formatted correctly', () {
      final ms = DateTime.utc(2026, 5, 29, 10, 30).millisecondsSinceEpoch;
      final result = JsonUtil.toRfc3339(ms);
      expect(result, startsWith('2026-05-29T10:30:00'));
      expect(result, endsWith('Z'));
    });

    test('always produces UTC (ends with Z, no offset)', () {
      final result = JsonUtil.toRfc3339(DateTime.now().millisecondsSinceEpoch);
      expect(result, endsWith('Z'));
      expect(result, isNot(contains('+')));
    });

    test('always contains T date-time separator', () {
      expect(JsonUtil.toRfc3339(1000000000000), contains('T'));
    });
  });

  // ── SnapshotBuffer ─────────────────────────────────────────────────────────

  group('SnapshotBuffer', () {
    test('empty drain returns empty list', () {
      expect(SnapshotBuffer(capacity: 10).drain(), isEmpty);
    });

    test('add and drain returns items in insertion order', () {
      final buf = SnapshotBuffer(capacity: 10);
      buf.add({'ordinal': 0});
      buf.add({'ordinal': 1});
      final items = buf.drain();
      expect(items.length, 2);
      expect(items[0]['ordinal'], 0);
      expect(items[1]['ordinal'], 1);
    });

    test('drain clears the buffer', () {
      final buf = SnapshotBuffer(capacity: 10);
      buf.add({'a': 1});
      buf.drain();
      expect(buf.drain(), isEmpty);
      expect(buf.length, 0);
    });

    test('overflow beyond capacity drops oldest item', () {
      final buf = SnapshotBuffer(capacity: 3);
      buf.add({'i': 0});
      buf.add({'i': 1});
      buf.add({'i': 2});
      buf.add({'i': 3}); // evicts i:0
      final items = buf.drain();
      expect(items.length, 3);
      expect(items.map((e) => e['i']).toList(), [1, 2, 3]);
    });

    test('clear empties buffer', () {
      final buf = SnapshotBuffer(capacity: 5);
      buf.add({'x': 1});
      buf.clear();
      expect(buf.length, 0);
      expect(buf.drain(), isEmpty);
    });

    test('length reflects current count', () {
      final buf = SnapshotBuffer(capacity: 10);
      expect(buf.length, 0);
      buf.add({});
      expect(buf.length, 1);
      buf.add({});
      expect(buf.length, 2);
      buf.drain();
      expect(buf.length, 0);
    });

    test('capacity of 1 always holds only the latest item', () {
      final buf = SnapshotBuffer(capacity: 1);
      buf.add({'i': 0});
      buf.add({'i': 1});
      buf.add({'i': 2});
      expect(buf.drain().single['i'], 2);
    });
  });

  // ── EventBuffer ────────────────────────────────────────────────────────────

  group('EventBuffer', () {
    test('empty drain returns empty list', () {
      final buf = EventBuffer(batchSize: 10, onFlushNeeded: () {});
      expect(buf.drain(), isEmpty);
      expect(buf.isEmpty, true);
    });

    test('emit adds events; drain returns them in order', () {
      final buf = EventBuffer(batchSize: 10, onFlushNeeded: () {});
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      buf.emit(UnilitixEvent(type: EventTypes.navigate));
      final events = buf.drain();
      expect(events.length, 2);
      expect(events[0].type, 'TAP');
      expect(events[1].type, 'NAV');
    });

    test('drain clears buffer — subsequent drain is empty', () {
      final buf = EventBuffer(batchSize: 10, onFlushNeeded: () {});
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      buf.drain();
      expect(buf.drain(), isEmpty);
      expect(buf.isEmpty, true);
      expect(buf.length, 0);
    });

    test('onFlushNeeded fires exactly once when batchSize is reached', () {
      var count = 0;
      final buf = EventBuffer(batchSize: 3, onFlushNeeded: () => count++);
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      expect(count, 0);
      buf.emit(UnilitixEvent(type: EventTypes.tap)); // 3rd event
      expect(count, 1);
    });

    test('onFlushNeeded fires again after drain when batchSize reached again', () {
      var count = 0;
      final buf = EventBuffer(batchSize: 2, onFlushNeeded: () => count++);
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      buf.emit(UnilitixEvent(type: EventTypes.tap)); // fires once
      buf.drain();
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      buf.emit(UnilitixEvent(type: EventTypes.tap)); // fires again
      expect(count, 2);
    });

    test('length reflects current count', () {
      final buf = EventBuffer(batchSize: 10, onFlushNeeded: () {});
      expect(buf.length, 0);
      buf.emit(UnilitixEvent(type: EventTypes.tap));
      expect(buf.length, 1);
      buf.drain();
      expect(buf.length, 0);
    });
  });

  // ── Session ────────────────────────────────────────────────────────────────

  group('Session', () {
    test('id is a valid UUID v4', () {
      final s = Session();
      expect(
        s.id,
        matches(RegExp(
          r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
        )),
      );
    });

    test('each session has a unique id', () {
      final ids = List.generate(10, (_) => Session().id).toSet();
      expect(ids.length, 10);
    });

    test('startedAt is within current second', () {
      final before = DateTime.now().millisecondsSinceEpoch - 100;
      final s = Session();
      final after = DateTime.now().millisecondsSinceEpoch + 100;
      expect(s.startedAt, greaterThanOrEqualTo(before));
      expect(s.startedAt, lessThanOrEqualTo(after));
    });

    test('durationMs reflects endedAt - startedAt when endedAt is set', () {
      final s = Session();
      s.endedAt = s.startedAt + 7500;
      expect(s.durationMs, 7500);
    });

    test('durationMs is non-negative when endedAt is null', () {
      final s = Session();
      expect(s.durationMs, greaterThanOrEqualTo(0));
    });

    test('all counters default to zero / false', () {
      final s = Session();
      expect(s.foregroundTimeMs, 0);
      expect(s.backgroundTimeMs, 0);
      expect(s.offlineEventCount, 0);
      expect(s.onlineEventCount, 0);
      expect(s.networkTransitions, 0);
      expect(s.crashed, false);
      expect(s.endedAt, isNull);
    });

    test('mutable fields can be updated', () {
      final s = Session();
      s.foregroundTimeMs = 1000;
      s.backgroundTimeMs = 500;
      s.offlineEventCount = 3;
      s.onlineEventCount = 7;
      s.networkTransitions = 2;
      s.crashed = true;
      expect(s.foregroundTimeMs, 1000);
      expect(s.backgroundTimeMs, 500);
      expect(s.offlineEventCount, 3);
      expect(s.onlineEventCount, 7);
      expect(s.networkTransitions, 2);
      expect(s.crashed, true);
    });
  });

  // ── Unilitix static API ────────────────────────────────────────────────────

  group('Unilitix', () {
    test('isInitialized is false before init()', () {
      expect(Unilitix.isInitialized, false);
    });

    test('config is null before init()', () {
      expect(Unilitix.config, isNull);
    });

    test('observer returns a UnilitixObserver', () {
      expect(Unilitix.observer, isA<UnilitixObserver>());
    });

    test('observer is the same singleton on repeated access', () {
      expect(identical(Unilitix.observer, Unilitix.observer), true);
    });
  });

  // ── SdkScope.repaintKey ────────────────────────────────────────────────────

  group('SdkScope.repaintKey', () {
    test('returns a GlobalKey', () {
      expect(SdkScope.repaintKey, isA<GlobalKey>());
    });

    test('is the same singleton on repeated access', () {
      expect(identical(SdkScope.repaintKey, SdkScope.repaintKey), true);
    });
  });

  // ── RageTapDetector cross-screen isolation ─────────────────────────────────

  group('RageTapDetector cross-screen isolation', () {
    late List<String> fired;
    late RageTapDetector detector;

    setUp(() {
      fired = [];
      detector = RageTapDetector(
        onRageTap: (screen, _, __, ___, ____) => fired.add(screen),
      );
    });

    test('does not fire when third tap is on a different screen', () {
      detector.recordTap('screenA', 100, 100);
      detector.recordTap('screenA', 102, 101);
      final result = detector.recordTap('screenB', 101, 100);
      expect(result, false);
      expect(fired, isEmpty);
    });

    test('fires when all three taps are on the same screen', () {
      detector.recordTap('screenA', 100, 100);
      detector.recordTap('screenA', 102, 101);
      final result = detector.recordTap('screenA', 101, 99);
      expect(result, true);
      expect(fired, ['screenA']);
    });

    test('each screen tracked independently — both can rage independently', () {
      final detectorB = RageTapDetector(
        onRageTap: (screen, _, __, ___, ____) => fired.add(screen),
      );
      detectorB.recordTap('B', 10, 10);
      detectorB.recordTap('B', 11, 10);
      final result = detectorB.recordTap('B', 12, 10);
      expect(result, true);
      expect(fired, ['B']);
    });
  });

  // ── Identity.computeAnonIdHash ─────────────────────────────────────────────

  group('Identity.computeAnonIdHash', () {
    test('same inputs produce same hash', () {
      final id1 = Identity.computeAnonIdHash('device123', 'com.example.app');
      final id2 = Identity.computeAnonIdHash('device123', 'com.example.app');
      expect(id1, equals(id2));
    });

    test('different device IDs produce different hashes', () {
      final id1 = Identity.computeAnonIdHash('device123', 'com.example.app');
      final id2 = Identity.computeAnonIdHash('device456', 'com.example.app');
      expect(id1, isNot(equals(id2)));
    });

    test('different package names produce different hashes', () {
      final id1 = Identity.computeAnonIdHash('device123', 'com.example.app');
      final id2 = Identity.computeAnonIdHash('device123', 'com.other.app');
      expect(id1, isNot(equals(id2)));
    });

    test('hash is 24 characters', () {
      final id = Identity.computeAnonIdHash('device123', 'com.example.app');
      expect(id.length, 24);
    });
  });

  // ── SessionManager.resetSession ────────────────────────────────────────────

  group('SessionManager.resetSession', () {
    late SessionManager manager;
    late List<Session> started;

    setUp(() {
      started = [];
      manager = SessionManager(
        sessionTimeoutSeconds: 1800,
        onSessionStart: started.add,
        onSessionEnd: (_) {},
        resetScreenshotOrdinal: () {},
      );
      manager.resetSession(); // establish initial session without WidgetsBinding
    });

    test('isBackgrounded is false after reset', () {
      manager.didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(manager.isBackgrounded, true);
      manager.resetSession();
      expect(manager.isBackgrounded, false);
    });

    test('currentSession is non-null after reset', () {
      expect(manager.currentSession, isNotNull);
    });

    test('reset starts a new session with a different id', () {
      final idBefore = manager.currentSession!.id;
      manager.resetSession();
      expect(manager.currentSession!.id, isNot(equals(idBefore)));
    });
  });

  // ── UnilitixObserver.resolveName ───────────────────────────────────────────

  group('UnilitixObserver.resolveName', () {
    test('named route returns name as-is', () {
      expect(UnilitixObserver.resolveName('/home', 'MaterialPageRoute'), '/home');
    });

    test('empty name falls back to type mapping', () {
      expect(UnilitixObserver.resolveName('', '_DialogRoute<dynamic>'), 'Dialog');
    });

    test('null name falls back to type mapping', () {
      expect(UnilitixObserver.resolveName(null, '_ModalBottomSheetRoute<dynamic>'), 'BottomSheet');
    });

    test('popup menu route maps to PopupMenu', () {
      expect(UnilitixObserver.resolveName(null, '_PopupMenuRoute<dynamic>'), 'PopupMenu');
    });

    test('unknown unnamed type returns the type string', () {
      expect(UnilitixObserver.resolveName(null, 'CustomRoute<void>'), 'CustomRoute<void>');
    });
  });
}
