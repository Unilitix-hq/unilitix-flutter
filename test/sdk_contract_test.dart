// Conformance with the shared SDK contract (api/sdk-contract.md in the api
// repo), mirrored here as lib/src/generated/sdk_contract.dart. Regenerate it
// with `go run ./cmd/sdkcontract` there and copy it over; never edit by hand.
//
// Keys listed in SdkContract.divergences are known gaps with a planned fix
// and are skipped; removing one from the contract turns its check back on.
//
// Since 3.0.0 most of the contract (retry, queue, sessions, identity, native
// crash grouping) is implemented by the native SDKs and tested there; this
// file checks what the Dart layer still owns: the option defaults, the
// consent states, and the fingerprint of Dart errors.
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/consent.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';

bool _skipped(String key) => SdkContract.divergences.contains(key);

/// The contract's vectors for the other platforms' stacks (JVM, JavaScript,
/// Apple, Android ANR main thread), from sdk-contract.md / fingerprint.go in
/// the api repo. [CrashTracker.contractFingerprint] must match these too, so
/// an error reported with `Unilitix.recordException` from another runtime
/// groups with the native SDKs' reports.
const _otherPlatformVectors = <(String, String, String?, String)>[
  (
    'jvm',
    'java.lang.IllegalStateException',
    'java.lang.IllegalStateException: cart empty\n\tat com.shop.cart.CartService.checkout(CartService.kt:42)\n\tat com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)\n\tat android.view.View.performClick(View.java:7448)\n\tat android.os.Handler.handleCallback(Handler.java:938)',
    '76bec3cae7c2c295',
  ),
  (
    'jvm native method',
    'java.lang.reflect.InvocationTargetException',
    '\tat java.lang.reflect.Method.invoke(Native Method)\n\tat com.a.B.c(B.java:1)',
    '8ca3b8f5c4b62b3e',
  ),
  (
    'hermes',
    'TypeError',
    'TypeError: undefined is not an object (evaluating \'cart.items\')\n    at checkout (address at index.android.bundle:1:234567)\n    at onPress (address at index.android.bundle:1:198765)\n    at anonymous (index.android.bundle:1:5)\n    at call (native)',
    'a3ad739a097ccbc5',
  ),
  (
    'js bare frame',
    'Error',
    'Error: boom\n    at index.android.bundle:1:2345\n    at foo (a.js:3:4)',
    'f7219531df83342a',
  ),
  (
    'apple symbolicated',
    'NSInvalidArgumentException',
    '0   CoreFoundation                      0x00000001804ab0f8 __exceptionPreprocess + 164\n1   libobjc.A.dylib                     0x0000000180051c94 objc_exception_throw + 56\n2   Shop                                0x00000001043a81c4 -[CartViewController pay:] + 52\n3   UIKitCore                           0x0000000184c1e2a0 -[UIApplication sendAction:to:from:forEvent:] + 96',
    'bd1e42f98a651ac8',
  ),
  (
    'apple symbolicated, other device',
    'NSInvalidArgumentException',
    '0   CoreFoundation 0x0000000191a2c0f8 __exceptionPreprocess + 164\n1   libobjc.A.dylib 0x0000000189b51c94 objc_exception_throw + 56\n2   Shop 0x0000000102e481c4 -[CartViewController pay:] + 52',
    'bd1e42f98a651ac8',
  ),
  (
    'apple unsymbolicated',
    'NSRangeException',
    '0   CoreFoundation                      0x00000001804ab0f8 __exceptionPreprocess + 164\n1   libobjc.A.dylib                     0x0000000180051c94 objc_exception_throw + 56\n2   Shop                                0x00000001043a81c4 Shop + 70084',
    'd45f6540033ea99b',
  ),
  (
    'android anr main thread',
    'ANR',
    '"main" prio=5 tid=1 Native\n  native: #00 pc 000000000009a1b8  /apex/com.android.runtime/lib64/bionic/libc.so (read+8)\n  native: #01 pc 0000000000012c34  /system/lib64/libsqlite.so (unixRead+52)\n  at android.database.sqlite.SQLiteConnection.nativeExecuteForCursorWindow(Native method)\n  at android.database.sqlite.SQLiteConnection.executeForCursorWindow(SQLiteConnection.java:1001)\n  - locked <0x0b1c2d3e> (a android.database.sqlite.SQLiteConnection)\n  at com.shop.cart.CartRepository.load(CartRepository.kt:88)\n  at com.shop.ui.CheckoutActivity.onPay(CheckoutActivity.kt:118)',
    'ff80a5189f547c4d',
  ),
  (
    'android anr main thread, other device',
    'ANR',
    '"main" prio=5 tid=1 Native\n  | group="main" sCount=1 ucsCount=0 flags=1 obj=0x72a1b2c8 self=0xb400007a1c2d3e40\n  | sysTid=9120 nice=-10 cgrp=top-app sched=0/0 handle=0x7b9e1f44f8\n  native: #00 pc 00000000000a0c44  /apex/com.android.runtime/lib64/bionic/libc.so (read+4)\n  at android.database.sqlite.SQLiteConnection.nativeExecuteForCursorWindow(Native method)\n  at android.database.sqlite.SQLiteConnection.executeForCursorWindow(SQLiteConnection.java:1012)\n  at com.shop.cart.CartRepository.load(CartRepository.kt:91)',
    'ff80a5189f547c4d',
  ),
];

