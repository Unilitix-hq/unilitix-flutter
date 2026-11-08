# Known divergences from the behaviour fixtures (contract 1.4.0)

Found by reading the SDK sources at their `base` commits (unilitix-android,
unilitix_flutter, unilitix-ios, unilitix-react-native) against the 1.4.0
rules; not yet confirmed by a runner. A runner may skip exactly the case ids
listed for its platform until the fix ships; delete the row with the fix.
"Source" is where the current behaviour lives.

The contract is the single source of truth: where SDKs disagreed, 1.4.0
picks one rule (noted as *chosen*) and the others diverge.

## All SDKs (new in 1.4.0)

| Rule | Cases | Notes |
|---|---|---|
| Native crash fingerprint = `SIGNAL:<n>` + first app frames | `crashes.native-*` | Every SDK sends the 1.3 value `Fingerprint("SIGNAL:<n>", "")` (Android `NativeCrash.fingerprint`, iOS/RN-iOS `CrashFile.fingerprint(of:)`, Flutter `NativeCrashRecord.fingerprint`). Port `internal/sdkcontract/native.go` and the `nativeSystemImages` / `nativeSystemPathPrefixes` lists; run the new `fingerprintVectors`. The API regroups old SDKs' crashes on ingest, so this is not urgent for dashboards. `crashes.native-*-system-only-falls-back` already pass. |
| `jsBundleId` / `release` / `dist` on JS errors | `crashes.react-native-js-error-metadata` | React Native only; not sent yet. |
| Network types `ETHERNET`, `5G`, `CELLULAR`, `UNKNOWN`, `OFFLINE` | `network.canonical-types` | 1.3 listed only WIFI/4G/3G/2G. See per-SDK rows. |

## unilitix-android

| Case(s) | Current behaviour | Source |
|---|---|---|
| `lifecycle.pre-init-calls-replayed-in-order`, `lifecycle.pre-init-buffer-cap` | Calls before `init` are dropped with a warning (`trackEvent`: "called before init()"; `identify`/`trackScreen` no-op on `instance == null`). | `Unilitix.kt` `trackEvent`, `identify`, `trackScreen` |
| `identity.*`, `consent.pending-holds-until-granted`, `properties.traits-normalised` | No `POST /v1/ingest/identify`: the user id rides on the session body (`userId` and `customUserId`) and traits go in `sessionData`. | `Unilitix.kt` session map (`"customUserId" to identity.userId`, `sessionData`) |
| `lifecycle.init-starts-session`, every `expectEvents` with `SESSION_START`, `retry.*` (eventId) | Events have no `eventId`/`seq`; `SESSION_START` is not in `eventToMap`'s known types (anything unknown becomes `CUSTOM` named after its type). | `Unilitix.kt` `eventToMap` |
| `properties.*` | `track` properties are flattened into `metadata` next to `name` (not `properties`); every event also gets `memory_usage_mb`/`cpu_usage_pct`/`frame_drops` props. No normalisation (NaN, depth, length, key caps). | `Unilitix.kt` `eventToMap`, `enrichEvent` |
| `sessions.replay-sampling-once-per-session` | `sampleRate` (= `replaySampleRate`) is rolled per `trackEvent` call and drops the event; the contract samples replay per session and always captures events. | `Unilitix.kt` `shouldSample` |
| `network.canonical-types` | Events: Ethernet → `WIFI` (`NetworkMonitor`); session `networkType`: `ETHERNET`/`UNKNOWN` → `OFFLINE`. *Chosen:* `ETHERNET` and `UNKNOWN` stay as such. | `context/NetworkInfo.kt`, `Unilitix.kt` session map |
| `retry.402-*` | 402 is a rejected 4xx: the batch is dropped. *Chosen (from Flutter 2.7.4):* keep and pause. | `network/RetryPolicy.kt` `ApiResult.failure` |
| `screens.consecutive-duplicates-dropped` | No dedupe: every `trackScreen` emits `NAVIGATE`. | `Unilitix.kt` `trackScreen` |
| `crashes.native-android-*` | See "All SDKs". | `capture/NativeCrash.kt` |

