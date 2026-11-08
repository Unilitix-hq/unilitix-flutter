// Behaviour fixtures (contract 1.4.0, test/behaviour/) run against the
// Dart layer of the SDK.
//
// Since 3.0.0 the engine the fixtures describe (sessions, queue, uploads,
// retry, consent effects, normalisation, native crashes) is the native
// SDKs', and their own runners check the fixtures' expectations end to end.
// This runner checks the part only the Dart layer can get wrong, for every
// case that applies to `flutter`:
//
//  * each app call reaches the native SDK exactly once, in call order, with
//    exactly the arguments the app passed (method channel `com.unilitix/sdk`,
//    recorded by a fake plugin);
//  * calls made before `init` are buffered (preInitBufferSize, oldest
//    dropped) and replayed right after the native `init`;
//  * `init` passes the case's options (canonical keys) and the wrapper
//    identity; a second `init` in one process is not passed on;
//  * `recordError` is reported with platform `dart` and the contract
//    fingerprint the case expects in its events;
//  * `expectState` `consent` and `screen` match the Dart layer's mirror.
//
// Steps that only the native SDK observes (advanceTime, setNetwork,
// background/foreground, serverResponds, crashNextLaunch) make no Dart
// call; request/event expectations are the native runners'. See
// test/behaviour/COVERAGE.md for which case is covered where.
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/consent.dart';
import 'package:unilitix/src/core/sdk_scope.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';
import 'package:unilitix/unilitix.dart';

import 'behaviour_fixtures.dart';
import 'support/fake_native.dart';

const _fixturesDir = 'test/behaviour';

/// Steps the Dart layer has nothing to do for.
const _nativeOnlySteps = {
  'advanceTime',
  'setNetwork',
  'background',
  'foreground',
  'serverResponds',
  'crashNextLaunch',
  'expectRequests',
  'expectEvents',
};

/// Contract options the Dart SDK does not have (`flutter: —` in
/// sdk-contract.md): the observer reports screens.
const _notFlutterOptions = {'autoTrackScreens'};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final fixtures = BehaviourFixtures.load(_fixturesDir, platform: 'flutter');

  test('the fixtures are the contract version of the generated constants', () {
    expect(behaviourContractVersion, SdkContract.version);
    expect(fixtures.cases, isNotEmpty);
  });

  for (final c in fixtures.cases) {
    test(c.id, () => _Runner(c, fixtures.harness).run());
  }
}

class _Expected {
  _Expected(this.method, this.arguments);
  final String method;
  final Object? arguments;
}

class _Runner {
  _Runner(this.c, this.harness);

  final BehaviourCase c;
  final Map<String, dynamic> harness;
  final FakeNative native = FakeNative();

  /// What the native side must have received, in order.
  final List<_Expected> expected = [];

  /// Calls made before `init` in the current process.
  final List<_Expected> preInit = [];
  bool initialisedInProcess = false;

  /// `metadata.fingerprint` literals the case expects on error events.
  final Set<String> expectedFingerprints = {};

  Future<void> run() async {
    SharedPreferences.setMockInitialValues({});
    Unilitix.debugReset();
    native.install();
    try {
      for (final step in c.steps) {
        await _step(step.action, step.args);
      }
      _verify();
    } finally {
      Unilitix.debugReset();
      native.uninstall();
    }
  }

  void _call(String method, Object? arguments) {
    final e = _Expected(method, arguments);
    if (initialisedInProcess) {
      expected.add(e);
    } else {
      if (preInit.length >= SdkContract.preInitBufferSize) preInit.removeAt(0);
      preInit.add(e);
    }
  }