/// Vectors of the native crash rule (1.4.0: `SIGNAL:<n>` + first app frames
/// of a tombstone or an Apple crash report). Native crashes are grouped by
/// the native SDKs since 3.0.0, so the Dart layer does not run them.
bool _nativeVector(String name, String? stack) =>
    stack != null &&
    (name.contains('tombstone') ||
        name.startsWith('apple signal') ||
        name == 'signal, unknown number');

void main() {
  group('SdkContract', () {
    test('the generated constants are contract 1.4.0', () {
      expect(SdkContract.version, '1.4.0');
    });

    test('every config default matches the contract', () {
      const c = UnilitixConfig(apiKey: 'k');
      final actual = <String, Object>{
        'apiUrl': c.apiUrl,
        'debug': c.debug,
        'autoTrackTaps': c.autoTrackTaps,
        'autoTrackCrashes': c.autoTrackCrashes,
        'autoTrackRageTaps': c.autoTrackRageTaps,
        'flushIntervalSeconds': c.flushIntervalSeconds,
        'flushBatchSize': c.flushBatchSize,
        'maxOfflineEvents': c.maxOfflineEvents,
        'sessionTimeoutSeconds': c.sessionTimeoutSeconds,
        'maskInputs': c.maskInputs,
        'maskAllText': c.maskAllText,
        'maskImages': c.maskImages,
        'maskScreenshots': c.maskScreenshots,
        'replaySampleRate': c.replaySampleRate,
        'captureSnapshots': c.captureSnapshots,
        'snapshotIntervalMs': c.snapshotIntervalMs,
        'maxSnapshotsPerSession': c.maxSnapshotsPerSession,
        'captureScreenshots': c.captureScreenshots,
        'screenshotIntervalMs': c.screenshotIntervalMs,
        'screenshotQuality': c.screenshotQuality,
        'screenshotMaxWidth': c.screenshotMaxWidth,
        'uploadScreenshotsOnWifiOnly': c.uploadScreenshotsOnWifiOnly,
        'maxScreenshotsPerSession': c.maxScreenshotsPerSession,
        'maxScreenshotsPerMinute': c.maxScreenshotsPerMinute,
        'screenshotHeartbeatMs': c.screenshotHeartbeatMs,
        'powerOutageContribution': c.powerOutageContribution,
        // init(consent:) defaults to granted.
        'consent': UnilitixConsent.granted.name,
      };
      for (final entry in SdkContract.defaults.entries) {
        if (_skipped(entry.key)) continue;
        expect(actual.containsKey(entry.key), isTrue,
            reason: 'contract option ${entry.key} has no UnilitixConfig field');
        expect(actual[entry.key], entry.value,
            reason: 'default for ${entry.key}');
      }
      expect(actual.keys.toSet(), SdkContract.defaults.keys.toSet(),
          reason: 'options the contract does not list');
    });

    test('consent states match', () {
      expect(UnilitixConsent.values.map((c) => c.name).toSet(),
          SdkContract.consentStates.toSet());
      expect(SdkContract.defaultConsent, UnilitixConsent.granted.name);
    });

    test('Dart errors: both rule sets match every Dart vector', () {
      final dart = SdkContract.fingerprintVectors
          .where((v) => !_nativeVector(v.$1, v.$3))
          .toList();
      expect(dart, isNotEmpty);
      for (final (name, type, stack, want) in dart) {
        expect(CrashTracker.fingerprint(type, stack), want, reason: name);
        expect(CrashTracker.contractFingerprint(type, stack), want,
            reason: name);
      }
    });

    test('contract fingerprint matches every other platform\'s vector', () {
      for (final (name, type, stack, want) in _otherPlatformVectors) {
        expect(CrashTracker.contractFingerprint(type, stack), want,
            reason: name);
      }
    });

    test('lines that are not frames are skipped', () {
      expect(CrashTracker.normaliseFrame('"main" prio=5 tid=1 Native'), isNull);
      expect(
          CrashTracker.normaliseFrame(
              '  - locked <0x0b1c2d3e> (a android.database.sqlite.SQLiteConnection)'),
          isNull);
      expect(CrashTracker.normaliseFrame('<asynchronous suspension>'), isNull);
    });
  });
}
