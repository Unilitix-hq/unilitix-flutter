# SDK behaviour fixtures — runner contract

Cross-platform conformance cases for the Unilitix SDKs (contract **1.4.0**).
Each case drives an SDK through a fixed vocabulary of steps against a **fake
transport**, a **fake clock** and a **fake device**, and checks the HTTP
requests the SDK sent and the state it reports. Every SDK implements one
*runner* for this vocabulary; the cases are shared.

Source of truth: `internal/sdkcontract/behaviour/` in the api repo.
`go run ./cmd/sdkcontract` copies this folder to `api/sdk/behaviour/` and
writes a typed loader per language:

| SDK | Loader | Fixtures folder to copy |
|---|---|---|
| unilitix-android | `api/sdk/kotlin/BehaviourFixtures.kt` | `api/sdk/behaviour/` → `unilitix-sdk/src/test/resources/behaviour/` |
| unilitix_flutter | `api/sdk/dart/behaviour_fixtures.dart` | `api/sdk/behaviour/` → `test/behaviour/` |
| unilitix-react-native | `api/sdk/ts/behaviourFixtures.ts` | `api/sdk/behaviour/` → `src/__tests__/behaviour/` |
| unilitix-ios | `api/sdk/swift/BehaviourFixtures.swift` | `api/sdk/behaviour/` → `Tests/UnilitixCoreTests/Resources/behaviour/` |

Loaders read the files, apply harness defaults, filter by platform, split each
step into `(action, args)` and provide `decodeInput` and `substitute` (below).
Matching is the runner's job and is specified here. The reference runner —
a small Go model of a conforming SDK plus the matcher — is
`internal/sdkcontract/behaviour/reference_test.go`; every case passes on it.
When an SDK and a fixture disagree, the reference decides which is wrong.

## Files

- `index.json` — `contractVersion`, `files` (the case files, run in this
  order), and `harness` (defaults below).
- `<area>.json` — `{kind: "behaviour", area, description, cases: [...]}`.
  Areas: consent, crashes, identity, lifecycle, network, properties, queue,
  retry, screens, sessions.
- `behaviour.schema.json` — JSON Schema (2020-12) for both file kinds.
- `DIVERGENCES.md` — where released SDKs do not yet match; runners may skip
  exactly the case ids listed there for their platform, nothing else.

## A case

```json
{ "id": "consent.pending-holds-until-granted",
  "description": "…",
  "platforms": ["android", "ios", "flutter", "react-native"],   // optional; absent = all
  "contract": ["limits.preInitBufferSize"],                     // optional, informational
  "config": {"consent": "pending"},                             // optional overrides
  "clock": "2026-01-05T09:00:00.000Z",                          // optional, default harness.clock
  "device": {"network": {...}, "randomRolls": [0.25]},          // optional, per-field override
  "steps": [ {"init": {}}, {"track": {"name": "a"}}, … ] }
```

Run each case in a **fresh install**: empty disk (queue database, prefs,
keychain items the SDK owns, crash files), no SDK singleton, fresh fake
transport/clock/device. Steps run in order; each step is an object with
exactly one key, the action.

### Harness

`index.json` `harness`:

| Field | Meaning |
|---|---|
| `apiKey` | Key passed to `init` (`ul_test_behaviour`). |
| `apiUrl` | `apiUrl` option; the fake transport answers every request to this host. |
| `config` | Option values applied before the case's `config`: auto-capture off (screens, taps, crashes, rage taps), replay capture off, `flushIntervalSeconds` 3600 so uploads happen only on the triggers the case causes. |
| `device` | Default network (`wifi`, online) and `randomRolls` (`[]`). |
| `clock` | Default start time. |
| `defaultResponse` | `{"status": 202}` for every request unless `serverResponds` says otherwise. |
| `ignoredPaths` | Path prefixes never recorded (replay media, power signals). |

**Config** keys are the contract's canonical option keys
(`sdk-contract.json` `options[].key`); map them to the platform's name with
`options[].names` (e.g. `replaySampleRate` is `sampleRate` on Android). An
option a platform does not offer is a fixture bug — report it.

**Fake clock.** Wall clock starts at `clock`; the SDK's monotonic clock starts
anywhere and advances in step. Nothing advances except through `advanceTime`.
Timers (flush interval, backoff retries if the SDK schedules them) fire
during `advanceTime`, in due order, at their due time.

