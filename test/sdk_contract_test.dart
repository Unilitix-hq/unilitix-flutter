// Conformance with the shared SDK contract (api/sdk-contract.md in the api
// repo), mirrored here as lib/src/generated/sdk_contract.dart. Regenerate it
// with `go run ./cmd/sdkcontract` there and copy it over; never edit by hand.
//
// Keys listed in SdkContract.divergences are known gaps with a planned fix
// and are skipped; removing one from the contract turns its check back on.
import 'package:flutter_test/flutter_test.dart';
import 'package:unilitix/src/config.dart';
import 'package:unilitix/src/crash/crash_tracker.dart';
import 'package:unilitix/src/events/event_types.dart';
import 'package:unilitix/src/generated/sdk_contract.dart';
import 'package:unilitix/src/network/retry_policy.dart';
import 'package:unilitix/src/privacy/opt_manager.dart';
import 'package:unilitix/src/storage/event_database.dart';

bool _skipped(String key) => SdkContract.divergences.contains(key);

void main() {
  group('SdkContract', () {
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

    test('event types are canonical', () {
      const sent = [
        EventTypes.tap,
        EventTypes.navigate,
        EventTypes.rageTap,
        EventTypes.crash,
        EventTypes.exception,
        EventTypes.custom,
        EventTypes.sessionStart,
        EventTypes.scroll,
      ];
      for (final t in sent) {
        expect(SdkContract.eventTypes, contains(t));
      }
    });

    test('consent states match', () {
      expect(UnilitixConsent.values.map((c) => c.name).toSet(),
          SdkContract.consentStates.toSet());
    });

    test('crash caps and retry policy come from the contract', () {
      final t = CrashTracker(
        onCrashEvent: (_) {},
        breadcrumbs: const [],
        database:
            EventDatabase(maxOfflineEvents: 1, maxScreenshotsPerSession: 1),
      );
      expect(t.maxPerFingerprint, SdkContract.maxReportsPerFingerprint);
      expect(t.maxPerSession, SdkContract.maxErrorReportsPerSession);
      expect(RetryPolicy.maxDelayMs, SdkContract.retryMaxDelayMs);
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 3600).inSeconds,
          SdkContract.retryAfterMaxSeconds);
      expect(RetryPolicy.delayFor(0, retryAfterSeconds: 0).inSeconds,
          SdkContract.retryAfterMinSeconds);
    });

    test('fingerprint matches every contract vector', () {
      expect(SdkContract.fingerprintVectors, isNotEmpty);
      for (final (name, type, stack, want) in SdkContract.fingerprintVectors) {
        expect(CrashTracker.fingerprint(type, stack), want, reason: name);
      }
    });
  });
}
