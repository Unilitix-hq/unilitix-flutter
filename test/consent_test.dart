import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/privacy/opt_manager.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('OptManager consent states', () {
    test('first launch uses the initial state passed to load()', () async {
      SharedPreferences.setMockInitialValues({});
      final m = OptManager();
      await m.load(initial: UnilitixConsent.pending);
      expect(m.consent, UnilitixConsent.pending);
      expect(m.isPending, isTrue);
      expect(m.canUpload, isFalse);
      expect(m.isOptedOut, isFalse);
    });

    test('a persisted decision wins over the initial state', () async {
      SharedPreferences.setMockInitialValues({'unilitix_consent': 'denied'});
      final m = OptManager();
      await m.load(initial: UnilitixConsent.granted);
      expect(m.consent, UnilitixConsent.denied);
      expect(m.isOptedOut, isTrue);
      expect(m.canUpload, isFalse);
    });

    test('pre-2.1 opt-out flag migrates to denied', () async {
      SharedPreferences.setMockInitialValues({'unilitix_opted_out': true});
      final m = OptManager();
      await m.load();
      expect(m.consent, UnilitixConsent.denied);
    });

    test('set() persists and keeps the legacy flag in sync', () async {
      SharedPreferences.setMockInitialValues({});
      final m = OptManager();
      await m.load();
      await m.set(UnilitixConsent.denied);
      var prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('unilitix_consent'), 'denied');
      expect(prefs.getBool('unilitix_opted_out'), isTrue);

      await m.optIn();
      prefs = await SharedPreferences.getInstance();
      expect(m.consent, UnilitixConsent.granted);
      expect(prefs.getBool('unilitix_opted_out'), isFalse);
      expect(m.canUpload, isTrue);
    });
  });

  group('UnilitixConfig replay sampling', () {
    test('defaults to recording every session', () {
      const c = UnilitixConfig(apiKey: 'k');
      expect(c.replaySampleRate, 1.0);
    });

    test('copyWith carries the rate', () {
      const c = UnilitixConfig(apiKey: 'k');
      expect(c.copyWith(replaySampleRate: 0.1).replaySampleRate, 0.1);
      expect(c.copyWith(debug: true).replaySampleRate, 1.0);
    });
  });
}
