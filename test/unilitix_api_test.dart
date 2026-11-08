import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/core/sdk_scope.dart';
import 'package:unilitix/src/core/version.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';
import 'package:unilitix/unilitix.dart';

import 'support/fake_native.dart';

/// 3.0.0: the Dart API is a thin layer over the native SDK. These tests pin
/// the exact native calls each public method makes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeNative native;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    Unilitix.debugReset();
    native = FakeNative()..install();
  });

  tearDown(() {
    Unilitix.debugReset();
    native.uninstall();
  });

  // Replay and error hooks off unless a test turns them on, so a test does
  // not leave timers or global handlers behind.
  const quiet = UnilitixConfig(
    apiKey: 'ignored',
    captureSnapshots: false,
    captureScreenshots: false,
    autoTrackCrashes: false,
  );

  group('init', () {
    test('sends the wrapper identity, the consent and every option', () async {
      const config = UnilitixConfig(
        apiKey: 'replaced by the init argument',
        apiUrl: 'https://ingest.example',
        debug: false,
        autoTrackTaps: false,
        autoTrackRageTaps: false,
        autoTrackCrashes: false,
        appHangTimeoutMs: 0,
        flushIntervalSeconds: 60,
        flushBatchSize: 50,
        maxOfflineEvents: 500,
        sessionTimeoutSeconds: 120,
        maskInputs: false,
        maskAllText: false,
        maskImages: true,
        maskScreenshots: false,
        replaySampleRate: 0.25,
        captureSnapshots: false,
        snapshotIntervalMs: 2000,
        maxSnapshotsPerSession: 10,
        captureScreenshots: false,
        screenshotIntervalMs: 1500,
        screenshotQuality: 40,
        screenshotMaxWidth: 360,
        uploadScreenshotsOnWifiOnly: false,
        maxScreenshotsPerSession: 11,
        maxScreenshotsPerMinute: 12,
        screenshotHeartbeatMs: 5000,
      );
      await Unilitix.init('ul_test_key',
          config: config, consent: UnilitixConsent.pending);

      expect(Unilitix.isInitialized, isTrue);
      final args = native.single('init');
      expect(args['apiKey'], 'ul_test_key');
      expect(args['consent'], 'pending');
      expect(args['wrapperName'], 'flutter');
      expect(args['wrapperVersion'], kUnilitixSdkVersion);
      expect(args['config'], {
        'apiUrl': 'https://ingest.example',
        'debug': false,
        'autoTrackTaps': false,
        'autoTrackRageTaps': false,
        'autoTrackCrashes': false,
        'appHangTimeoutMs': 0,
        'flushIntervalSeconds': 60,
        'flushBatchSize': 50,
        'maxOfflineEvents': 500,
        'sessionTimeoutSeconds': 120,
        'maskInputs': false,
        'maskAllText': false,
        'maskImages': true,
        'maskInputsInScreenshots': false,
        'replaySampleRate': 0.25,
        'captureSnapshots': false,
        'snapshotIntervalMs': 2000,
        'maxSnapshotsPerSession': 10,
        'captureScreenshots': false,
        'screenshotIntervalMs': 1500,
        'screenshotQuality': 40,
        'screenshotMaxWidth': 360,
        'uploadScreenshotsOnWifiOnly': false,
        'maxScreenshotsPerSession': 11,
        'maxScreenshotsPerMinute': 12,
        'screenshotHeartbeatMs': 5000,
      });
    });

    test('every contract option the native SDK applies is sent', () async {
      await Unilitix.init('k', config: quiet);
      final sent = (native.single('init')['config'] as Map).keys.toSet();
      // Applied in Dart, not by the native SDK.
      const dartOnly = {'consent', 'powerOutageContribution'};
      for (final key in SdkContract.defaults.keys) {
        if (dartOnly.contains(key)) continue;
        final nativeKey =
            key == 'maskScreenshots' ? 'maskInputsInScreenshots' : key;
        expect(sent, contains(nativeKey), reason: key);
      }
    });

    test('concurrent and repeated inits make one native init', () async {
      final a = Unilitix.init('first', config: quiet);
      final b = Unilitix.init('second', config: quiet);
      await Future.wait([a, b]);
      await Unilitix.init('third', config: quiet);
      expect(native.named('init'), hasLength(1));
      expect(native.single('init')['apiKey'], 'first');
    });

    test('a failed native init disables the SDK without throwing', () async {
      native.failInit = true;
      Unilitix.track('before');
      await Unilitix.init('k', config: quiet);
      expect(Unilitix.isInitialized, isFalse);
      Unilitix.track('after');
      expect(native.methods, ['init'], reason: 'nothing else crosses');
    });

    test('a decision the native SDK persisted wins over init\'s consent',
        () async {
      native
        ..consent = 'denied'
        ..consentPersisted = true;
      await Unilitix.init('k', config: quiet);
      expect(native.single('init')['consent'], 'granted');
      expect(Unilitix.consent, UnilitixConsent.denied);
    });

    test('without a persisted decision init\'s consent applies', () async {
      await Unilitix.init('k', config: quiet, consent: UnilitixConsent.pending);
      expect(Unilitix.consent, UnilitixConsent.pending);
    });
  });

  group('pre-init buffer', () {
    test('calls made before init reach the native SDK after it, in order',
        () async {
      await Unilitix.track('a', {'n': 1});
      await Unilitix.screen('Home');
      await Unilitix.identify('u1', {'plan': 'pro'});
      Unilitix.captureException(StateError('early'),
          stackTrace: StackTrace.fromString('#0 f (package:app/a.dart:1:2)'));
      await Unilitix.setConsent(UnilitixConsent.pending);
      await Unilitix.track('b');
      expect(native.calls, isEmpty);

      await Unilitix.init('k', config: quiet);
      expect(native.methods, [
        'init',
        'track',
        'screen',
        'identify',
        'recordError',
        'setConsent',
        'track',
      ]);
      expect(native.calls[1].arguments, {
        'name': 'a',
        'properties': {'n': 1}
      });
      expect(Unilitix.consent, UnilitixConsent.pending,
          reason: 'a decision made before init wins over init\'s answer');
    });

    test('at most preInitBufferSize calls are kept, the oldest dropped',
        () async {
      for (var i = 0; i < SdkContract.preInitBufferSize + 5; i++) {
        await Unilitix.track('e$i');
      }
      await Unilitix.init('k', config: quiet);
      final names =
          native.named('track').map((c) => (c.arguments as Map)['name']);
      expect(names.first, 'e5');
      expect(names, hasLength(SdkContract.preInitBufferSize));
    });
  });

  group('forwarding', () {
    setUp(() async {
      await Unilitix.init('k', config: quiet);
      native.clear();
    });

    test('track, identify, screen and the session calls', () async {
      await Unilitix.track('purchase', {
        'amount': 5000,
        'items': [1, 2],
        'at': DateTime.utc(2026, 1, 5)
      });
      await Unilitix.identify('u1', {'plan': 'pro'});
      await Unilitix.screen('Checkout');
      await Unilitix.flush();
      await Unilitix.reset();
      await Unilitix.startSession();
      await Unilitix.endSession();
      Unilitix.addBreadcrumb('paid', category: 'flow', data: {'items': 3});

      expect(native.methods, [
        'track',
        'identify',
        'screen',
        'flush',
        'reset',
        'startSession',
        'endSession',
        'addBreadcrumb',
      ]);
      expect(native.calls[0].arguments, {
        'name': 'purchase',
        'properties': {
          'amount': 5000,
          'items': [1, 2],
          'at': '2026-01-05T00:00:00.000Z'
        }
      });
      expect(native.calls[1].arguments, {
        'userId': 'u1',
        'traits': {'plan': 'pro'}
      });
      expect(native.calls[2].arguments, {'name': 'Checkout'});
      expect(SdkScope.currentScreen, 'Checkout');
      expect(native.calls.last.arguments,
          {'message': 'paid {"items":3}', 'category': 'flow'});
    });

    test('consent changes are passed through and mirrored', () async {
      await Unilitix.setConsent(UnilitixConsent.pending);
      expect(Unilitix.consent, UnilitixConsent.pending);
      await Unilitix.optOut();
      expect(Unilitix.consent, UnilitixConsent.denied);
      await Unilitix.optIn();
      expect(Unilitix.consent, UnilitixConsent.granted);
      expect(
          native
              .named('setConsent')
              .map((c) => (c.arguments as Map)['consent']),
          ['pending', 'denied', 'granted']);
    });

    test('screens from the navigator observer', () async {
      final route = PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/pay'),
        pageBuilder: (_, __, ___) => const SizedBox(),
      );
      Unilitix.observer.didPush(route, null);
      expect(native.single('screen'), {'name': '/pay'});
    });
  });

  group('2.x migration', () {
    test('a consent decision 2.x stored is handed to the native SDK once',
        () async {
      SharedPreferences.setMockInitialValues({'unilitix_consent': 'denied'});
      await Unilitix.track('early');
      await Unilitix.init('k', config: quiet);

      expect(native.single('init')['consent'], 'denied');
      expect(native.methods.take(3).toList(), ['init', 'setConsent', 'track'],
          reason: 'the decision applies before any buffered call');
      expect(native.single('setConsent'), {'consent': 'denied'});
      expect(Unilitix.consent, UnilitixConsent.denied);
      await pumpEventQueue();
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('unilitix_consent'), isFalse);
    });

    test('the pre-2.1 opt-out flag counts as denied', () async {
      SharedPreferences.setMockInitialValues({'unilitix_opted_out': true});
      await Unilitix.init('k', config: quiet);
      expect(native.single('init')['consent'], 'denied');
    });
  });

  group('taps', () {
    test('Android: taps and rage taps are sent by Dart', () async {
      await Unilitix.init('k', config: quiet.copyWith(autoTrackTaps: true));
      native.clear();
      SdkScope.onTap!('Home', 10, 20);
      SdkScope.onTap!('Home', 12, 21);
      SdkScope.onTap!('Home', 14, 22);
      final taps = native.named('recordTap').map((c) => c.arguments).toList();
      expect(taps, [
        {'type': 'TAP', 'screen': 'Home', 'x': 10.0, 'y': 20.0},
        {'type': 'TAP', 'screen': 'Home', 'x': 12.0, 'y': 21.0},
        {'type': 'RAGE_TAP', 'screen': 'Home', 'x': 12.0, 'y': 21.0},
      ]);
    });

    test('iOS: the native SDK records taps, Dart sends none', () async {
      native.dartTaps = false;
      await Unilitix.init('k', config: quiet.copyWith(autoTrackTaps: true));
      SdkScope.onTap!('Home', 10, 20);
      expect(native.named('recordTap'), isEmpty);
    });

    test('autoTrackTaps off sends none', () async {
      await Unilitix.init('k', config: quiet.copyWith(autoTrackTaps: false));
      SdkScope.onTap!('Home', 10, 20);
      expect(native.named('recordTap'), isEmpty);
    });
  });

  group('replay gating', () {
    test(
        'capture runs only while the native session is sampled and consent '
        'is not denied', () async {
      native.replaySampled = false;
      await Unilitix.init('k',
          config:
              quiet.copyWith(captureSnapshots: true, captureScreenshots: true));
      expect(Unilitix.debugSnapshots!.isActive, isFalse);
      expect(Unilitix.debugScreenshots!.isActive, isFalse);

      native.replaySampled = true;
      await Unilitix.debugRefreshReplayState();
      expect(Unilitix.debugSnapshots!.isActive, isTrue);
      expect(Unilitix.debugScreenshots!.isActive, isTrue);

      await Unilitix.setConsent(UnilitixConsent.denied);
      expect(Unilitix.debugSnapshots!.isActive, isFalse);
      expect(Unilitix.debugScreenshots!.isActive, isFalse);

      await Unilitix.setConsent(UnilitixConsent.pending);
      expect(Unilitix.debugSnapshots!.isActive, isTrue,
          reason: 'pending still captures (held on the device)');
    });
  });
}