  Future<void> _step(String action, Object? rawArgs) async {
    // Native-only steps are skipped before their arguments are read:
    // expectRequests carries a list, not a map.
    if (_nativeOnlySteps.contains(action) && action != 'expectEvents') return;
    final args = rawArgs is Map
        ? rawArgs.cast<String, Object?>()
        : const <String, Object?>{};
    switch (action) {
      case 'init':
        final config = _config();
        final consent =
            consentFromWireName(c.config['consent']) ?? UnilitixConsent.granted;
        await Unilitix.init(harness['apiKey'] as String,
            config: config, consent: consent);
        if (!initialisedInProcess) {
          initialisedInProcess = true;
          expected.add(_Expected('init', nativeInitArguments(config, consent)));
          expected.addAll(preInit);
          preInit.clear();
        }
      case 'track':
        final name = decodeInput(args['name']) as String;
        final props = decodeInput(args['properties']) as Map<String, Object?>?;
        await Unilitix.track(name, props);
        _call('track', {'name': name, 'properties': props ?? const {}});
      case 'screen':
        final name = decodeInput(args['name']) as String;
        await Unilitix.screen(name);
        _call('screen', {'name': name});
      case 'identify':
        final userId = decodeInput(args['userId']) as String;
        final traits = decodeInput(args['traits']) as Map<String, Object?>?;
        await Unilitix.identify(userId, traits);
        _call('identify', {'userId': userId, 'traits': traits ?? const {}});
      case 'reset':
        await Unilitix.reset();
        _call('reset', null);
      case 'flush':
        await Unilitix.flush();
        _call('flush', null);
      case 'setConsent':
        final state = consentFromWireName(args['state'])!;
        await Unilitix.setConsent(state);
        _call('setConsent', {'consent': state.name});
      case 'recordError':
        final type = args['type'] as String;
        final message = args['message'] as String;
        final stack = args['stack'] as String?;
        final fatal = args['fatal'] as bool;
        Unilitix.recordException(type, message,
            stackTrace: stack, fatal: fatal);
        _call('recordError', {
          'type': type,
          'message': message,
          'stackTrace': stack,
          'fatal': fatal,
          'platform': 'dart',
          'fingerprint': CrashTracker.contractFingerprint(type, stack),
          'metadata': const <String, Object?>{},
        });
      case 'repeat':
        final times = args['times'] as int;
        final steps = args['steps'] as List;
        for (var i = 0; i < times; i++) {
          for (final raw in steps) {
            final s = BehaviourStep.fromJson(
                Map<String, dynamic>.from(substitute(raw, i) as Map));
            await _step(s.action, s.args);
          }
        }
      case 'restart':
        // Process death: the Dart layer forgets everything; the fake plugin
        // keeps its state (the native SDK's disk) and its recording.
        Unilitix.debugReset();
        initialisedInProcess = false;
        preInit.clear();
      case 'expectState':
        await pumpEventQueue();
        final want = args;
        if (want['consent'] is String) {
          expect(Unilitix.consent.name, want['consent'],
              reason: '${c.id}: consent mirror');
        }
        if (want['screen'] is String) {
          expect(SdkScope.currentScreen, want['screen'],
              reason: '${c.id}: current screen');
        }
      case 'expectEvents':
        _collectFingerprints(args['events']);
      default:
        if (!_nativeOnlySteps.contains(action)) {
          fail('${c.id}: unknown step $action');
        }
    }
  }

  UnilitixConfig _config() {
    var cfg = UnilitixConfig(
      apiKey: harness['apiKey'] as String,
      apiUrl: harness['apiUrl'] as String,
    );
    for (final MapEntry(:key, :value) in c.config.entries) {
      if (_notFlutterOptions.contains(key) || key == 'consent') continue;
      cfg = switch (key) {
        'debug' => cfg.copyWith(debug: value as bool),
        'autoTrackTaps' => cfg.copyWith(autoTrackTaps: value as bool),
        'autoTrackRageTaps' => cfg.copyWith(autoTrackRageTaps: value as bool),
        'autoTrackCrashes' => cfg.copyWith(autoTrackCrashes: value as bool),
        'captureSnapshots' => cfg.copyWith(captureSnapshots: value as bool),
        'captureScreenshots' => cfg.copyWith(captureScreenshots: value as bool),
        'flushIntervalSeconds' =>
          cfg.copyWith(flushIntervalSeconds: value as int),
        'flushBatchSize' => cfg.copyWith(flushBatchSize: value as int),
        'maxOfflineEvents' => cfg.copyWith(maxOfflineEvents: value as int),
        'sessionTimeoutSeconds' =>
          cfg.copyWith(sessionTimeoutSeconds: value as int),
        'replaySampleRate' =>
          cfg.copyWith(replaySampleRate: (value as num).toDouble()),
        _ => throw StateError('${c.id}: option $key has no Flutter mapping '
            '(fixture bug, or add it here)'),
      };
    }
    return cfg;
  }

  void _collectFingerprints(Object? events) {
    if (events is! List) return;
    for (final e in events) {
      if (e is! Map) continue;
      final type = e['type'];
      final fp = (e['metadata'] as Map?)?['fingerprint'];
      if ((type == 'EXCEPTION' || type == 'CRASH') &&
          fp is String &&
          RegExp(r'^[0-9a-f]{16}$').hasMatch(fp)) {
        expectedFingerprints.add(fp);
      }
    }
  }

  void _verify() {
    final actual = [
      for (final call in native.calls)
        if (call.method != 'replayState') call
    ];
    final got = actual.map((m) => m.method).toList();
    final want = expected.map((e) => e.method).toList();
    expect(got, want, reason: '${c.id}: native calls in order');
    for (var i = 0; i < expected.length; i++) {
      expect(_jsonEqual(actual[i].arguments, expected[i].arguments), isTrue,
          reason: '${c.id}: arguments of call $i (${expected[i].method}):\n'
              'got  ${_describe(actual[i])}\n'
              'want ${expected[i].arguments}');
    }
    if (expectedFingerprints.isNotEmpty) {
      for (final call in native.named('recordError')) {
        expect(expectedFingerprints,
            contains((call.arguments as Map)['fingerprint']),
            reason: '${c.id}: Dart fingerprint matches the contract');
      }
    }
  }

  static String _describe(MethodCall call) {
    final s = '${call.arguments}';
    return s.length > 300 ? '${s.substring(0, 300)}…' : s;
  }
}

/// Deep equality of channel values, with NaN equal to NaN (the fixtures
/// send non-finite numbers on purpose; normalising them is native work).
bool _jsonEqual(Object? a, Object? b) {
  if (a is num && b is num) {
    if (a.isNaN && b.isNaN) return true;
    return a == b;
  }
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final key in a.keys) {
      if (!b.containsKey(key) || !_jsonEqual(a[key], b[key])) return false;
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!_jsonEqual(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