**Fake device.** Network state (`setNetwork`), app version `1.4.2`, build
`42`, and `randomRolls`: values returned, in order, for the per-session replay
sampling roll — and only for it (UUIDs, jitter and anything else use their
normal source). A session is sampled iff `roll < replaySampleRate`. A roll is
consumed at each session start when replay capture (`captureSnapshots` or
`captureScreenshots`) is on. When the list is exhausted, return 0.999.

**Fake transport.** Records every request (method, path, headers, body) and
answers synchronously: status from `serverResponds` or `defaultResponse`,
headers as given, and body `{"received": <events in the body>, "sessionId":
<body.sessionId>}` for session/events requests, `{"anonymousId": …,
"customUserId": …, "updated": true}` for identify, `{}` otherwise. Status
`0` means *no response*: fail the request as a connection error. While the
fake network is offline (`online: false`) every request fails as a
connection error **and is not recorded** (it never left the device).
A gzip body (`Content-Encoding: gzip`) is decoded before recording.

**Settling.** Before every `expect…` step and before `restart`, run the SDK
until idle: drain its executors/coroutines/isolates/dispatch queues, deliver
every in-flight request's response, and let anything the SDK does in
response run, without advancing the clock.

## Steps

Arguments marked *input* may contain generators (see Input values).

