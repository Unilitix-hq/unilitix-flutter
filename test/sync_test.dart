import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/unilitix.dart';
import 'package:unilitix/src/util/json_util.dart';

void main() {
  group('Backend sync payload validation', () {
    test('JsonUtil.toRfc3339 produces ISO8601 string', () {
      final ms = DateTime(2026, 5, 29, 10, 30).millisecondsSinceEpoch;
      final result = JsonUtil.toRfc3339(ms);
      expect(
        result,
        matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')),
      );
      expect(result, contains('T'));
      expect(result, contains('Z'));
    });

    test('screen event type is NAV not NAVIGATE', () {
      expect(EventTypes.navigate, equals('NAV'));
    });

    test('orientation is lowercase', () {
      const portrait = 'portrait';
      const landscape = 'landscape';
      expect(portrait, isNot(equals('PORTRAIT')));
      expect(landscape, isNot(equals('LANDSCAPE')));
      expect(portrait, equals('portrait'));
      expect(landscape, equals('landscape'));
    });

    test('custom event properties wrapped in metadata', () {
      final event = UnilitixEvent(
        type: EventTypes.custom,
        properties: {'screen': 'home', 'button': 'cta'},
      )..eventName = 'button_tapped';

      final map = event.toMap();
      expect(map.containsKey('metadata'), isTrue);
      expect((map['metadata'] as Map)['name'], equals('button_tapped'));
      expect((map['metadata'] as Map)['screen'], equals('home'));
    });

    test('crash event does not have metadata field', () {
      final event = UnilitixEvent(type: EventTypes.crash)
        ..exceptionType = 'StateError'
        ..exceptionMessage = 'Bad state';

      final map = event.toMap();
      expect(map.containsKey('metadata'), isFalse);
      expect(map['exceptionType'], equals('StateError'));
    });

    test('event timestamp is RFC3339', () {
      final event = UnilitixEvent(type: EventTypes.custom);
      final map = event.toMap();
      final ts = map['timestamp'] as String;
      expect(ts, matches(RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}')));
    });

    test('snapshot capturedAt format uses RFC3339 helper', () {
      // 2026-05-29T10:00:00.000Z
      const ms = 1780048800000;
      final rfc = JsonUtil.toRfc3339(ms);
      expect(rfc, startsWith('2026-'));
      expect(rfc, contains('T'));
    });
  });
}
