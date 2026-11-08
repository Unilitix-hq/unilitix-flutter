import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';
import 'package:unilitix/unilitix.dart';

import 'support/fake_native.dart';

/// Dart and Flutter errors are the one kind of crash only Dart can see. They
/// go to the native SDK's `recordExternalError` with platform `dart` and the
/// contract fingerprint; native crashes are the native SDK's.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const symbolized = '''
#0      CheckoutPage.pay (package:shop/checkout.dart:120:7)
#1      _InkResponseState.handleTap (package:flutter/src/material/ink_well.dart:1183:21)
#2      GestureRecognizer.invokeCallback (package:flutter/src/gestures/recognizer.dart:351:24)
#3      TapGestureRecognizer.handleTapUp (package:flutter/src/gestures/tap.dart:656:11)
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
  const jvmStack =
      'java.lang.IllegalStateException: cart empty\n\tat com.shop.cart.CartService.checkout(CartService.kt:42)\n\tat com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)\n\tat android.view.View.performClick(View.java:7448)\n\tat android.os.Handler.handleCallback(Handler.java:938)';

  group('CrashTracker', () {
    late List<DartErrorReport> reports;
    late CrashTracker tracker;
    FlutterExceptionHandler? savedFlutter;
    bool Function(Object, StackTrace)? savedPlatform;

    setUp(() {
      reports = [];
      tracker = CrashTracker(onReport: reports.add);
      savedFlutter = FlutterError.onError;
      savedPlatform = PlatformDispatcher.instance.onError;
    });

    tearDown(() {
      tracker.uninstall();
      FlutterError.onError = savedFlutter;
      PlatformDispatcher.instance.onError = savedPlatform;
    });

    test(
        'a framework error is a non-fatal EXCEPTION and still reaches the '
        'previous handler', () {
      final upstream = <FlutterErrorDetails>[];
      FlutterError.onError = upstream.add;
      tracker.install();
      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('layout'),
          stack: StackTrace.fromString(symbolized)));
      expect(upstream, hasLength(1));
      expect(reports.single.fatal, isFalse);
      expect(reports.single.type, 'StateError');
      expect(reports.single.message, 'Bad state: layout');
      expect(reports.single.stackTrace, symbolized);
      expect(reports.single.fingerprint,
          CrashTracker.contractFingerprint('StateError', symbolized));
    });

    test(
        'an uncaught error is a CRASH; the previous handler keeps its '
        'verdict', () {
      var upstreamCalls = 0;
      PlatformDispatcher.instance.onError = (e, st) {
        upstreamCalls++;
        return true;
      };
      tracker.install();
      final handled = PlatformDispatcher.instance.onError!(
          ArgumentError('boom'), StackTrace.fromString(symbolized));
      expect(handled, isTrue);
      expect(upstreamCalls, 1);
      expect(reports.single.fatal, isTrue);
      expect(reports.single.type, 'ArgumentError');
    });

    test('uninstall restores the previous handlers', () {
      void previous(FlutterErrorDetails d) {}
      FlutterError.onError = previous;
      tracker.install();
      expect(FlutterError.onError, isNot(same(previous)));
      tracker.uninstall();
      expect(FlutterError.onError, same(previous));
    });

    test(
        'a repeating framework error stops crossing the channel after '
        'maxReportsPerFingerprint, until the next session', () {
      FlutterError.onError = (_) {};
      tracker.install();
      for (var i = 0; i < 10; i++) {
        FlutterError.onError!(FlutterErrorDetails(
            exception: StateError('every frame'),
            stack: StackTrace.fromString(symbolized)));
      }
      expect(reports, hasLength(SdkContract.maxReportsPerFingerprint));
      tracker.resetSession();
      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('every frame'),
          stack: StackTrace.fromString(symbolized)));
      expect(reports, hasLength(SdkContract.maxReportsPerFingerprint + 1));
    });

    test('explicit captures are never filtered by the repeat guard', () {
      for (var i = 0; i < 5; i++) {
        tracker.capture(StateError('x'), StackTrace.fromString(symbolized));
      }
      expect(reports, hasLength(5), reason: 'the native caps apply');
    });

    test('errors thrown inside the SDK are not recorded as app crashes', () {
      FlutterError.onError = (_) {};
      tracker.install();
      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('sdk'),
          stack: StackTrace.fromString(
              '#0 Unilitix.track (package:unilitix/unilitix.dart:1:1)')));
      expect(reports, isEmpty);
    });

    test('an obfuscated trace carries its build ids', () {
      tracker.capture(StateError('x'), StackTrace.fromString(obfuscated));
      expect(reports.single.metadata, {
        'buildId': 'a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6',
        'isolateDsoBase': '7a1c200000',
      });
      expect(CrashTracker.symbolicationMetadata(symbolized), isEmpty);
    });

    test('fingerprints ignore line numbers and differ by type and frame', () {
      final a = CrashTracker.contractFingerprint('StateError', symbolized);
      expect(
          CrashTracker.contractFingerprint(
              'StateError', symbolized.replaceAll(':120:7', ':131:9')),
          a);
      expect(
          CrashTracker.contractFingerprint('RangeError', symbolized), isNot(a));
      expect(
          CrashTracker.contractFingerprint('StateError',
              symbolized.replaceFirst('CheckoutPage.pay', 'CartPage.add')),
          isNot(a));
    });
  });

  group('Unilitix error API', () {
    late FakeNative native;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      Unilitix.debugReset();
      native = FakeNative()..install();
      await Unilitix.init('k',
          config: const UnilitixConfig(
              apiKey: 'k', captureScreenshots: false, captureSnapshots: false));
      native.clear();
    });

    tearDown(() {
      Unilitix.debugReset();
      native.uninstall();
    });

    test('captureException sends recordError with platform dart', () {
      Unilitix.captureException(StateError('cart empty'),
          stackTrace: StackTrace.fromString(symbolized), fatal: true);
      expect(native.single('recordError'), {
        'type': 'StateError',
        'message': 'Bad state: cart empty',
        'stackTrace': symbolized,
        'fatal': true,
        'platform': 'dart',
        'fingerprint':
            CrashTracker.contractFingerprint('StateError', symbolized),
        'metadata': <String, Object?>{},
      });
    });

    test('captureException without a stack still reports', () {
      Unilitix.captureException(StateError('no stack given'));
      expect(native.named('recordError'), hasLength(1));
    });

    test('recordException groups a JVM stack like the native SDKs', () {
      Unilitix.recordException('java.lang.IllegalStateException', 'cart empty',
          stackTrace: jvmStack);
      final args = native.single('recordError');
      expect(args['fingerprint'], '76bec3cae7c2c295');
      expect(args['fatal'], isFalse);
      expect(args['platform'], 'dart');
    });

    test('init installs the hooks when autoTrackCrashes is on', () {
      expect(FlutterError.onError, isNotNull);
      FlutterError.onError!(FlutterErrorDetails(
          exception: StateError('build'),
          stack: StackTrace.fromString(symbolized)));
      expect(native.single('recordError')['fatal'], isFalse);
    });
  });
}