| Step | Args | What the runner does |
|---|---|---|
| `init` | `{}` | Call the SDK's init/start with `harness.apiKey` and the merged config. A second init in the same process is passed through (the SDK ignores it). |
| `track` | `name` *input*, `properties`? *input* | `track(name, properties)` (Android `trackEvent`). Before `init`: call it anyway — the SDK must buffer it. |
| `screen` | `name` *input* | Manual screen call (`screen`, `trackScreen`). |
| `identify` | `userId` *input*, `traits`? *input* | `identify(userId, traits)`. |
| `reset` | `{}` | `reset()`. |
| `setConsent` | `state`: granted \| pending \| denied | `setConsent(state)`. |
| `advanceTime` | `ms` | Advance the fake clock by `ms`, firing due timers. |
| `setNetwork` | `type`: wifi \| ethernet \| cellular \| none \| other; `generation`?: 2g \| 3g \| 4g \| 5g \| unknown; `online` | Change the fake device network and deliver the platform's change callback. See "Network" for platform mappings. |
| `background` / `foreground` | `{}` | Deliver the platform's app-lifecycle transition (Android ProcessLifecycleOwner ON_STOP/ON_START, iOS didEnterBackground/willEnterForeground, Flutter AppLifecycleState.paused/resumed, RN AppState). |
| `flush` | `{}` | App-called `flush()`. |
| `recordError` | `type`, `message`, `stack`?, `fatal`, `platform`? | Report a caught error through the SDK's public API with this type/message/stack (Android `recordException`, iOS `recordException(type:message:stackTrace:fatal:)`, Flutter `captureException` with a stack parsed from `stack`, RN `captureException` with an Error whose `name`, `message`, `stack` are set). `platform: "react-native"` means "raised in JS": React Native runners use the JS API; others ignore the field. |
| `crashNextLaunch` | `exceptionType`, `signal`?, `message`?, `stack`?, `platform`: android \| ios | Write the record the dying process would have written for a native crash (Android: the native handler's JSON record / tombstone, iOS: `CrashFile` signal record) so that the next launch reports it with exactly this `exceptionType`, `metadata.signal`, `exceptionMessage` and `stackTrace` (the frames, already in their printed form). Always followed by `restart`. |
| `restart` | `{}` | Process death and relaunch: drop every in-memory object of the SDK (singletons, timers, in-flight work), keep the disk. The fake transport (recordings and pending `serverResponds`), clock and device carry over. The SDK is not initialised until the next `init`. |
| `serverResponds` | `status`, `headers`?, `times`? | From now on, answer the next `times` recorded requests (all of them if absent) with this status and headers; then go back to `defaultResponse`. Replaces any earlier override. |
| `repeat` | `times`, `steps` | Run `steps` `times` times; in iteration *i* (from 0) replace `${i}` in every string of the steps (`substitute`). |
| `expectRequests` | list of request matchers | See Expectations. |
| `expectEvents` | `mode`: exact \| contains, `events`, `absent`? | See Expectations. |
| `expectState` | state matcher | See Expectations. |

### Input values

`decodeInput` turns these into native values before the SDK call:

- `{"$number": "NaN" | "Infinity" | "-Infinity"}` → that double.
- `{"$repeat": {"string": "a", "count": 1500}}` → `"aaa…"`.
- `{"$keys": {"count": 150, "prefix": "k", "value": 1}}` → map `k0…k149`, in that insertion order.
- `{"$list": {"count": 150, "value": 0}}` → list of 150 values.

Strings may contain any Unicode (e.g. a surrogate pair at the cut point).

## Expectations

### Normalised requests

Every `expectRequests` / `expectEvents` step consumes all requests recorded
since the previous `expectRequests` / `expectEvents` step (or the start of the
case). `expectState` consumes nothing. Before matching, the recorded requests
are normalised:

1. Drop requests whose path starts with an `ignoredPaths` entry and requests
   to any host other than `apiUrl` (presigned uploads).
2. Requests attempted while offline were never recorded (see Fake transport).
3. Keep `path` (no host, no query), the response `status` (0 = no response)
   and the JSON-decoded `body`.
4. `POST /v1/ingest/events` is renamed `/v1/ingest/session` (its body,
   `{sessionId, events}`, is a subset of a session body).
5. Split the list by path, keeping send order within each path. In the
   `/v1/ingest/session` list, merge **consecutive** records whose status is
   2xx and whose `body.sessionId` is equal: concatenate their `events`; for
   every other member the later record's value wins. Non-2xx records are
   never merged.

Ordering is asserted only between requests to the same path.

### `expectRequests`

A list of `{path, status?, body?}`. For every path that occurs in the
expected list **or** in the normalised requests, the normalised records for
that path must be exactly as many as the expected entries for that path, and
match them in order: `status` (if given) equal, `body` (if given) matching
the record's body. `[]` therefore asserts that nothing was sent.

### `expectEvents`

The *delivered events*: the `events` of every 2xx `/v1/ingest/session`
record, in order. `mode: "exact"` matches the whole list as an array
matcher. `mode: "contains"` finds each expected event, in order, among the
delivered events (a subsequence; other events may sit between). Every
matcher in `absent` must match **no** delivered event.

### `expectState`

The SDK's current state, read through a test hook (internal API is fine):

| Key | Value |
|---|---|
| `anonymousId` | Current anonymous id (string). |
| `sessionId` | Current session id, or `null` when there is none. |
| `userId` | Identified user id, or `null`. |
| `consent` | `granted` \| `pending` \| `denied`. |
| `queueLength` | Events stored on the device and not yet acknowledged by a 2xx (held under `pending` included; identify requests not counted). |
| `uploadsPaused` | `true` while uploads are latched off by a 401/403 (not for backoff or 402). |
| `replaySampled` | The current session's replay sampling decision (`false` when replay capture is off). |
| `screen` | Current screen name, or `null`. |

Each listed key's value must match the matcher.

### Matchers

A matcher is JSON compared with the actual JSON value:

- **Literal** string, number, boolean, `null`: equal (numbers numerically;
  `42` matches `42.0`).
- **Object** (no `$` keys): *partial* — every listed member must match; extra
  actual members are allowed.
- **Array**: same length, element-wise in order, after expanding `$each`.
- **Sentinel strings** (an expected string that starts with `<` and ends
  with `>`; any other such string is a fixture error):

  | Sentinel | Matches |
  |---|---|
  | `<any>` | member present, any value (null included) |
  | `<absent>` | member absent |
  | `<empty>` | member absent, `null` or `""` |
  | `<uuid>` | 8-4-4-4-12 hex string, any case |
  | `<timestamp>` | RFC 3339 string with offset |
  | `<fingerprint>` | 16 lowercase hex chars |
  | `<string>` `<number>` `<bool>` `<object>` `<array>` | value of that JSON type |

- **Operator objects** (every key starts with `$`; all listed operators must
  hold; a case keeps one table of captures for its whole run):

  | Operator | Matches |
  |---|---|
  | `{"$capture": "a1"}` | present; binds the actual value to `a1` (after the other operators passed) |
  | `{"$match": m}` | matches `m` (to combine with `$capture`/`$ne`) |
  | `{"$eq": "a1"}` | JSON-equal to the value captured as `a1` |
  | `{"$ne": "a1"}` | present and not equal to it |
  | `{"$size": n}` | array length or object member count is `n` |
  | `{"$length": n}` | string of `n` UTF-16 code units |
  | `{"$repeat": {"string", "count"}}` | equal to that generated string |
  | `{"$time": "2026-…Z"}` | RFC 3339 string denoting the same instant (millisecond precision; any offset) |
  | `{"$oneOf": [m1, m2]}` | matches at least one |
  | `{"$each": {"from": a, "to": b, "match": m}}` | only as an array element: stands for the elements `m` with `${i}` = a…b |

## Behaviour the fixtures pin (contract 1.4.0)

Beyond `sdk-contract.md`, the cases fix these rules; they are the contract:

- **Uploads.** Events go to `POST /v1/ingest/session` with `sessionId`,
  `anonymousId`, `customUserId` (when identified) and `events` (or to
  `/v1/ingest/events` after the session exists). Upload triggers: the flush
  interval, the queue reaching `flushBatchSize`, entering background, and
  `flush()`. Nothing is attempted offline, during a backoff window (app
  `flush()` included), while paused by 401/403, or unless consent is granted.
- **Event shape.** Every event has a client `eventId` (UUID, reused on retry),
  `seq` (0-based per session), `timestamp` (capture time, RFC 3339),
  `networkAtCapture`, `capturedOffline`. A session's first event is
  `SESSION_START`. `track` sends `CUSTOM` with `metadata.name` and the
  normalised `properties`; events carry the current `screen`.
- **Pre-init.** `track`/`screen`/`identify` (and other calls) before `init`
  are buffered (`preInitBufferSize`, oldest dropped) and replayed after the
  session starts, in order.
- **Identity.** `identify` sends `POST /v1/ingest/identify {anonymousId,
  customUserId, traits}` once (resent only if that request fails
  retryably); the user and anonymous ids persist across restarts. `reset`
  gives a new anonymous id, clears user and traits and starts a new session;
  events captured before it keep their session and ids.
- **Consent.** `pending` captures and holds everything (identify included);
  `granted` releases it; `denied` purges the queue and pending identifies
  and captures nothing. A `setConsent` decision persists and beats the
  `consent` passed to later inits.
- **Sessions.** Foreground after more than `sessionTimeoutSeconds` in the
  background starts a new session; the replay sampling decision is made once
  per session start. Events are captured whatever the sampling decision.
- **Queue.** At most `maxOfflineEvents` events on the device, oldest
  (including `SESSION_START`) dropped first, whatever the network state.
- **Screens.** `screen(name)` emits `NAVIGATE` only when `name` differs from
  the current screen of the session; a new session starts with no screen.
- **Errors.** `recordError` → `EXCEPTION` (`fatal: false`) or `CRASH`
  (`fatal: true`) with `exceptionType`, `exceptionMessage`, `stackTrace` and
  `metadata.fingerprint`; at most `maxReportsPerFingerprint` per fingerprint
  per session. A native crash is reported at the next launch as `CRASH`,
  `exceptionType: "SIGNAL"`, `metadata.signal`, the fingerprint of
  `SIGNAL:<n>` + first app frames (`sdk-contract.md` "Native crashes").

## Network

`setNetwork` gives a platform-neutral state; the runner fakes the platform
API so the SDK sees it, and the SDK maps it with `networkTypeRules`:

| `setNetwork` | Android fake | iOS fake | Flutter fake (connectivity) | Expected |
|---|---|---|---|---|
| wifi | TRANSPORT_WIFI | NWPath .wifi | `wifi` | `WIFI` |
| ethernet | TRANSPORT_ETHERNET | .wiredEthernet | `ethernet` | `ETHERNET` |
| cellular 5g | TRANSPORT_CELLULAR + NETWORK_TYPE_NR | .cellular + CTRadioAccessTechnologyNR | `mobile` + native 5G | `5G` |
| cellular 4g / 3g / 2g | NETWORK_TYPE_LTE / UMTS / EDGE | LTE / WCDMA / Edge | `mobile` + native type | `4G` / `3G` / `2G` |
| cellular unknown | NETWORK_TYPE_UNKNOWN or no READ_PHONE_STATE | no radio tech | `mobile` | `CELLULAR` |
| other | TRANSPORT_VPN / BLUETOOTH only | .other | `vpn` / `bluetooth` / `other` | `UNKNOWN` |
| none, or `online: false` | no active network / not VALIDATED | .unsatisfied | `none` | `OFFLINE` |
