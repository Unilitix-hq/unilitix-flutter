import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/tracking/rage_tap_detector.dart';
import 'package:unilitix/unilitix.dart';

/// Taps (Android) and route names are detected in Dart: the native SDKs
/// cannot see Flutter routes or UnilitixPrivate areas.
void main() {
  group('RageTapDetector', () {
    late List<String> fired;
    late RageTapDetector detector;

    setUp(() {
      fired = [];
      detector = RageTapDetector(
        onRageTap: (screen, _, __, ___, ____) => fired.add(screen),
      );
    });

    test('one or two taps do not fire', () {
      expect(detector.recordTap('/home', 100, 100), isFalse);
      expect(detector.recordTap('/home', 102, 102), isFalse);
      expect(fired, isEmpty);
    });

    test('three taps within the radius fire once and clear the history', () {
      detector.recordTap('/home', 100, 100);
      detector.recordTap('/home', 102, 102);
      expect(detector.recordTap('/home', 104, 104), isTrue);
      expect(fired, ['/home']);
      expect(detector.recordTap('/home', 106, 106), isFalse);
    });

    test('taps beyond the radius or on another screen do not cluster', () {
      detector.recordTap('/home', 0, 0);
      detector.recordTap('/home', 200, 0);
      expect(detector.recordTap('/home', 400, 0), isFalse);
      detector.recordTap('A', 100, 100);
      detector.recordTap('A', 102, 101);
      expect(detector.recordTap('B', 101, 100), isFalse);
      expect(fired, isEmpty);
    });

    test('the callback gets the centroid', () {
      double? cx, cy;
      final d = RageTapDetector(onRageTap: (_, __, ___, x, y) {
        cx = x;
        cy = y;
      });
      d.recordTap('/h', 100, 100);
      d.recordTap('/h', 110, 110);
      d.recordTap('/h', 120, 120);
      expect(cx, closeTo(110, 0.1));
      expect(cy, closeTo(110, 0.1));
    });
  });

  group('UnilitixObserver.resolveName', () {
    test('a named route keeps its name', () {
      expect(
          UnilitixObserver.resolveName('/home', 'MaterialPageRoute'), '/home');
    });

    test('unnamed dialogs, sheets and menus get readable names', () {
      expect(
          UnilitixObserver.resolveName('', '_DialogRoute<dynamic>'), 'Dialog');
      expect(
          UnilitixObserver.resolveName(null, '_ModalBottomSheetRoute<dynamic>'),
          'BottomSheet');
      expect(UnilitixObserver.resolveName(null, '_PopupMenuRoute<dynamic>'),
          'PopupMenu');
      expect(UnilitixObserver.resolveName(null, 'CustomRoute<void>'),
          'CustomRoute<void>');
    });
  });
}
