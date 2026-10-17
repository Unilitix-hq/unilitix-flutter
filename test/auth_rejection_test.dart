import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/flush/flush_scheduler.dart';

void main() {
  group('FlushScheduler.isAuthFailure', () {
    test('401 and 403 are key failures that must stop uploads', () {
      expect(FlushScheduler.isAuthFailure(401), isTrue);
      expect(FlushScheduler.isAuthFailure(403), isTrue);
    });

    test('other statuses keep the normal retry path', () {
      for (final s in [200, 201, 204, 400, 404, 409, 429, 500, 503]) {
        expect(FlushScheduler.isAuthFailure(s), isFalse, reason: '$s');
      }
    });
  });
}
