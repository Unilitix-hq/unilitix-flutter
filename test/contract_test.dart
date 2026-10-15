// Contract tests: everything the SDK puts on the wire must be a field the
// server declares in api/openapi.sdk.json (mirrored here as
// lib/src/generated/ingest_models.dart). A key the server does not know is
// silently dropped by the Go decoder, so this is the test that catches it.
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/generated/ingest_models.dart';
import 'package:unilitix/src/storage/pending_screenshot.dart';
import 'dart:typed_data';

void expectKnownKeys(Map<String, dynamic> wire, Set<String> known, String what) {
  final unknown = wire.keys.where((k) => !known.contains(k)).toList();
  expect(unknown, isEmpty,
      reason: '$what sends keys the server contract does not declare: $unknown');
}

void main() {
  group('ingest contract', () {
    test('tap, navigation and custom events only use declared fields', () {
      final tap = UnilitixEvent(type: EventTypes.tap, screen: '/home', x: 1, y: 2)
        ..seq = 0
        ..memoryUsageMb = 12.5
        ..frameDrops = 1;
      final nav = UnilitixEvent(type: EventTypes.navigate, screen: '/profile')..seq = 1;
      final custom = UnilitixEvent(
          type: EventTypes.custom, screen: '/cart', properties: {'sku': 'A1'})
        ..eventName = 'add_to_cart'
        ..seq = 2;
      for (final e in [tap, nav, custom]) {
        final wire = e.toJson();
        expectKnownKeys(wire, IngestEvent.fields, 'event ${e.type}');
        final parsed = IngestEvent.fromJson(wire);
        expect(parsed.type, e.type);
        expect(parsed.eventId, e.id);
        expect(parsed.seq, e.seq);
      }
    });

    test('crash and exception events carry title and fatal in declared fields', () {
      final crash = UnilitixEvent(type: EventTypes.crash, screen: '/pay')
        ..fatal = true
        ..title = 'SIGSEGV'
        ..stackTrace = '#0 main'
        ..exceptionType = 'SIGSEGV'
        ..exceptionMessage = 'boom'
        ..breadcrumbs = [
          {'type': 'NAV', 'screen': '/pay'}
        ];
      final wire = crash.toJson();
      expectKnownKeys(wire, IngestEvent.fields, 'crash event');
      final parsed = IngestEvent.fromJson(wire);
      expect(parsed.fatal, isTrue);
      expect(parsed.title, 'SIGSEGV');
      expect(parsed.breadcrumbs, isA<List<dynamic>>());

      final exc = UnilitixEvent(type: EventTypes.exception, screen: '/pay')
        ..exceptionType = 'StateError';
      expectKnownKeys(exc.toJson(), IngestEvent.fields, 'exception event');
      expect(IngestEvent.fromJson(exc.toJson()).fatal, isFalse);
    });

    test('events batch matches IngestEventsRequest', () {
      final e = UnilitixEvent(type: EventTypes.tap, screen: '/home', x: 0, y: 0);
      final body = {
        'sessionId': 'sess-1',
        'events': [e.toJson()],
      };
      expectKnownKeys(body, IngestEventsRequest.fields, 'events batch');
      final req = IngestEventsRequest.fromJson(body);
      expect(req.events, hasLength(1));
      expect(req.toJson()['sessionId'], 'sess-1');
    });

    test('session payload keys are all declared on IngestSessionRequest', () {
      // Mirrors the keys Unilitix._buildSessionPayload emits.
      final payload = <String, dynamic>{
        'anonymousId': 'a', 'userId': 'u', 'deviceType': 'phone',
        'manufacturer': 'm', 'deviceModel': 'd', 'os': 'Android', 'osVersion': '14',
        'screenWidth': 1, 'screenHeight': 2, 'screenDensity': 2.0,
        'appVersion': '1', 'buildNumber': '2', 'packageName': 'p', 'sdkVersion': '2.0.74',
        'networkType': 'WIFI', 'carrierName': '', 'orientation': 'portrait',
        'locale': 'en', 'timezone': 'UTC', 'installId': 'i', 'batteryLevel': 0.5,
        'totalStorageGb': 64.0, 'startedAt': '2026-01-01T00:00:00.000Z',
        'endedAt': '2026-01-01T00:01:00.000Z', 'durationMs': 60000,
        'foregroundTimeMs': 1, 'backgroundTimeMs': 0, 'crashed': false,
        'capturedOffline': false, 'offlineEventCount': 0, 'onlineEventCount': 3,
        'networkTransitions': 0, 'sessionId': 's', 'sessionData': {'plan': 'pro'},
        'events': <Map<String, dynamic>>[],
      };
      expectKnownKeys(payload, IngestSessionRequest.fields, 'session payload');
      final parsed = IngestSessionRequest.fromJson(payload);
      expect(parsed.startedAt, DateTime.utc(2026));
      expect(parsed.durationMs, 60000);
    });

    test('screenshot confirm sends the metadata the server stores', () {
      final shot = PendingScreenshot(
        sessionId: 's',
        ordinal: 7,
        screenName: '/home',
        viewportWidth: 390,
        viewportHeight: 844,
        capturedAt: DateTime.utc(2026, 1, 1).millisecondsSinceEpoch,
        imageBytes: Uint8List(3),
        createdAt: 0,
      );
      final body = ScreenshotConfirmRequest(
        sessionId: shot.sessionId,
        screenshots: [
          ScreenshotConfirmItem(
            ordinal: shot.ordinal,
            screenName: shot.screenName,
            viewportWidth: shot.viewportWidth,
            viewportHeight: shot.viewportHeight,
            bytes: shot.imageBytes.length,
            capturedAt: DateTime.fromMillisecondsSinceEpoch(shot.capturedAt, isUtc: true)
                .toIso8601String(),
          ),
        ],
      ).toJson();
      expectKnownKeys(body, ScreenshotConfirmRequest.fields, 'screenshot confirm');
      final items = body['screenshots'] as List;
      expect(items, hasLength(1));
      expectKnownKeys(items.first as Map<String, dynamic>, ScreenshotConfirmItem.fields,
          'screenshot confirm item');
      expect((items.first as Map)['bytes'], 3);
    });

    test('server responses parse', () {
      final r = IngestResponse.fromJson({'sessionId': 'abc', 'received': true});
      expect(r.sessionId, 'abc');
      final err = ErrorResponse.fromJson({'error': 'nope', 'code': 'BAD_REQUEST'});
      expect(err.code, 'BAD_REQUEST');
      expect(err.details, isNull);
      final quota = QuotaExceeded.fromJson(
          {'error': 'over', 'limitType': 'events', 'limit': 10, 'used': 11});
      expect(quota.upgradeUrl, isNull);
    });
  });
}
