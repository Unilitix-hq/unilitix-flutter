import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/core/sdk_scope.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/events/event.dart';
import 'package:unilitix/src/generated/ingest_models.dart';
import 'package:unilitix/src/storage/event_database.dart';

/// 2.1.2 crash credibility: stable grouping, per-session dedup, chained
/// handlers, native marker attribution, and build ids for symbolication.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // The contract's "android anr main thread" vector (fingerprint
  // ff80a5189f547c4d), as the plugin sends it.
  const anrMainThread = '"main" prio=5 tid=1 Native\n'
      '  native: #00 pc 000000000009a1b8  /apex/com.android.runtime/lib64/bionic/libc.so (read+8)\n'
      '  native: #01 pc 0000000000012c34  /system/lib64/libsqlite.so (unixRead+52)\n'
      '  at android.database.sqlite.SQLiteConnection.nativeExecuteForCursorWindow(Native method)\n'
      '  at android.database.sqlite.SQLiteConnection.executeForCursorWindow(SQLiteConnection.java:1001)\n'
      '  - locked <0x0b1c2d3e> (a android.database.sqlite.SQLiteConnection)\n'
      '  at com.shop.cart.CartRepository.load(CartRepository.kt:88)\n'
      '  at com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)';
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

  group('ANR records', () {
    // What NativeCrashBridge.recordFor(Anr) returns (Android plugin 2.6.0).
    Map<String, dynamic> record({
      String? fingerprint = 'ff80a5189f547c4d',
      int? importance = 100,
    }) =>
        {
          'type': 'ANR',
          'platform': 'android',
          'exceptionType': 'ANR',
          'exceptionMessage': 'Input dispatching timed out',
          'stackTrace': anrMainThread,
          'timestamp': 1760700000123,
          if (fingerprint != null) 'fingerprint': fingerprint,
          if (importance != null) 'importance': importance,
          if (importance != null) 'foreground': importance <= 100,
        };

    test('becomes an ANR event, not a crash, with its kill time', () {
      int? ts;
      final e = CrashTracker.eventFromNativeMarker(
        jsonEncode(record()),
        onTimestamp: (t) => ts = t,
      )!;
      expect(ts, 1760700000123);
      expect(e.type, EventTypes.anr);
      expect(e.exceptionType, 'ANR');
      expect(e.exceptionMessage, 'Input dispatching timed out');
      expect(e.stackTrace, anrMainThread);
      expect(e.title, isNull);
      expect(e.crashMetadata, {
        'fingerprint': 'ff80a5189f547c4d',
        'platform': 'android',
        'importance': 100,
        'foreground': true,
      });
    });

    test('wire shape: no fatal, no title, declared fields only', () {
      final e = CrashTracker.eventFromNativeMarker(
        jsonEncode(record()),
        onTimestamp: (_) {},
      )!;
      final wire = e.toJson();
      expect(wire['type'], 'ANR');
      expect(wire.containsKey('fatal'), isFalse);
      expect(wire.containsKey('title'), isFalse);
      expect(wire['exceptionType'], 'ANR');
      expect(wire['stackTrace'], anrMainThread);
      expect(wire['breadcrumbs'], isEmpty);
      expect((wire['metadata'] as Map)['fingerprint'], 'ff80a5189f547c4d');
      final unknown =
          wire.keys.where((k) => !IngestEvent.fields.contains(k)).toList();
      expect(unknown, isEmpty);
      expect(IngestEvent.fromJson(wire).type, 'ANR');
    });

    test('without the plugin fingerprint, the contract one is computed', () {
      final e = CrashTracker.eventFromNativeMarker(
        jsonEncode(record(fingerprint: null)),
        onTimestamp: (_) {},
      )!;
      // SDK contract 1.3.0, vector "android anr main thread".
      expect(e.crashMetadata!['fingerprint'], 'ff80a5189f547c4d');
    });

    test('unknown importance leaves importance and foreground out', () {
      final e = CrashTracker.eventFromNativeMarker(
        jsonEncode(record(importance: null)),
        onTimestamp: (_) {},
      )!;
      expect(e.crashMetadata!.containsKey('importance'), isFalse);
      expect(e.crashMetadata!.containsKey('foreground'), isFalse);
    });

    test('an empty message and stack still make an event', () {
      final e = CrashTracker.eventFromNativeMarker(
        '{"type":"ANR","exceptionType":"ANR","timestamp":1}',
        onTimestamp: (_) {},
      )!;
      expect(e.type, EventTypes.anr);
      expect(e.exceptionMessage, 'Application Not Responding');
      expect(e.stackTrace, '');
      expect(e.crashMetadata!['fingerprint'],
          CrashTracker.contractFingerprint('ANR', ''));
      expect(e.crashMetadata!['platform'], 'android');
    });

    test('a crash record without type stays a CRASH', () {
      final e = CrashTracker.eventFromNativeMarker(
        '{"platform":"android","exceptionType":"ANR","timestamp":1}',
        onTimestamp: (_) {},
      )!;
      expect(e.type, EventTypes.crash, reason: 'the type marker decides');
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

    String anrRecord({required int ts}) => jsonEncode({
          'type': 'ANR',
          'platform': 'android',
          'exceptionType': 'ANR',
          'exceptionMessage': 'Input dispatching timed out',
          'stackTrace': anrMainThread,
          'timestamp': ts,
          'fingerprint': 'ff80a5189f547c4d',
          'importance': 100,
          'foreground': true,
        });

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

    test('an ANR record is an ANR event for its own session, not a crash',
        () async {
      final anrs = <UnilitixEvent>[];
      final t = CrashTracker(
        onCrashEvent: crashes.add,
        onAnrEvent: anrs.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      serve([signal(11, 1000), anrRecord(ts: 2000), anrRecord(ts: 3000)]);
      final attributed = <int?>[];
      final reported = <String, UnilitixEvent>{};
      await t.reportNativeCrashIfAny(
        attribute: (ts) async {
          attributed.add(ts);
          return CrashAttribution(ts == 2000 ? 's-anr' : null);
        },
        report: (id, e) async => reported[id] = e,
      );
      expect(attributed, [1000, 2000, 3000]);
      expect(reported.keys.toList(), ['s-anr']);
      expect(reported['s-anr']!.type, EventTypes.anr);
      expect(anrs, hasLength(1), reason: 'no match: current session');
      expect(anrs.single.type, EventTypes.anr);
      expect(crashes, hasLength(1), reason: 'only the signal is a crash');
      expect(crashes.single.type, EventTypes.crash);
    });

    test('without onAnrEvent an ANR goes to onExceptionEvent', () async {
      final exceptions = <UnilitixEvent>[];
      final t = CrashTracker(
        onCrashEvent: crashes.add,
        onExceptionEvent: exceptions.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      serve([anrRecord(ts: 1)]);
      expect(await t.reportNativeCrashIfAny(), isTrue);
      expect(crashes, isEmpty);
      expect(exceptions.single.type, EventTypes.anr);
    });

    test('consent denied: ANR records are consumed and dropped too', () async {
      final calls = <String>[];
      serve([signal(11, 1), anrRecord(ts: 2)], calls: calls);
      expect(await tracker.discardNativeCrashes(), 2);
      expect(crashes, isEmpty);
      expect(await tracker.reportNativeCrashIfAny(), isFalse);
    });
  });
  group('iOS app hangs', () {
    const sdk = MethodChannel('com.unilitix/sdk');
    const hangChannel = 'com.unilitix/app_hang';
    const codec = StandardMethodCodec();
    const hangId = '6294f32f-bebe-4859-abe0-b1b03efa32f3';
    // Apple frames as UnilitixCore's ThreadSampler prints them.
    const appleStack =
        '0   libsystem_kernel.dylib              0x00000001e5a2b1c4 read + 8\n'
        '1   Runner                              0x0000000104a1c2d0 -[SlowPlugin handleMethodCall:result:] + 120\n'
        '2   Flutter                             0x0000000105b0e2a8 Flutter + 3211944\n'
        '3   UIKitCore                           0x0000000184c1e2a0 -[UIApplication sendEvent:] + 96';
    // Fingerprint.of("ANR", stack:) of the vendored UnilitixCore 0.6.0 for
    // appleStack (computed with Swift), which the plugin sends.
    const nativeFp = 'af5e4d72dd8272ad';
    const image = {
      'arch': 'arm64',
      'loadAddress': '0x104a18000',
      'name': 'Runner',
      'uuid': '6F1E2D3C-4B5A-6978-8796-A5B4C3D2E1F0',
    };

    // What PluginAppHangFile.record returns (UnilitixAppHangMonitor.swift).
    String iosRecord({
      bool terminated = false,
      int durationMs = 3200,
      String? fingerprint = nativeFp,
      String id = hangId,
    }) =>
        jsonEncode({
          'type': 'ANR',
          'exceptionType': 'ANR',
          'platform': 'ios',
          'id': id,
          'timestamp': 1760700008000,
          'exceptionMessage': terminated
              ? 'The main thread was blocked for at least $durationMs ms; '
                  'the app was terminated before it recovered'
              : 'The main thread was blocked for $durationMs ms',
          'stackTrace': appleStack,
          if (fingerprint != null) 'fingerprint': fingerprint,
          'metadata': {
            'appHangTimeoutMs': 2000,
            'debugImages': [image],
            if (fingerprint != null) 'fingerprint': fingerprint,
            'hangDurationMs': durationMs,
            'platform': 'ios',
            if (terminated) 'appTerminated': true,
          },
        });

    late List<UnilitixEvent> crashes;
    late List<UnilitixEvent> anrs;
    late CrashTracker tracker;
    late List<MethodCall> sdkCalls;

    setUp(() {
      crashes = [];
      anrs = [];
      sdkCalls = [];
      tracker = CrashTracker(
        onCrashEvent: crashes.add,
        onAnrEvent: anrs.add,
        breadcrumbs: [
          {'type': 'NAVIGATE', 'screen': 'Checkout'},
        ],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sdk, (call) async {
        sdkCalls.add(call);
        return null;
      });
    });

    tearDown(() {
      tracker.uninstall();
      SdkScope.currentScreen = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sdk, null);
    });

    /// Sends `onAppHang` as the plugin does; returns Dart's answer.
    Future<Object?> pushHang(String record) async {
      Object? answer;
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
        hangChannel,
        codec.encodeMethodCall(MethodCall('onAppHang', record)),
        (data) => answer = data == null ? null : codec.decodeEnvelope(data),
      );
      return answer;
    }

    test('appHangTimeoutMs defaults to 2000 and copies', () {
      const c = UnilitixConfig(apiKey: 'k');
      expect(c.appHangTimeoutMs, 2000);
      expect(c.copyWith(appHangTimeoutMs: 0).appHangTimeoutMs, 0);
      expect(c.copyWith(debug: true).appHangTimeoutMs, 2000);
    });

    test('the plugin fingerprint is the contract fingerprint of type ANR', () {
      expect(CrashTracker.contractFingerprint('ANR', appleStack), nativeFp);
    });

    test('a hang the app did not survive (readNativeCrash) is an ANR event',
        () {
      int? ts;
      final e = CrashTracker.eventFromNativeMarker(
        iosRecord(terminated: true, durationMs: 2000),
        onTimestamp: (t) => ts = t,
      )!;
      expect(ts, 1760700008000, reason: 'attributed by when the hang began');
      expect(e.type, EventTypes.anr);
      expect(e.fatal, isFalse);
      expect(e.title, isNull);
      expect(e.exceptionType, 'ANR');
      expect(
          e.exceptionMessage,
          'The main thread was blocked for at least 2000 ms; the app was '
          'terminated before it recovered');
      expect(e.stackTrace, appleStack);
      expect(e.id, hangId);
      expect(e.timestamp, 1760700008000);
      expect(e.breadcrumbs, isEmpty);
      expect(e.crashMetadata, {
        'fingerprint': nativeFp,
        'platform': 'ios',
        'hangDurationMs': 2000,
        'appHangTimeoutMs': 2000,
        'appTerminated': true,
        'debugImages': [image],
      });
    });

    test('wire shape: debugImages reach metadata, the hang id is the eventId',
        () {
      final e =
          CrashTracker.eventFromNativeMarker(iosRecord(), onTimestamp: (_) {})!;
      final wire = e.toJson();
      expect(wire['eventId'], hangId);
      expect(wire['type'], 'ANR');
      expect(wire.containsKey('fatal'), isFalse);
      expect(wire.containsKey('title'), isFalse);
      final metadata = wire['metadata'] as Map;
      expect(metadata['debugImages'], [image]);
      expect(metadata['hangDurationMs'], 3200);
      expect(metadata.containsKey('appTerminated'), isFalse);
      final unknown =
          wire.keys.where((k) => !IngestEvent.fields.contains(k)).toList();
      expect(unknown, isEmpty);
      expect(IngestEvent.fromJson(wire).type, 'ANR');
    });

    test('without the plugin fingerprint the same one is computed', () {
      final e = CrashTracker.eventFromNativeMarker(iosRecord(fingerprint: null),
          onTimestamp: (_) {})!;
      expect(e.crashMetadata!['fingerprint'], nativeFp);
    });

    test('an id that is not a UUID is not used as the event id', () {
      final e = CrashTracker.eventFromNativeMarker(iosRecord(id: 'x'),
          onTimestamp: (_) {})!;
      expect(e.id, isNot('x'));
      expect(e.id, matches(RegExp(r'^[0-9a-f-]{36}$')));
    });

    test('Android records keep a new event id and the time of reporting', () {
      final before = DateTime.now().millisecondsSinceEpoch;
      final e = CrashTracker.eventFromNativeMarker(
        jsonEncode({
          'type': 'ANR',
          'platform': 'android',
          'id': hangId,
          'timestamp': 1,
          'stackTrace': anrMainThread,
        }),
        onTimestamp: (_) {},
      )!;
      expect(e.id, isNot(hangId));
      expect(e.timestamp, greaterThanOrEqualTo(before));
    });

    test('a terminated hang read at launch goes to its own session', () async {
      final queue = <String?>[iosRecord(terminated: true)];
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(sdk, (call) async {
        if (call.method != 'readNativeCrash') return null;
        return queue.isEmpty ? null : queue.removeAt(0);
      });
      final reported = <String, UnilitixEvent>{};
      await tracker.reportNativeCrashIfAny(
        attribute: (ts) async =>
            CrashAttribution(ts == 1760700008000 ? 's-hung' : null),
        report: (id, e) async => reported[id] = e,
      );
      expect(reported['s-hung']!.type, EventTypes.anr);
      expect(reported['s-hung']!.crashMetadata!['appTerminated'], isTrue);
      expect(crashes, isEmpty);
      expect(anrs, isEmpty);
    });

    test('a live hang is an ANR in the current session, not a crash', () {
      SdkScope.currentScreen = 'Checkout';
      expect(tracker.handleAppHang(iosRecord()), isTrue);
      expect(crashes, isEmpty);
      final e = anrs.single;
      expect(e.type, EventTypes.anr);
      expect(e.screen, 'Checkout');
      expect(e.breadcrumbs, [
        {'type': 'NAVIGATE', 'screen': 'Checkout'},
      ]);
      expect(e.exceptionMessage, 'The main thread was blocked for 3200 ms');
      expect(e.crashMetadata!['debugImages'], [image]);
      expect(e.crashMetadata!['hangDurationMs'], 3200);
      expect(e.crashMetadata!.containsKey('appTerminated'), isFalse);
      expect(e.id, hangId);
    });

    test('live hangs follow the per-session caps', () {
      for (var i = 0; i < 5; i++) {
        tracker.handleAppHang(
            iosRecord(id: '00000000-0000-4000-8000-00000000000$i'));
      }
      expect(anrs, hasLength(3), reason: 'maxPerFingerprint');
      tracker.resetSession();
      expect(tracker.handleAppHang(iosRecord()), isTrue);
      expect(anrs, hasLength(4));
    });

    test('live hangs share the per-session total with errors', () {
      final t = CrashTracker(
        onCrashEvent: crashes.add,
        onAnrEvent: anrs.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
        maxPerSession: 2,
      );
      t.capture(StateError('a'),
          StackTrace.fromString('#0      A.a (package:app/a.dart:1:1)'));
      t.capture(StateError('b'),
          StackTrace.fromString('#0      B.b (package:app/b.dart:1:1)'));
      expect(t.handleAppHang(iosRecord()), isFalse);
      expect(anrs, isEmpty);
    });

    test('without onAnrEvent a live hang goes to onExceptionEvent', () {
      final exceptions = <UnilitixEvent>[];
      final t = CrashTracker(
        onCrashEvent: crashes.add,
        onExceptionEvent: exceptions.add,
        breadcrumbs: [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      expect(t.handleAppHang(iosRecord()), isTrue);
      expect(crashes, isEmpty);
      expect(exceptions.single.type, EventTypes.anr);
    });

    test('a record that is not an ANR is ignored', () {
      expect(tracker.handleAppHang('{"type":"CRASH"}'), isFalse);
      expect(anrs, isEmpty);
    });

    test('start configures the watchdog, with capture off while denied',
        () async {
      await tracker.startAppHangDetection(timeoutMs: 2000, capture: false);
      await tracker.setAppHangCapture(true);
      expect(sdkCalls.map((c) => c.method),
          ['configureAppHang', 'configureAppHang']);
      expect(sdkCalls[0].arguments, {'timeoutMs': 2000, 'capture': false});
      expect(sdkCalls[1].arguments, {'timeoutMs': 2000, 'capture': true});
    });

    test('0 disables detection: nothing is sent to the plugin', () async {
      await tracker.startAppHangDetection(timeoutMs: 0, capture: true);
      await tracker.setAppHangCapture(false);
      expect(sdkCalls, isEmpty);
    });

    test('onAppHang from the plugin is reported and acknowledged', () async {
      await tracker.startAppHangDetection(timeoutMs: 2000, capture: true);
      expect(await pushHang(iosRecord()), isTrue);
      expect(anrs.single.id, hangId);
      // Dropped by the caps is still acknowledged: never delivered again.
      for (var i = 0; i < 3; i++) {
        expect(await pushHang(iosRecord()), isTrue);
      }
      expect(anrs, hasLength(3));
      // An unreadable record is acknowledged (it would never parse).
      expect(await pushHang('nope'), isTrue);
    });

    test('before start (or after uninstall) onAppHang is not handled',
        () async {
      Object? answer = 'unset';
      Future<void> push() =>
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
              .handlePlatformMessage(
            hangChannel,
            codec.encodeMethodCall(MethodCall('onAppHang', iosRecord())),
            (data) => answer = data,
          );
      await push();
      expect(answer, isNull, reason: 'no handler: the plugin keeps the file');
      await tracker.startAppHangDetection(timeoutMs: 2000, capture: true);
      tracker.uninstall();
      answer = 'unset';
      await push();
      expect(answer, isNull);
      expect(anrs, isEmpty);
    });
  });
}
