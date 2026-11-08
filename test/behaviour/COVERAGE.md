# Behaviour fixture coverage (contract 1.4.0, SDK 3.0.0)

The fixtures in this folder are copied verbatim from the api repo
(`api/sdk/behaviour/`; loader `test/behaviour_fixtures.dart` from
`api/sdk/dart/`). Since 3.0.0 the Flutter SDK is a thin wrapper over the
native SDKs, so each case is checked in two places:

| Where | Runner | What it asserts |
|---|---|---|
| **Dart layer** (this repo) | `test/behaviour_runner_test.dart` | Every case for `flutter`: each app call reaches the native SDK once, in order, with the exact arguments (fake plugin on `com.unilitix/sdk`); the pre-init buffer; `init` arguments (options by contract key, wrapper `flutter`/`kUnilitixSdkVersion`); `recordError` sent with platform `dart` and the fingerprint the case's events expect; `expectState` `consent` / `screen` against the Dart mirror. |
| **Android engine** | unilitix-android `BehaviourRunner` / `BehaviourFixturesTest` (`unilitix-sdk/src/test/java/io/unilitix/sdk/contract/`) | The case's requests, events and state end to end (`expectRequests`, `expectEvents`, `expectState`) with a fake transport, clock and device. |
| **iOS engine** | UnilitixCore `BehaviourTests` (`Tests/UnilitixCoreTests/`) | Same, for UnilitixCore. |

A Flutter app on Android runs the Android engine, on iOS UnilitixCore, so a
case passes for Flutter when the Dart-layer check here and both native
runners pass. Known native gaps are listed in `DIVERGENCES.md` (the 2.x
`unilitix_flutter` rows describe the deleted Dart engine and no longer apply
to 3.0.0; the native rows do).

## Per case

"Dart" = behaviour implemented in this repo and asserted here. "Pass-through"
= the Dart layer only forwards the calls (asserted here); the behaviour itself
is the native SDK's (asserted by the native runners). "Native" = no Dart call
at all besides `init`/`track`/`flush` forwarding.

| Case | Dart layer | Behaviour owner |
|---|---|---|
| `lifecycle.pre-init-calls-replayed-in-order` | **Dart**: buffered before the channel is ready, replayed in order after the native `init` | Dart buffer + native pre-init buffer |
| `lifecycle.pre-init-buffer-cap` | **Dart**: 205 calls → the newest 200 reach the native SDK | Dart buffer |
| `lifecycle.init-starts-session` | **Dart**: `init` arguments; consent mirror `granted` | Native (session) |
| `lifecycle.queue-survives-restart` | Pass-through across a process restart | Native (queue on disk) |
| `lifecycle.timestamps-follow-clock` | Pass-through | Native (clock) |
| `consent.pending-holds-until-granted` | **Dart**: `setConsent` pass-through; consent mirror `pending` → `granted` | Native (hold/release) |
| `consent.denied-purges-queue` | **Dart**: pass-through; consent mirror `denied` | Native (purge) |
| `consent.granted-to-denied-drops-unsent` | **Dart**: pass-through; consent mirror `denied` | Native |
| `consent.decision-persists-across-restart` | **Dart**: after restart the mirror takes the native (persisted) state, not `init`'s argument | Native (persistence) |
| `consent.denied-then-granted-captures-again` | Pass-through (init with `denied`) | Native |
| `crashes.exception-fingerprint` | **Dart**: `recordError` with platform `dart` and fingerprint `76bec3cae7c2c295` | Dart fingerprint, native event |
| `crashes.fatal-error-is-crash` | **Dart**: `fatal: true`, same fingerprint | Dart fingerprint, native event |
| `crashes.reports-per-fingerprint-capped` | **Dart**: all 4 explicit reports forwarded (Dart filters only automatic repeats) | Native cap (3) |
| `crashes.native-android-*` (3) | Pass-through (`init`, `track`, `flush`) | Native (NDK crash, next launch) |
| `crashes.native-apple-*` (3) | Pass-through | Native (signal crash, next launch) |
| `identity.identify-links-anonymous-id` | Pass-through of `identify` with traits | Native |
| `identity.identify-persists-across-restart` | Pass-through across restart | Native |
| `identity.reset-rotates-ids` | Pass-through of `reset` | Native |
| `identity.reset-does-not-relink-queued-events` | Pass-through | Native |
| `network.canonical-types` | Pass-through (`setNetwork` is native-only) | Native |
| `network.offline-capture` | Pass-through | Native |
| `properties.normalised` | **Dart**: properties reach the channel unchanged (NaN, ±Infinity, 1500-char strings, 150 keys, deep nesting) | Native normalisation |
| `properties.traits-normalised` | **Dart**: traits reach the channel unchanged | Native normalisation |
| `properties.names-truncated` | **Dart**: long event/screen/user names unchanged | Native truncation |
| `queue.cap-drops-oldest` | Pass-through | Native |
| `retry.*` (12) | Pass-through (`track`, `flush`; `serverResponds` is native-only) | Native |
| `screens.consecutive-duplicates-dropped` | **Dart**: every `screen` call forwarded; current screen `Home` | Native dedupe |
| `screens.new-session-emits-again` | Pass-through of `screen`, `reset` | Native |
| `sessions.*` (5) | Pass-through; `background`/`foreground` are native-only (the native SDK observes the app lifecycle itself) | Native (timeout, sampling) |

Not run for Flutter (platform filter): `crashes.react-native-js-error-metadata`,
`crashes.native-react-native-engine-frames-skipped`.

## Dart-only behaviour outside the fixtures

These have no fixture (they are Flutter-specific) and are covered by widget
and unit tests:

| Behaviour | Test |
|---|---|
| `FlutterError.onError` / `PlatformDispatcher.onError` capture and chaining | `test/error_capture_test.dart` |
| Dart fingerprint vs the contract vectors (Dart and other-platform stacks) | `test/sdk_contract_test.dart` |
| Screenshot masks, native draw, commit/discard hand-off | `test/replay_handoff_test.dart` |
| Wireframe snapshot → `addSnapshot` | `test/replay_handoff_test.dart` |
| Sliced wireframe walk (equivalence, abandon) and its time budget | `test/wireframe_walk_test.dart`, `test/wireframe_benchmark_test.dart` |
| Tap privacy (`UnilitixPrivate`), rage taps, route names | `test/replay_handoff_test.dart`, `test/tracking_test.dart`, `test/unilitix_api_test.dart` |
| Init re-entrancy, failed init, 2.x consent carry-over, replay gating | `test/unilitix_api_test.dart` |
| Power-outage contribution (Flutter-only feature) | `test/power_outage_test.dart` |
