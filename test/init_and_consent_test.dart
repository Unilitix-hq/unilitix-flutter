import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/core/init_guard.dart';
import 'package:unilitix/src/privacy/opt_manager.dart';
import 'package:unilitix/unilitix.dart';

/// 2.7.4: init runs once and never throws; consent given before init is
/// persisted and becomes the starting state.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('InitGuard', () {
    test('concurrent callers share one run', () async {
      var runs = 0;
      final gate = Completer<void>();
      final guard = InitGuard(onError: (_, __) {});
      Future<void> body() async {
        runs++;
        await gate.future;
      }

      final first = guard.run(body);
      final second = guard.run(body);
      expect(identical(first, second), isTrue);
      expect(guard.inFlight, isTrue);
      gate.complete();
      await Future.wait([first, second]);
      await guard.run(body); // after completion: still the same, no rerun
      expect(runs, 1);
      expect(guard.succeeded, isTrue);
      expect(guard.inFlight, isFalse);
    });

    test('a throwing body is reported, not rethrown', () async {
      final errors = <Object>[];
      final guard = InitGuard(onError: (e, _) => errors.add(e));
      await guard.run(() async {
        throw const FormatException('prefs corrupt');
      });
      expect(errors.single, isA<FormatException>());
      expect(guard.succeeded, isFalse);
      expect(guard.started, isTrue);
    });
  });

  group('consent before init', () {
    test('is persisted at once and reported by Unilitix.consent', () async {
      SharedPreferences.setMockInitialValues({});
      expect(Unilitix.isInitialized, isFalse);

      await Unilitix.setConsent(UnilitixConsent.denied);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('unilitix_consent'), 'denied');
      expect(prefs.getBool('unilitix_opted_out'), isTrue);
      expect(Unilitix.consent, UnilitixConsent.denied);

      // init (on this launch or the next) starts from the stored decision.
      final m = OptManager();
      await m.load(initial: UnilitixConsent.granted);
      expect(m.consent, UnilitixConsent.denied);

      await Unilitix.optIn();
      expect(
          (await SharedPreferences.getInstance()).getString('unilitix_consent'),
          'granted');
      expect(Unilitix.consent, UnilitixConsent.granted);
    });
  });
}