## unilitix_flutter

| Case(s) | Current behaviour | Source |
|---|---|---|
| `lifecycle.pre-init-*` | Calls before `init` are ignored (`_ready` returns false, asserts in debug). | `lib/unilitix.dart` `_ready` |
| `identity.reset-rotates-ids`, `identity.reset-does-not-relink-queued-events`, `screens.new-session-emits-again` | `reset()` resets identity only; the session continues. *Chosen (Android, iOS):* reset starts a new session. | `lib/unilitix.dart` `reset` |
| `retry.408-is-retryable` | 408 counts as a rejected 4xx and the batch is dropped (`retryable` is 429/5xx only). | `lib/src/network/api_client.dart`, `retry_policy.dart` |
| `retry.402-honours-retry-after` | 402 honours `Retry-After` unclamped; contract clamps to 1–3600 s. Default window 15 min matches. | `lib/src/flush/flush_scheduler.dart` |
| `network.canonical-types` | No `5G` (an NR type reads as `UNKNOWN` unless the native string contains CELLULAR/MOBILE); web/desktop polling reports `UNKNOWN`/`OFFLINE` (as the contract). | `lib/src/network/network_monitor.dart` `_parseNativeType` |
| `properties.*` | No property/trait normalisation (a NaN property fails JSON encoding of the whole batch). | `lib/src/events/event.dart` |
| `screens.consecutive-duplicates-dropped` | No dedupe in `_onScreenChange`. | `lib/unilitix.dart` |

## unilitix-ios (UnilitixCore; also embedded in unilitix-react-native/ios)

| Case(s) | Current behaviour | Source |
|---|---|---|
| `network.*` | `networkAtCapture` is never set on events and `capturedOffline` is not derived from reachability. | `Models.swift` (`networkAtCapture` unused), `Reachability.swift` (Wi-Fi flag only) |
| `retry.402-*` | 402 is `.rejected` (dropped). | `RetryPolicy.swift` `classify` |
| `retry.other-4xx-drops-batch` (409 only) | 409 is treated as accepted; observable result is the same (batch deleted, no backoff), so no case fails. | `RetryPolicy.swift` |
| `screens.consecutive-duplicates-dropped` | Only automatic screen events are deduped; a manual `screen()` with the current name emits again. | `Engine.swift` `screenView` |
| `properties.*` | No property/trait normalisation; non-finite doubles make `JSONSerialization` throw. | `Engine.swift` `track` |
| `crashes.native-apple-*` | See "All SDKs" (`CrashFile.fingerprint(of:)` deliberately leaves the backtrace out). | `CrashFile.swift` |

## unilitix-react-native

JS layer (`src/index.tsx`) plus unilitix-android (Android) and the embedded
UnilitixCore (iOS): the native rows above apply to RN on that platform.

| Case(s) | Current behaviour | Source |
|---|---|---|
| `properties.*` | JS `sanitizeProperties` already matches the rules (depth 5, 1024 chars, 100 keys, non-finite → null) and adds `"[Circular]"` for cycles (allowed: not covered by fixtures). Event names are cut with `str()` (1024). Conformant in JS; native normalisation still needed for calls that bypass JS. | `src/index.tsx` |
| `lifecycle.pre-init-*` | JS buffers 200 calls (`PRE_INIT_LIMIT = preInitBufferSize`): conformant. | `src/index.tsx` `whenReady` |
| `crashes.react-native-js-error-metadata` | `captureException` sends no `jsBundleId`/`release`/`dist`. | `src/index.tsx` `captureException` |

## Not yet verified

Consent (`consent.*`), session timeout (`sessions.*-background-*`), offline
queue cap (`queue.cap-drops-oldest`: Android and Flutter implement
`maxOfflineEvents`; whether `SESSION_START` is protected is unverified),
exponential backoff (`retry.backoff-grows-exponentially`) and identify
persistence look implemented in every SDK but have no runner yet.
