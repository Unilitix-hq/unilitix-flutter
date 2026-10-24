import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/generated/ingest_models.dart';
import 'package:unilitix/src/storage/event_database.dart';

/// 2.1.2 crash credibility: stable grouping, per-session dedup, chained
/// handlers, native marker attribution, and build ids for symbolication.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const symbolized = '''
#0      CheckoutPage.pay (package:shop/checkout.dart:120:7)
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1183:21)
#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:351:24)
#3      TapGestureRecognizer.handleTapUp (package:flutter/src/gestures/tap.dart:656:11)
''';
  const symbolizedMoved = '''
#0      CheckoutPage.pay (package:shop/checkout.dart:131:9)
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1183:21)
#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:351:24)
''';
  const obfuscated = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1234, tid: 1234, name: main
os: android arch: arm64 comp: yes sim: no
build_id: 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6'
isolate_dso_base: 7a1c200000, vm_dso_base: 7a1c200000
isolate_instructions: 7a1c3c0000, vm_instructions: 7a1c3b0000
    #00 abs 0000007a1c4d2b virt 00000000002d2b _kDartIsolateSnapshotInstructions+0x112b
    #01 abs 0000007a1c4f10 virt 00000000002f10 _kDartIsolateSnapshotInstructions+0x1310
    #02 abs 0000007a1c5a00 virt 0000000000003a00 _kDartIsolateSnapshotInstructions+0x1e00
''';

  group('fingerprint', () {
    test('ignores line and column numbers of the same frames', () {
      final a = CrashTracker.fingerprint('StateError', symbolized);
      final b = CrashTracker.fingerprint('StateError', symbolizedMoved);
      expect(a, b);
      expect(a, hasLength(16));
    });

    test('differs by exception type and by frame', () {
      final a = CrashTracker.fingerprint('StateError', symbolized);
      expect(CrashTracker.fingerprint('RangeError', symbolized), isNot(a));
      expect(
          CrashTracker.fingerprint('StateError',
              symbolized.replaceFirst('CheckoutPage.pay', 'CartPage.add')),
          isNot(a));
    });

    test('uses virt offsets for obfuscated traces', () {
      final a = CrashTracker.fingerprint('SIGNAL:11', obfuscated);
      final b = CrashTracker.fingerprint('SIGNAL:11',
          obfuscated.replaceAll('abs 0000007a1c', 'abs 0000007b9f'));
      expect(a, b, reason: 'absolute addresses change per launch');
      expect(
          CrashTracker.fingerprint(
              'SIGNAL:11',
              obfuscated.replaceFirst(
                  'virt 00000000002d2b', 'virt 0000000000ffff')),
          isNot(a));
    });

    test('is stable across runs (no process salt)', () {
      expect(CrashTracker.fingerprint('X', null),
          CrashTracker.fingerprint('X', null));
    });
  });

  group('crashMetadata', () {
    test('carries build ids from an obfuscated trace', () {
      final m = CrashTracker.crashMetadata('abc', 2, obfuscated);
      expect(m['fingerprint'], 'abc');
      expect(m['occurrence'], 2);
      expect(m['buildId'], 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6');
      expect(m['isolateDsoBase'], '7a1c200000');
    });

    test('omits build ids when the trace is symbolized', () {
      final m = CrashTracker.crashMetadata('abc', 1, symbolized);
      expect(m.containsKey('buildId'), isFalse);
    });

    test('rides the declared metadata field of the contract', () {
      final e = UnilitixEvent(type: EventTypes.crash)
        ..crashMetadata = CrashTracker.crashMetadata('fp', 1, obfuscated);
      final wire = e.toJson();
      expect(wire.keys.where((k) => !IngestEvent.fields.contains(k)), isEmpty);
      expect((wire['metadata'] as Map)['fingerprint'], 'fp');
    });
  });

  group('recording', () {
    late List<UnilitixEvent> crashes;
    late List<UnilitixEvent> exceptions;
    late CrashTracker tracker;

    setUp(() {
      crashes = [];
      exceptions = [];
      tracker = CrashTracker(
        onCrashEvent: crashes.add,
        onExceptionEvent: exceptions.add,
        breadcrumbs: [
          {'type': 'NAVIGATE', 'screen': '/pay'}
        ],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
        maxPerFingerprint: 2,
        maxPerSession: 3,
      );
    });

    test('same bug is reported at most maxPerFingerprint times a session', () {
      for (var i = 0; i < 5; i++) {
        tracker.capture(StateError('x'), StackTrace.fromString(symbolized));
      }
      expect(exceptions, hasLength(2));
      expect(exceptions[0].crashMetadata!['occurrence'], 1);
      expect(exceptions[1].crashMetadata!['occurrence'], 2);
      tracker.resetSession();
      tracker.capture(StateError('x'), StackTrace.fromString(symbolized));
      expect(exceptions, hasLength(3), reason: 'new session, counted again');
    });

    test('total reports per session are capped', () {
      for (var i = 0; i < 10; i++) {
        tracker.capture(
            StateError('bug $i'), StackTrace.fromString('#0 f$i (a.dart:1:1)'));
      }
      expect(exceptions, hasLength(3));
    });

    test('fatal captures go to the crash callback with breadcrumbs', () {
      tracker.capture(ArgumentError('bad'), StackTrace.fromString(symbolized),
          fatal: true);
      expect(crashes, hasLength(1));
      expect(crashes.single.breadcrumbs, hasLength(1));
      expect(crashes.single.exceptionType, 'ArgumentError');
      expect(crashes.single.fatal, isFalse, reason: 'Dart errors never kill');
    });

    test('errors thrown inside the SDK are not recorded', () {
      tracker.capture(
          StateError('sdk'),
          StackTrace.fromString(
              '#0 Unilitix.track (package:unilitix/unilitix.dart:1:1)'));
      expect(exceptions, isEmpty);
    });
  });

  group('handler chaining', () {
    test(
        'PlatformDispatcher.onError calls the previous handler and keeps its '
        'verdict', () {
      final crashes = <UnilitixEvent>[];
      final tracker = CrashTracker(
        onCrashEvent: crashes.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      final previousFlutter = FlutterError.onError;
      final previousPlatform = PlatformDispatcher.instance.onError;
      var upstreamCalls = 0;
      PlatformDispatcher.instance.onError = (e, st) {
        upstreamCalls++;
        return true;
      };
      try {
        tracker.install();
        final handled = PlatformDispatcher.instance.onError!(
            StateError('boom'), StackTrace.fromString(symbolized));
        expect(handled, isTrue, reason: 'upstream said handled');
        expect(upstreamCalls, 1);
        expect(crashes, hasLength(1));
        expect(crashes.single.type, EventTypes.crash);
      } finally {
        tracker.uninstall();
        PlatformDispatcher.instance.onError = previousPlatform;
        FlutterError.onError = previousFlutter;
      }
      expect(PlatformDispatcher.instance.onError, same(previousPlatform));
    });
  });

  group('native markers', () {
    test('a signal marker becomes a fatal CRASH with its timestamp', () {
      int? ts;
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"ios","exceptionType":"SIGNAL","signal":11,"timestamp":1760700000000}',
        onTimestamp: (t) => ts = t,
      )!;
      expect(ts, 1760700000000);
      expect(e.fatal, isTrue);
      expect(e.type, EventTypes.crash);
      expect(e.exceptionType, 'SIGNAL');
      expect(e.exceptionMessage, '[ios] Fatal signal 11');
      expect(e.crashMetadata!['fingerprint'], isNotEmpty);
    });

    test('an Android JVM marker keeps type, message and stack', () {
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"android","thread":"main","exceptionType":"java.lang.IllegalStateException","exceptionMessage":"nope","stackTrace":"at a.b(c.kt:1)","timestamp":1}',
        onTimestamp: (_) {},
      )!;
      expect(e.title, startsWith('java.lang.IllegalStateException: nope'));
      expect(e.stackTrace, 'at a.b(c.kt:1)');
    });

    test('an iOS record carries its UnilitixCore fingerprint, used as is', () {
      // What UnilitixCore's CrashFile.consume returns: the on-disk record
      // (sorted keys) plus the contract fingerprint over the Apple frames.
      const stack = '2   Shop  0x1043a81c4 -[Cart pay:] + 52';
      final raw = jsonEncode({
        'exceptionMessage': 'index 3',
        'exceptionType': 'NSRangeException',
        'fingerprint': '0123456789abcdef',
        'platform': 'ios',
        'stackTrace': stack,
        'timestamp': 1760700000123,
      });
      int? ts;
      final e = CrashTracker.eventFromNativeMarker(
        raw,
        onTimestamp: (t) => ts = t,
      )!;
      expect(ts, 1760700000123);
      expect(e.crashMetadata!['fingerprint'], '0123456789abcdef');
      expect(e.exceptionType, 'NSRangeException');
      expect(e.exceptionMessage, '[ios] index 3');
      expect(e.title, 'NSRangeException: index 3');
      expect(e.stackTrace, stack);
    });

    test('without one, a signal is keyed as UnilitixCore keys it', () {
      // UnilitixCore's CrashFileTests pins Fingerprint.of("SIGNAL:11") to
      // the same value, so records from 2.2.x plugins group with new ones.
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"ios","exceptionType":"SIGNAL","signal":11,"timestamp":1}',
        onTimestamp: (_) {},
      )!;
      expect(e.crashMetadata!['fingerprint'], '8f1fc15bfa06be00');
    });

    test('an empty native fingerprint falls back to the Dart one', () {
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"ios","exceptionType":"SIGNAL","signal":11,"timestamp":1,"fingerprint":""}',
        onTimestamp: (_) {},
      )!;
      expect(e.crashMetadata!['fingerprint'], '8f1fc15bfa06be00');
    });

    test('garbage is ignored', () {
      expect(CrashTracker.eventFromNativeMarker('nope', onTimestamp: (_) {}),
          isNull);
    });

    test('an Android signal record (2.4.0 plugin) keeps its name and key', () {
      // What NativeCrashBridge.recordFor returns for a SIGSEGV, from the
      // signal handler (API 21-29) or ApplicationExitInfo (API 30+).
      int? ts;
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"android","exceptionType":"SIGNAL","signal":11,'
        '"exceptionMessage":"Fatal signal 11 (SIGSEGV)",'
        '"timestamp":1760700000123,"fingerprint":"8f1fc15bfa06be00"}',
        onTimestamp: (t) => ts = t,
      )!;
      expect(ts, 1760700000123);
      expect(e.fatal, isTrue);
      expect(e.title, 'SIGNAL: Fatal signal 11 (SIGSEGV)');
      expect(e.exceptionMessage, '[android] Fatal signal 11 (SIGSEGV)');
      expect(e.crashMetadata!['fingerprint'], '8f1fc15bfa06be00');
    });

    test('an Android record with an unknown signal is keyed SIGNAL', () {
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"android","exceptionType":"SIGNAL","timestamp":1}',
        onTimestamp: (_) {},
      )!;
      expect(e.crashMetadata!['fingerprint'],
          CrashTracker.fingerprint('SIGNAL', null));
      expect(e.title, 'SIGNAL: Native crash');
    });
  });

  group('reading native records', () {
    const channel = MethodChannel('com.unilitix/sdk');
    late List<UnilitixEvent> crashes;
    late CrashTracker tracker;

    void serve(List<String?> records, {List<String>? calls}) {
      final queue = List<String?>.of(records);
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls?.add(call.method);
        if (call.method != 'readNativeCrash') return null;
        return queue.isEmpty ? null : queue.removeAt(0);
      });
    }

    setUp(() {
      crashes = [];
      tracker = CrashTracker(
        onCrashEvent: crashes.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    String signal(int n, int ts) =>
        '{"platform":"android","exceptionType":"SIGNAL","signal":$n,'
        '"timestamp":$ts}';

    test('every record is read, oldest first, each attributed on its own',
        () async {
      serve([signal(11, 1000), signal(6, 2000), null]);
      final attributed = <int?>[];
      final reported = <String, UnilitixEvent>{};
      final found = await tracker.reportNativeCrashIfAny(
        attribute: (ts) async {
          attributed.add(ts);
          return CrashAttribution(ts == 1000 ? 's-old' : null);
        },
        report: (id, e) async => reported[id] = e,
      );
      expect(found, isTrue);
      expect(attributed, [1000, 2000]);
      expect(reported.keys.toList(), ['s-old']);
      expect(reported['s-old']!.exceptionMessage, '[android] Fatal signal 11');
      expect(crashes, hasLength(1), reason: 'no match: current session');
      expect(crashes.single.exceptionMessage, '[android] Fatal signal 6');
    });

    test('one record then null (iOS) reports one', () async {
      final calls = <String>[];
      serve([signal(11, 1)], calls: calls);
      expect(await tracker.reportNativeCrashIfAny(), isTrue);
      expect(crashes, hasLength(1));
      expect(calls, ['readNativeCrash', 'readNativeCrash']);
    });

    test('an unreadable record is skipped, the next one still read', () async {
      serve(['nope', signal(11, 1)]);
      expect(await tracker.reportNativeCrashIfAny(), isTrue);
      expect(crashes, hasLength(1));
    });

    test('nothing pending reports nothing', () async {
      serve([]);
      expect(await tracker.reportNativeCrashIfAny(), isFalse);
      expect(crashes, isEmpty);
    });

    test('reads are capped per launch', () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (_) async => signal(11, 1));
      await tracker.reportNativeCrashIfAny();
      expect(crashes, hasLength(CrashTracker.maxNativeCrashesPerLaunch));
    });

    test('no native hook (MissingPluginException) is not a crash', () async {
      expect(await tracker.reportNativeCrashIfAny(), isFalse);
      expect(await tracker.discardNativeCrashes(), 0);
    });

    test('consent denied: records are consumed and dropped', () async {
      final calls = <String>[];
      serve([signal(11, 1), signal(6, 2)], calls: calls);
      expect(await tracker.discardNativeCrashes(), 2);
      expect(crashes, isEmpty);
      expect(calls, hasLength(3), reason: 'read until null');
      expect(await tracker.reportNativeCrashIfAny(), isFalse);
    });
  });
}
