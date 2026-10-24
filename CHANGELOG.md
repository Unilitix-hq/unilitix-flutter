## 2.5.0

No more double native crash reports in apps that also ship the Unilitix
Android SDK. No API or configuration changes.

### Fixed
- **Android, with the Unilitix Android SDK 1.8.0+ in the same app:** both
  captured native (NDK) crashes (two signal handlers on API 21–29, two
  readers of `ApplicationExitInfo` on API 30+), so one crash was reported
  twice. The plugin now looks for the SDK at runtime (`Class.forName`, no
  compile-time dependency) and asks `Unilitix.nativeCrashCaptureActive()`.
  When it is true the SDK alone reports native crashes, against its own
  session: the plugin installs no signal handler, and drops the exit
  records it reads (its watermark still moves, so nothing is reported late
  if the SDK is later removed).
  - SDK present but not initialized when the plugin attaches (an engine
    started in `Application.onCreate` before `Unilitix.init`): the plugin
    decides on the next main-looper turn.
  - Signal records already on disk (written while the plugin was capturing)
    are still reported.
  - Without the Android SDK, with one older than 1.8.0, or with its
    `autoTrackCrashes` off, the plugin captures native crashes as in 2.4.0.

### Not changed
- JVM uncaught exceptions and sessions are still recorded by both SDKs when
  an app ships both (each keeps its own sessions).
- Session replay: Flutter content is drawn by the Flutter engine into a
  `FlutterView` and masked by the Dart side; the Android SDK's Jetpack
  Compose masking (1.8.0) does not apply to it.

## 2.4.0

Native (NDK) crash capture on Android, on the implementation the Android SDK
shipped in 1.7.0 (vendored, as UnilitixCore is on iOS). A crash in C/C++
code — the Flutter engine, a plugin's native library, your own FFI code — is
reported on the next launch as a fatal `CRASH` against the session that was
running, as on iOS. On by default; no API or configuration changes.

### Added
- **Android 11+ (API 30+): no native code.** When Dart reads native crashes
  at startup, the plugin reads `ActivityManager.getHistoricalProcessExitReasons`
  and returns exits with `REASON_CRASH_NATIVE` newer than a watermark kept in
  the plugin's own preferences (`unilitix_flutter_native_crash`), at most 5
  per launch (the newest). The signal comes from the tombstone (API 31+),
  else the exit description, else it is unknown. JVM crashes (`REASON_CRASH`)
  are not taken from here: the plugin's uncaught-exception handler already
  records them, with their stack.
  - **First launch with 2.4.0:** the watermark is set to now and nothing is
    reported, so exits from before the upgrade never arrive as a flood of
    stale crashes. A native crash in that first process is reported on the
    launch after it.
- **Android 5.0–10 (API 21–29): `libunilitix-flutter-native.so`.** A C
  signal handler (SIGSEGV, SIGABRT, SIGBUS, SIGILL, SIGFPE, SIGTRAP), installed
  when the plugin attaches, writes one record with async-signal-safe calls
  only, then chains to the previous handler (debuggerd, Crashlytics,
  Sentry, …) so the process dies as before. Each process writes its own file
  in `files/unilitix_native_signals/`, so a crash before Dart has read an
  older record never overwrites it. Not loaded on API 30+.
- **Same record and grouping as every Unilitix SDK.**
  `{"platform":"android","exceptionType":"SIGNAL","signal":11,"timestamp":<ms>}`
  plus, as on iOS, the contract `fingerprint` (`SIGNAL:11` =
  `8f1fc15bfa06be00`; an unknown signal is keyed `SIGNAL`) and the message
  `Fatal signal 11 (SIGSEGV)`, so the event reads
  `SIGNAL: Fatal signal 11 (SIGSEGV)`, as from the Android SDK.
- **No double reports.** The JVM crash handler tells the signal handler the
  exception is handled, so a SIGABRT that follows it is not recorded again.
  Every record is read and deleted (or passed by the watermark) once.

### Changed
- `readNativeCrash` returns one record per call, oldest first, and null when
  there are no more; the Dart side now reads until null (at most 8 per
  launch) and attributes each crash to its own session. iOS still returns at
  most one record per launch.
- **Consent denied:** native crash records (Android and iOS) are now read and
  dropped at startup. 2.3.x left them on the device, so a crash from a
  denied period could be reported after a later grant. Pending consent still
  holds them on the device like other events.

### Size and build
- The plugin now builds a few KB of plain C per ABI (no libc++, no liblog,
  `-Os`, stripped, 16 KB page aligned) with CMake and the NDK of the app's
  build: AGP's default NDK, which is `flutter.ndkVersion` on current
  Flutter/AGP pairs (no pin of the plugin's own). Apps that already build
  without an NDK installed get one downloaded by AGP on the first build.
- The library and its JNI class are distinct from the Android SDK's
  (`libunilitix-native.so`, `io.unilitix.sdk.capture`), so an app can include
  both.
- `consumer-rules.pro` keeps the JNI methods of
  `io.unilitix.flutter.nativecrash.NativeSignalHandler` under R8.

### How to test
- Debuggable build on a device or emulator: start the app, then
  `adb shell run-as <package> kill -SEGV $(adb shell pidof <package>)`,
  and relaunch. Expect one `CRASH` `SIGNAL: Fatal signal 11 (SIGSEGV)`
  with fingerprint `8f1fc15bfa06be00` on the session that was running. On
  Android 11+ the first launch with 2.4.0 only sets the watermark: crash
  the launch after it.

### Internal
- The C handler and the Android SDK's pure-Kotlin capture code are vendored
  into `android/src/main/cpp` and `android/src/main/kotlin/io/unilitix/flutter/nativecrash`
  by `scripts/sync-android-native.sh` (see CONTRIBUTING); the plugin-owned
  glue is `NativeCrashBridge.kt`.

## 2.3.0

iOS native code moves onto UnilitixCore 0.4.1, the Swift core of the native
iOS and React Native SDKs, so the three SDKs share one crash-capture
implementation and crash-file format and one screenshot path on iOS. No API
changes; Android is unchanged.

### Changed
- **iOS crash capture is UnilitixCore's `CrashFile`.** Uncaught
  `NSException`s and fatal signals are recorded as before (same file,
  `Application Support/unilitix_native_crash.json`, same JSON record, which
  is also the Android plugin's format) and reported on the next launch.
  `readNativeCrash` now adds the record's `fingerprint`, computed with the
  SDK contract's frame rules, so an Objective-C exception groups by its
  Apple stack frames, as the native iOS SDK groups it (2.2.x grouped iOS
  exceptions by type only). Signal crashes keep their grouping. Android
  records are fingerprinted in Dart as before.
- **iOS screenshots are drawn and encoded by UnilitixCore**
  (`ScreenshotCapture.render` / `encode`). The masks from Dart are painted
  while the frame is drawn, so no unmasked image is kept in memory (2.2.x
  drew the window unmasked and painted the masks afterwards), each mask is
  grown by one point on every side (was one output pixel), and frames are
  drawn at up to `screenshotMaxWidth` pixels wide, as on Android and native
  iOS (2.2.x drew them at one pixel per point, e.g. 390 px on a 390-point
  phone). Frames are taken from the key window of the foreground-active
  scene and are skipped while that is a system window. Still JPEG, and the
  `captureScreenshot` channel contract is unchanged.
- Device and app fields (`getDeviceInfo`, `getPackageInfo`) come from
  UnilitixCore's `DeviceInfo`; the values are unchanged.
- The privacy manifest declares `NSPrivacyAccessedAPICategorySystemBootTime`
  (`35F9.1`), which the vendored UnilitixCore sources use to time captures.

### Fixed
- **iOS:** an uncaught `NSException` is reported with its name, reason and
  stack. In 2.2.x the `SIGABRT` that follows it could overwrite the record,
  and the crash was reported as `SIGNAL` 6.

### Internal
- UnilitixCore's Swift sources are vendored into `ios/Classes/UnilitixCore`
  by `scripts/sync-ios-core.sh` (as in the React Native SDK); the
  `Unilitix.swift` facade is left out. Minimum iOS stays 13.0
  (UnilitixCore's minimum too).

## 2.2.1

### Fixed
- **Replay frames carry their real image type.** Native capture produces
  JPEG and the Dart fallback (web, desktop, Android < 26) produces PNG, but
  every frame was uploaded labelled `image/webp` and stored as `.webp`. Each
  upload now sends the type detected from the frame's bytes, and frames are
  reserved in one `/v1/ingest/screenshots/init` call per format with the new
  `format` field, so the API stores them as `.jpg` / `.png`. Older APIs
  ignore the field. No app changes needed.

## 2.2.0

Power outage contribution (opt-in). No breaking changes; apps that do not
opt in collect nothing new.

### Added
- **`UnilitixConfig.powerOutageContribution`** (default `false`). Reports
  plug/unplug transitions and charging samples to `POST /v1/signals/power`
  for the crowd-sourced outage map. Double opt-in: the flag, plus coarse
  location permission that the app declares and requests itself (the SDK
  never prompts), and consent `granted` (nothing is collected or held while
  `pending`/`denied`; leaving `granted` deletes the queue).
- Each request carries an **H3 resolution-7 cell** computed on the device
  (pure-Dart and pure-Java ports of H3's `latLngToCell`; coordinates never
  leave the device) and a **daily-rotating salted device hash** (the raw
  install id is never sent with these events). At most 200 events per
  request; events older than 48 h are dropped; at most 500 kept on device.
- **Android:** a manifest receiver for `ACTION_POWER_CONNECTED` /
  `ACTION_POWER_DISCONNECTED`, disabled by default and enabled only on opt-in,
  appends to a file in the no-backup directory; a runtime-registered receiver
  covers the same events while the app process is alive. A WorkManager job
  (15 min, network required) records a sample and uploads; the SDK also
  uploads on every foreground. Location comes from
  `LocationManager.getLastKnownLocation` (no Play services).
- **iOS:** samples at foreground and background, plug changes while in the
  foreground (`UIDevice.batteryStateDidChangeNotification`), uploaded on
  foreground. Location from `CLLocationManager().location`, only with
  existing when-in-use/always authorization.
- `ApiClient.postPowerSignals`.
- Tests: `test/power_outage_test.dart` (H3 vectors from the reference
  library, SHA-256 and device-hash vectors, queue cap/dedupe/48 h/200-batch
  rules, wire format, consent gating) and JVM unit tests for the Android
  implementation (`android/src/test/java/.../PowerH3Test.java`,
  `PowerSignalsTest.java`).

### Changed
- Android: the plugin now depends on `androidx.work:work-runtime:2.9.1`.
- iOS: the pod links `CoreLocation`. `PrivacyInfo.xcprivacy` declares coarse
  location (not linked, not tracking, app functionality), collected only when
  the feature is enabled.

## 2.1.4

Conforms to the shared SDK contract (v1.0.0). No breaking changes.

### Changed
- **Navigation events are sent as `NAVIGATE`**, the name the Android and
  React Native SDKs use. Earlier versions sent `NAV`, which the dashboard did
  not count in screen visits, journeys or the session timeline; the API now
  rewrites `NAV` on ingest, so older app builds are covered too.
- Defaults and limits (crash caps, breadcrumb trail, rage-tap thresholds,
  retry backoff, request timeout) now come from the generated
  `lib/src/generated/sdk_contract.dart`. Values are unchanged.

### Added
- `test/sdk_contract_test.dart`: config defaults, event types, consent
  states, crash and retry limits, and the crash fingerprint test vectors are
  checked against the contract.

## 2.1.3

- **Fixed:** the iOS plugin failed to compile in 2.1.2 (`ss_size` is
  `size_t`). 2.1.2 is retracted; use 2.1.3 or later.
- Publishing now waits for the Android and iOS example builds to pass.

## 2.1.2

Crash credibility release. No breaking changes.

### Fixed
- **Native crashes are attributed to the session that crashed**, not to the
  session that starts on the next launch, so a crash and its replay stay
  together. The marker written by the plugin carries the time of death; the
  SDK matches it to the pending session stub.
- **Sessions that did not end cleanly are recovered regardless of age.** A
  crash the device only reports a week later (offline, app unused) was
  discarded as stale.
- **`PlatformDispatcher.onError` is chained.** A handler the app or another
  SDK installed first still runs and still decides whether the error is
  handled; previously the SDK replaced it.
- **iOS signal handlers use `sigaction` on an alternate stack
  (`sigaltstack`)** and chain to the previously installed handler
  (Crashlytics, Sentry, the app's own) instead of replacing it, so two crash
  reporters can coexist; a stack-overflow `SIGSEGV` is now recorded. The
  signal record carries the time of death.

### Added
- **Fingerprints.** Every crash and exception carries a stable grouping key
  in `metadata.fingerprint` (exception type + the top three frames with line
  and column numbers removed; `virt` offsets for obfuscated traces), with
  `metadata.occurrence` counting repeats. The same fingerprint is reported at
  most 3 times per session and reports are capped at 50 per session, so an
  error thrown every frame no longer floods the queue.
- `metadata.buildId` and `metadata.isolateDsoBase` on reports from
  `--split-debug-info` builds, and `dart run unilitix:unilitix_symbols
  upload <dir>` to upload the symbol files. Server-side symbolication lands
  with the API release that adds `POST /v1/symbols`; until then the tool
  reports the endpoint as unavailable and exits non-zero.
- `Unilitix.captureException(error, stackTrace:, fatal:)` and
  `Unilitix.addBreadcrumb(message, category:, data:)`.

## 2.1.1

Reliability and size release. No API changes; two behaviour changes worth
reading before upgrading (marked **Changed**).

### Fixed
- **Retries no longer pile up.** Every request is now made once per flush
  cycle. A transient failure (no response, 5xx, 429) opens a backoff window —
  exponential with jitter, or exactly what `Retry-After` asks for — during
  which no request is made and data waits in the on-device queue. Previously
  each call retried up to five times inside the HTTP layer, so a degraded
  link could hold a flush open for minutes and multiply load on the API.
- **Permanent rejections are dropped.** A 4xx other than 429/401/403 means
  the payload can never succeed; the batch is discarded (and logged) instead
  of being re-sent every cycle for seven days.
- **A 400 on the session record no longer resets the session.** The record
  is kept, not re-sent until it changes, and the reason is logged. The reset
  split one visit into many and detached the events already attributed to it.
- `HttpException`, `HandshakeException`, "Connection closed before full
  header" and other `IOException`s thrown by the HTTP stack were not caught
  by the client and could reach the host app; every transport failure is now
  a result the scheduler handles.
- A queued batch with corrupt JSON is deleted on first sight instead of
  throwing on every retry.
- **SDK errors are never recorded as crashes.** Every public entry point and
  framework callback is guarded, and the crash tracker ignores errors whose
  stack originates inside `package:unilitix`.
- `foregroundTimeMs` is measured with a monotonic `Stopwatch`; a clock change
  mid-session used to add or subtract hours.
- `timezone` is the IANA zone id (`Africa/Lagos`) on Android and iOS rather
  than an ambiguous abbreviation.

### Changed
- **`track()` no longer sends an immediate request.** Custom events ride the
  normal batch (every `flushIntervalSeconds`, or sooner once `flushBatchSize`
  is reached). An app that tracked in a loop used to make one POST per call.
  Call `Unilitix.flush()` when an event must leave the device now.
- **The session record is upserted only when it changes** (or every five
  minutes so durations stay current), not every 30 s for the life of the
  session.
- **Dependencies cut from eight to three.** `device_info_plus`,
  `package_info_plus`, `flutter_secure_storage`, `crypto` and `image` are
  gone; device and app fields come from the SDK's own plugin, ids live in
  `shared_preferences`, and the Dart screenshot fallback (web, desktop,
  Android < 26) encodes PNG through `dart:ui`. Installs upgrading from
  ≤ 2.1.0 receive a fresh anonymous id once (the old one was in the
  Keychain/Keystore); the user id is restored by the app's next `identify()`.
- The retry queue is bounded by events (`maxOfflineEvents`, now counted in
  events rather than batches), by bytes (5 MB) and by age (7 days); oldest
  batches are evicted first.
- Write-ahead rows are written in batches (100 ms window) instead of one
  disk write per event.

### Added
- CI publishes an SDK size report (release arm64 APK of the example app) in
  the job summary.
- Storage and scheduler tests run against real SQLite (`sqflite_common_ffi`)
  and a `MockClient`; 20+ new tests cover backoff, drops, queue caps and WAL
  coalescing.

## 2.1.0

Privacy release. Upgrade before enabling session replay in any app that shows
personal or financial data.

### Fixed
- **Text inputs were not masked in pixel screenshots.** `maskInputs` only
  affected wireframe snapshots; a `TextField` without `obscureText` was
  uploaded legibly. Inputs are now painted over in screenshots too.
- **Opt-out was not honoured everywhere.** A session stub (device fields and
  user id) was written at session start and uploaded on the next launch even
  when the user had opted out; crash events bypassed the opt-out gate. Every
  persistence and upload path is now gated, and a denied consent purges what
  a previous process left behind.
- `autoTrackTaps` did nothing unless the app also wrapped its tree in the
  undocumented `UnilitixGestureDetector`. `UnilitixWidget` now records taps
  itself through a pointer listener that never competes with app gestures.
- Calling any API before `init()` in a release build threw a
  `LateInitializationError`; it is now logged and ignored.
- The connectivity fallback polled `https://1.1.1.1` every 30 s on mobile when
  the native channel errored, leaking timers; mobile now reports `UNKNOWN`
  instead, web/desktop probe the Unilitix API, and timers never stack.
- Session payloads sent `-1.0` for unknown battery/storage and `''` for an
  unknown carrier; these fields are now omitted.
- User traits were re-sent on every session upsert; they travel once, via
  `/identify`.
- `ios/unilitix.podspec` was stuck at 2.0.73; it now tracks the package
  version and CI fails if it drifts.
- `PrivacyInfo.xcprivacy` was empty; it now declares what the SDK collects.

### Added
- `maskAllText` now also paints over every text widget in pixel screenshots,
  and `UnilitixUnmasked` exempts a subtree (never inputs or `UnilitixPrivate`).
- `UnilitixConsent { pending, granted, denied }`, `init(consent:)`,
  `Unilitix.setConsent()` and `Unilitix.consent`. `pending` collects to the
  on-device queue and uploads nothing until granted; `denied` purges.
- `replaySampleRate` (default 1.0, decided once per session).
- README section "What the SDK collects by default".

### Changed
- `optOut()` / `optIn()` are now aliases of `setConsent(denied/granted)`.
- `UnilitixGestureDetector` becomes a passthrough when `UnilitixWidget` is
  mounted, so a tap is never counted twice.

## 2.0.76

### Fixed
- A rejected API key (HTTP 401/403) no longer retries forever. The SDK used to
  treat it like a network blip and re-send the session on every flush cycle
  and every launch; it now logs one clear error, pauses uploads for the rest
  of the process, and keeps captured data on-device for a later launch with a
  valid key.

## 2.0.75

### Fixed
- **iOS: the plugin did not compile** (since 2.0.50). `UnilitixFlutterPlugin.swift`
  referenced two CoreTelephony symbols that do not exist
  (`CTTelephonyNetworkInfo.serviceOrder`, `CTRadioAccessTechnologyHSPA`), so any
  app building for iOS failed with a Swift compiler error. Carrier lookup now uses
  `dataServiceIdentifier` (the SIM carrying data) with a fallback to any SIM, and
  the 3G radio set is HSDPA/HSUPA/WCDMA/EVDO/eHRPD.
- CI now compiles the iOS plugin on macOS (`ios-build` job) so this cannot
  regress silently; the publish workflow is unchanged.

## 2.0.74

### Durability
- Every event carries a client-generated UUID (`eventId`) and a per-session
  sequence number (`seq`). Retried batches are de-duplicated by the server and
  never billed twice.
- Events are written to an on-device write-ahead queue the moment they are
  emitted, before any network call, and recovered on the next launch.
- Uploads are serialised — one in-flight request at a time — so a slow network
  no longer stacks up parallel retries.
- A crash event is flushed synchronously before the process exits.
- Session timeout uses wall-clock time, so a device sleeping through the
  timeout starts a fresh session on resume.

### Privacy
- `maskAllText` (default **on**): the content of every `Text` widget is
  redacted in wireframe snapshots, preserving length for layout fidelity.
- `UnilitixPrivate` now also masks **pixel screenshots**: the subtree's bounds
  are painted over on the device before the frame is encoded
  (`maskScreenshots`, default on).
- `maskImages` (default off) blacks out `Image`, `RawImage`, `CircleAvatar`
  and `FadeInImage` in screenshots and snapshots.
- The anonymous id is a random UUID, never derived from device identifiers,
  and `reset()` rotates it.
- `optOut()` stops replay capture, discards buffered data, purges the
  on-device queue and gates every upload path.

### Performance
- Screenshots are encoded natively off the main thread (Android and iOS) and
  captured on change or navigation rather than on a fixed timer, with
  `maxScreenshotsPerMinute` (20) and `screenshotHeartbeatMs` (10 s) as the
  new tuning knobs.

### Crash reporting
- Native uncaught-exception handlers on Android (`Thread` default handler) and
  iOS (signal handlers) record a fatal `CRASH` on the next launch.
- Caught Flutter errors are reported as non-fatal `EXCEPTION` events; crash
  events now carry `fatal` and `title` so the dashboard groups them correctly.

### Contract
- `lib/src/generated/ingest_models.dart` is generated from the API's OpenAPI
  contract; `test/contract_test.dart` fails if the SDK ever sends a field the
  server does not declare.
- Fixed: screenshot confirmation now sends screen name, viewport, byte size
  and capture time, so replay frames are labelled (previously only the
  ordinal was sent and the server ignored it).

### Example app
- iOS deployment target raised to 13.0.

## 2.0.73

- fix: screenshot uploads now processed in batches of 3 instead of all at once — fixes connection saturation causing request timeouts and white frames in session replay on heavy sessions

## 2.0.72

- fix: persist session end payload to SQLite before network call — recovers incomplete sessions on next launch
- fix: remove dead SESSION_END constant

## 2.0.71

### Fixed
- `_recordCrash` now has a re-entrancy guard (`_isRecording`) — prevents
  recursive crash recording if an error fires during crash event handling
- Removed dead `recordZoneError` method — unreachable since `runZonedGuarded`
  was removed from `Unilitix.runApp` in v2.0.67
- `SnapshotCapture` now implements `WidgetsBindingObserver` and tracks `_active`
  state — timer callbacks are suppressed while the app is backgrounded, preventing
  accumulated `addPostFrameCallback` registrations that would fire in a burst on resume
- Navigator observer `_name()` fallback now maps common unnamed route types to
  clean names (`_DialogRoute` → `Dialog`, `_ModalBottomSheetRoute` → `BottomSheet`,
  `_PopupMenuRoute` → `PopupMenu`) instead of raw runtime type strings

### Changed
- `UnilitixPrivate` doc comment updated to clarify it only masks wireframe
  snapshot JSON, not pixel screenshots — use `captureScreenshots: false` in
  `UnilitixConfig` to prevent sensitive content in pixel screenshots
- Network connectivity polling URL changed from Google `generate_204` to
  Cloudflare `1.1.1.1/cdn-cgi/trace` — better availability in African markets
  where the Google endpoint may be blocked by some ISPs
- `memoryUsageMb` documented as RSS (resident set size), not Dart heap —
  on iOS this metric may read higher than heap-only tools
- Anonymous ID no longer includes `buildNumber` in its hash input — previously
  every app update generated a new anon ID, breaking user continuity across
  versions; now stable across builds on the same device
- fix: anonymous ID now stable across app updates (sha256 of deviceId + packageName only)
  Note: existing users will receive a new anonymous ID on first launch after upgrading to
  v2.0.71 — this is a one-time break; continuity holds for all future updates.

## 2.0.70

### Changed
- Renamed iOS podspec from `unilitix_flutter.podspec` to `unilitix.podspec`
- Updated podspec `s.name` from `unilitix_flutter` to `unilitix` — module name
  now matches the Dart package name
- Renamed privacy resource bundle from `unilitix_flutter_privacy` to
  `unilitix_privacy` for consistency

## 2.0.69

### Fixed
- **Periodic flush now runs all 4 stages** — previously only flushed events
  and retried pending DB records; screenshots and snapshots were deferred to
  session end only. Every 30s cycle now also uploads pending screenshots and
  snapshots (best-effort, background)
- **HTTP 409 on session upsert no longer resets the session** — 409 means the
  session already exists on the server; treated as success so events are
  flushed under the correct session ID instead of being re-attributed to a
  new session
- **Events restored to buffer on DB queue failure** — if `_queueEventsForRetry`
  fails to insert into SQLite, drained events are put back in the in-memory
  buffer instead of being silently dropped
- **`firstWhere` → safe `where + isEmpty` guard in screenshot upload** —
  eliminates `StateError` when the server omits a presigned slot for an
  ordinal; affected ordinal is skipped and retried next cycle
- **Session ID priority corrected in `_flushSnapshots` and
  `_uploadScreenshots`** — was `lastEndedSession ?? currentSession`; changed
  to `currentSession ?? lastEndedSession` so media captured during an active
  session uploads on periodic flush, not only after session end
- **`flushOnSessionEnd` no longer bails if a periodic flush is in progress** —
  polls up to 3 seconds for the flush to complete before proceeding, ensuring
  session-end data is always uploaded
- **`deletePendingSession` moved inside `flushOnSessionEnd`** — stub is only
  deleted after the flush succeeds, not before
- **Observer warning deferred to `addPostFrameCallback`** — removed
  unconditional `⚠️ not connected` line from the init banner; check now fires
  after the first frame when `MaterialApp` is fully built, eliminating the
  false-positive warning when `Unilitix.observer` is correctly wired
- **NDK version pinned in example app** — `example/android/app/build.gradle.kts`
  now specifies `ndkVersion = "27.0.12077973"` to silence plugin NDK mismatch
  warnings

## 2.0.68

### Fixed
- Screenshots not appearing in session replay — Content-Type
  mismatch on R2 presigned PUT (`image/jpeg` sent, `image/webp` expected)
  caused R2 to silently reject every screenshot upload
- `confirmScreenshotUpload` fired even when PUT to R2 failed —
  screenshots marked as uploaded when they weren't
- Screenshots deleted from local DB after failed upload causing
  permanent data loss — now only deleted after confirmed success
- Silent upload failures now logged for observability

## 2.0.67

### Fixed
- `Unilitix.runApp()` called itself recursively instead of Flutter's
  `runApp()` — would have caused a stack overflow on every app launch
- `onCrashEvent` `flush()` call created a recursive loop when a network
  error occurred during crash reporting
- Corrected `PixelCopy` import from `android.graphics` to `android.view`

## 2.0.66
### Fixed
- **Android black frames on Impeller/Vulkan** — four-part fix:
  1. `screenshot_capture.dart`: replaced `Timer.periodic` with `SchedulerBinding.addPostFrameCallback` — captures are now frame-synchronised and stop automatically when the app backgrounds
  2. `screenshot_capture.dart`: `toImage(pixelRatio: 1.0)` → `(devicePixelRatio * 0.5).clamp(1.0, 2.0)` — avoids Impeller allocating an oversized DEVICE_LOCAL texture
  3. `screenshot_capture.dart`: added `await SchedulerBinding.instance.endOfFrame` between `toImage()` and `toByteData()` — flushes Impeller's Vulkan command buffer before CPU pixel readback
  4. `UnilitixPlugin.kt`: added native `captureScreenshot` via `PixelCopy.request()` (API 26+) on a new `unilitix/screenshot` channel — reads from the window compositor, immune to Impeller; Dart `RepaintBoundary` path retained as fallback
- `android/build.gradle`: `compileSdk 34` → `compileSdk 35` for Android 16 (API 36) compatibility
- `UnilitixPlugin.kt`: implements `ActivityAware` to supply `Activity.window` to `PixelCopy`
- `ScreenshotCapture`: added `WidgetsBindingObserver` — re-anchors post-frame callback chain after app returns from background (prevents capture stoppage within a long session)

## 2.0.65
### Fixed
- `_recoverPendingSessions` now catches `FormatException` and `TypeError` separately — corrupt or malformed session records are deleted immediately instead of failing silently on every app start; generic catch retained for transient network errors

## 2.0.64
### Changed
- `_recoverPendingSessions` now checks for unsent events before discarding stale sessions — sessions older than 30 minutes are only discarded if they have no pending events in the DB; sessions with unsent events are always recovered regardless of age
- Added `EventDatabase.hasPendingEventsForSession()` — queries `pending_events` by `sessionId` in `session_json` using a `LIKE` match

## 2.0.63
### Changed
- `SnapshotCapture` rewritten with allowlist approach — only ~60 known renderable widget types serialized; framework/wrapper nodes traversed transparently (UXCam-style view pruning)
- Zero-size nodes skipped (`w == 0 || h == 0`)
- `Text.data` and `Text.textSpan` content extracted into `text` field
- `Icon.codePoint` extracted into `icon` field (hex string)
- Button widgets (`ElevatedButton`, `TextButton`, `OutlinedButton`) annotated with `role: button`
- `Image` nodes annotated with `role: image`
- Input masking now driven by `_kInputTypes` set, consistent with allowlist

## 2.0.62
### Changed
- `FlushScheduler` now uses a strict 4-stage sequential flush via `_flushAll()`: Stage 1 (session POST) → Stage 2 (events) → Stages 3 & 4 (snapshots + screenshots in parallel, best-effort)
- All four flush methods now return `bool` — stages 3 and 4 only run if stages 1 and 2 both succeed
- Screenshot upload removed from inside `_flushEvents`; it lives exclusively in Stage 4
- `uploadScreenshotsOnWifiOnly` gate now enforced in `_uploadScreenshots`
- Snapshot buffer re-queued on flush rejection or error instead of being silently dropped

## 2.0.61
### Fixed
- `recordZoneError` now guarded by `_isRecording` flag — prevents recursive crash recording if `onCrashEvent` itself throws
- 5-second observer warning now uses `_observerConnected` flag — suppressed as soon as `UnilitixWidget` detects a Navigator or the observer fires its first navigation event

### Added
- `Unilitix.markObserverConnected()` — public static method; call it to suppress the observer warning in custom navigation setups
- `UnilitixWidget` converted to `StatefulWidget` — auto-calls `markObserverConnected()` via `didChangeDependencies` when a `Navigator` is found in context
- `UnilitixObserver.didPush` fires `SdkScope.onObserverConnected` on the first navigation event — wired to `markObserverConnected()` in init
- `SdkScope.onObserverConnected` callback added for observer-to-SDK signalling without circular imports

## 2.0.60
### Changed
- Version bump to 2.0.60 — includes all fixes and changes from 2.0.58 and 2.0.59:
  - Pending session stub wrapped in try/catch with 500 ms retry (2.0.57–2.0.58)
  - Setup pattern updated to `MaterialApp.builder` for correct screenshot capture (2.0.59)
  - Network exceptions filtered from crash tracker (2.0.57)

## 2.0.59
### Changed
- Setup pattern updated: `UnilitixWidget` now placed via `MaterialApp.builder` instead of wrapping `MyApp` — ensures screenshots capture fully rendered content including the navigation shell
- README quick start and `Unilitix.runApp` dartdoc updated to reflect the builder pattern
- `Unilitix.runApp(MyApp())` replaces `Unilitix.runApp(UnilitixWidget(child: MyApp()))`

## 2.0.58
### Changed
- Version bump: pubspec, podspec, `kUnilitixSdkVersion`, and README all synced to 2.0.58

## 2.0.57
### Fixed
- Network exceptions (`ClientException`, "Connection closed", "Software caused connection abort") are now filtered out of crash tracking — avoids false-positive crash reports from transient connectivity drops
- `onSessionStart` pending-session stub write now wrapped in try/catch — failures logged as warnings instead of silently swallowed
- Retry once after 500 ms if `_buildSessionPayload()` returns null on first call (platform channel not ready at session start)

## 2.0.56
### Changed
- Startup observer warning updated: "not connected — add Unilitix.observer to MaterialApp.navigatorObservers" (was stale UnilitixMaterialApp reference)
- Dashboard docs: amber warning callout added directly after the setup snippet in Flutter Quick start Step 2

## 2.0.55
### Changed
- Dartdoc updated on all public `Unilitix` methods and getters — consistent verb-first phrasing, code examples on `observer`, `track`, `identify`, `runApp`, and `init`

## 2.0.54
### Fixed (Android)
- 5G detection added — `NETWORK_TYPE_NR` now returns `"5G"` on Android API 29+ (Q); previously reported as `"4G"`
- `import android.os.Build` added; `NETWORK_TYPE_NR` removed from the 4G case

## 2.0.53
### Changed
- `_retryPending` now processes batches in parallel chunks of 5 — reduces retry wall-clock time under backlog
- Per-batch logic extracted into `_processBatch` for clarity
- `_retryPending(skipPurge: true)` — session-end retries skip the 7-day purge (periodic flush handles it)
- `flushOnSessionEnd` now calls `_retryPending(skipPurge: true)` before the session POST — offline-queued events are delivered and `offlineEventCount` is updated before the session record is sent
- `RetryPolicy.delayFor` adds ±20% random jitter to exponential backoff — reduces thundering-herd on bulk retries
- `offlineEventCount` / `onlineEventCount` fall back to `lastEndedSession` when `currentSession` is null
- File-level dartdoc updated to show current `Unilitix.runApp` + `UnilitixWidget` + `navigatorObservers` pattern

## 2.0.52
### Added
- `pending_sessions` table (DB v3) — persists session stub on start, deleted on clean session end
- `_recoverPendingSessions()` — on SDK init, sends any undelivered session stubs from previous crashed/killed sessions
- `onSessionStart` now saves a stub to `pending_sessions` so crash-killed sessions are recoverable on next launch
- `onSessionEnd` deletes the stub after `flushOnSessionEnd` completes

### Changed
- DB schema version bumped to 3; v1→v3 and v2→v3 migrations handled in `_onUpgrade`

## 2.0.51
### Added
- `onEventsFlush` callback on `SessionManager` — fires on `AppLifecycleState.paused` to drain in-flight events before the app goes dark
- `FlushScheduler.flushEventsOnly()` — events-only flush with no session POST and no screenshot upload; used exclusively for background drains
### Changed
- On `paused`, events are now flushed immediately before the background timer starts — reduces event loss when the OS kills the app during the timeout window

## 2.0.50
### Fixed (iOS)
- Podspec version synced to 2.0.50 (was stale at 2.0.36)
- 5G detection added — `CTRadioAccessTechnologyNRNSA` and `CTRadioAccessTechnologyNR` now return `"5G"` on iOS 14.1+; previously reported as `"4G"`
- Dual-SIM primary carrier selection uses `serviceOrder` (iOS 13+) instead of arbitrary dictionary key iteration

## 2.0.49
### Fixed
- `flushOnSessionEnd` now respects the `_flushing` guard — no more race with periodic flush
- `flushOnSessionEnd` no longer calls `_uploadScreenshots` separately; `_flushEvents` handles it on success, eliminating double-upload
- `_flushEvents` fallback now includes `lastEndedSession?.id` — events are correctly sent after session ends
- `insertEvent` wrapped in a sqflite transaction — count + delete + insert is now atomic
- `EventBuffer` capped at 500 events — drops new events when full instead of growing unbounded

### Changed
- DB schema version bumped to 2 — adds `idx_events_created_at` index on `pending_events(created_at)` for existing and new installs

## 2.0.47
### Changed
- Session timeout is now timer-based — session ends in the background after `sessionTimeoutSeconds` elapses, not on every pause
- `resumed` within timeout cancels the timer and continues the same session (backgroundTimeMs recorded)
- `resumed` after timeout starts a fresh session
- `detached` cancels the pending timer and ends the session immediately
- `stop()` cancels the background timer to prevent leaks
- Extracted `_commitForegroundWindow()` helper — eliminates foreground double-count risk
- Removed dead `onBackground` field

## 2.0.46
### Added
- `UnilitixWidget` — thin `RepaintBoundary` wrapper; replaces `UnilitixMaterialApp` for session replay setup
- New canonical pattern: `Unilitix.runApp(UnilitixWidget(child: MyApp()))` + `navigatorObservers: [Unilitix.observer]`

### Deprecated
- `UnilitixMaterialApp` — use `UnilitixWidget` + plain `MaterialApp` instead; will be removed in v3.0.0

### Changed
- README quick start updated to `UnilitixWidget` pattern

## 2.0.45
### Fixed
- Screenshot capture re-entrancy guard — concurrent captures no longer overlap
- Ordinal incremented before `await` — eliminates race condition under concurrent timers
- `uiImage` always disposed in `finally` — fixes GPU texture memory leak on capture failure
- Upload `Content-Type` corrected to `image/jpeg` to match actual JPEG encoding

## 2.0.44
### Added
- Scroll tracking via NotificationListener — SCROLL events with screen position
- SCROLL gesture type now supported in heatmap

### Fixed
- Heatmap date range filter (days param)
- Network type and offline flag on heatmap data points

## 2.0.42
### Fixed
- Removed double `flushOnSessionEnd` on background — `onBackground` wiring dropped since `onSessionEnd` already triggers the flush when session ends on `paused`
- Removed redundant `SESSION_END` event emit from `onSessionEnd` callback

## 2.0.41
### Changed
- Session ends immediately on `AppLifecycleState.paused` — full session record sent on every background
- `resumed` always starts a fresh session — no more session restore/continue logic
- `onBackground` now triggers `flushOnSessionEnd` (events + screenshots + session record) instead of a simple flush
- `detached` (app killed) still ends the session as a safety net

## 2.0.40
### Fixed
- UnilitixGestureDetector added back to quick start — tap and rage tap tracking now documented correctly
### Changed
- README quick start updated to include UnilitixGestureDetector wrapper

## 2.0.38
### Fixed
- Events flush immediately when app goes to background
- Session ends and full session record sent when app is killed (detached)
- Fixes missing score, duration, device, location on dashboard sessions

## 2.0.37
### Changed
- Version bump: pubspec, podspec, and `kUnilitixSdkVersion` all synced to 2.0.37

## 2.0.36
### Changed
- `Unilitix.init` now accepts a positional `apiKey` string — `init('key')` and `init('key', config: ...)` both work
- Old `init(config: UnilitixConfig(apiKey: ...))` signature removed

### Fixed (iOS)
- Network monitoring now uses NWPathMonitor — real-time updates instead of one-shot static WIFI
- Cellular type resolved to 2G/3G/4G via CTRadioAccessTechnology
- Battery monitoring enabled/disabled correctly — no longer leaks monitoring state
- Podspec version synced to 2.0.36

## 2.0.35
### Changed
- README: simplified init syntax in Quick start and Configuration examples
- README: removed UnilitixGestureDetector from Quick start (UnilitixMaterialApp handles screen tracking)
- README: iOS minimum updated to iOS 13.0+
- README: Verify section version string updated to v2.0.35

## 2.0.34
### Fixed
- iOS plugin rewritten — correct channels (com.unilitix/sdk, com.unilitix/network), correct class name (UnilitixPlugin), handles getBatteryLevel and getCarrierName
- Android manifest declares ACCESS_NETWORK_STATE for correct initial network state
- iOS XCTest updated to match new plugin API
- crashTracker error log updated after logPendingCrashesIfAny rename
### Changed
- example/lib/main.dart updated to UnilitixGestureDetector + UnilitixMaterialApp pattern
- iOS podspec updated: CoreTelephony + UIKit frameworks, PrivacyInfo.xcprivacy, iOS 13.0 minimum, correct metadata
- CONTRIBUTING.md release tag example updated to v2.x.x format

## 2.0.32
### Fixed
- Web stub now handles getBatteryLevel (returns -1.0 sentinel)
- Web connectivity check uses google.com/generate_204 instead of api.unilitix.com — decouples connectivity state from Unilitix API availability
- Docstring in unilitix.dart updated to show UnilitixMaterialApp pattern
### Removed
- EventTypes.scroll — was never emitted, removed to avoid false API expectations
### Changed
- publish.yml pinned to Flutter 3.32.8
### Added
- 73 new unit tests covering UnilitixConfig, UnilitixEvent, RageTapDetector, RetryPolicy, JsonUtil, SnapshotBuffer, EventBuffer, Session, and Unilitix static API (87 total)
- RetryPolicy.delayFor overflow fix — attempt clamped to [0, 20] before bit-shift; returns Duration instead of int
- Removed path and battery_plus dependencies (8 pub dependencies total); battery level now via existing com.unilitix/sdk channel

## 2.0.31
### Fixed
- Init log now shows SDK version (kUnilitixSdkVersion), not app version
- SdkScope.onCrash removed — was emitting a ghost crash event with silently-dropped properties alongside the real one from CrashTracker
- Web screenshot uploads unblocked — _checkConnectivity now returns 'WIFI' so isWifi() is true on web when connected
- publish.yml: actions/checkout@v5 → @v4 (v5 does not exist; publish CI was broken)
### Removed
- SdkScope.onCrash field (no longer assigned or needed)
- CrashTracker.uninstall() — renamed _restoreCrashHandlers() and made private; wiring left for a future Unilitix.dispose() (TODO in crash_tracker.dart)
- AfricaContext.networkType getter (no caller)
- EventDatabase.deleteScreenshotsByIds (no caller)
- EventDatabase.isAvailable getter (no caller)
### Changed
- UnilitixObserver now overrides didRemove in addition to didPush/didPop/didReplace — Navigator.removeRoute() calls now tracked

## 2.0.30
### Fixed
- sdkVersion in payloads and User-Agent now correctly reports SDK version, not app version
- Screenshots now captured: RepaintBoundary auto-attached via UnilitixMaterialApp
- Web network polling no longer converges to OFFLINE — uses http reachability check
- recoverPendingCrash() now called on init — crash batches from previous sessions are logged
- SdkScope.onCrash now wired — was a permanent no-op
- uploadScreenshotBytes now logs exceptions instead of silently swallowing them
### Removed
- SdkScope.onRageTap and SdkScope.onFlushNeeded (dead fields)
- UnilitixConfig.autoTrackScreens and UnilitixConfig.sampleRate (declared, never read)
- AfricaContext.batteryState (no caller)
- EventDatabase.deleteEventsByIds (no caller)
- JsonUtil.encode / decode / safeMap (no callers — only toRfc3339 remains)
- customUserId field from session payload (duplicate of userId)
- Session() fallback in _buildSessionPayload — returns null instead of sending garbage
### Changed
- observerAttached now set in didPop and didReplace, not only didPush
- UnilitixApp deprecated — use UnilitixMaterialApp
- kUnilitixSdkVersion constant in lib/src/core/version.dart is single source of truth for SDK version

## 2.0.29
### Changed
- UnilitixMaterialApp now covers all MaterialApp parameters: scaffoldMessengerKey, color, onGenerateTitle, highContrastTheme, highContrastDarkTheme, routeInformationParser, themeAnimationDuration, themeAnimationCurve, themeAnimationStyle, scrollBehavior, shortcuts, actions, localeListResolutionCallback, localeResolutionCallback, onNavigationNotification, onGenerateInitialRoutes, and all debug overlay flags

## 2.0.28
### Added
- UnilitixMaterialApp — drop-in replacement for MaterialApp with automatic screen tracking; no navigatorObservers wiring needed
- Supports classic navigator, routerDelegate, and routerConfig paths

## 2.0.27
### Fixed
- sdkVersion now reads from PackageInfo at runtime — never drifts from pubspec.yaml
- identify() no longer calls setTraits twice
- screenshotQuality config now correctly passed into screenshot capture
- capturedAt uses RFC3339 consistently in screenshot init and confirm
### Removed
- Dead SdkScope.onRageTap assignment
- Dead remapSessionId method
- maskInputsInScreenshots config field (not yet implemented)
### Changed
- totalStorageGb simplified to honest stub
- webpBytes renamed to jpegBytes

## 2.0.26
- Reconcile version, README and CHANGELOG — all in sync

## 2.0.25
- Fix: API 26 guard for NetworkCallback 3-argument overload
- Fix: NET_CAPABILITY_INTERNET filter to reduce callback frequency

## 2.0.24
- Fix: register NetworkCallback on main thread handler — eliminates ConnectivityThread crash

## 2.0.23
- Fix: widen all dependency constraints (battery_plus, device_info_plus, flutter_secure_storage, image, package_info_plus, http)
- Fix: CHANGELOG entries for 2.0.22

## 2.0.22
- Removed connectivity_plus dependency — native Android network monitoring via EventChannel
- Widened battery_plus and device_info_plus constraints
- Added web platform support

## [2.0.14] - 2026-06-01
### Fixed
- Widened connectivity_plus, battery_plus, device_info_plus constraints
  to support both v6.x and v7.x — resolves dependency conflicts for apps
  still on older plugin versions

## [2.0.13] - 2026-06-01

### Added
- Web platform stub (`lib/unilitix_web.dart`) — registers the
  `com.unilitix/sdk` method channel on web; `getCarrierName` returns
  `''` (carrier detection not available in browsers)
- macOS, Linux, Windows declared as `default_package: unilitix` so
  the pure-Dart SDK works on all desktop platforms without native code

## [2.0.12] - 2026-06-01

### Changed
- Bumped battery_plus to ^7.0.0, connectivity_plus to ^7.0.0,
  device_info_plus to ^11.0.0
- Two-path flush architecture: events → POST /v1/ingest/events,
  session → POST /v1/ingest/session (session end only)
- Custom event properties now sent as top-level `properties` key
  separate from `metadata.name`
- Immediate flush on track() via unawaited flushNow()
- Snapshot buffer now flushed to backend via POST /v1/ingest/snapshots

## [2.0.11] - 2026-05-30

### Changed
- README: expanded track() example to show arbitrary key/value properties

## [2.0.10] - 2026-05-30

### Fixed
- Android device info fallbacks: empty manufacturer → 'Android',
  empty model → brand if available, else 'Unknown'

## [2.0.9] - 2026-05-30

### Fixed
- DeviceInfo collection now logs errors instead of swallowing them silently
- Default values changed from 'unknown' to '' to match backend expectations
- Added success log for device info collection to aid debugging

## [2.0.8] - 2026-05-30

### Fixed
- sdkVersion constant updated from stale 2.0.0 to current version
- Added payload debug logging for device/version fields

## [2.0.7] - 2026-05-30

### Fixed
- Session duration was always 0: `_currentSession` was nulled before flush
  ran; `_buildSessionPayload` now falls back to `lastEndedSession`
- `foregroundTimeMs` was only committed on `paused`; `_endCurrentSession`
  now captures the final foreground window before nulling the session, and
  `_buildSessionPayload` uses `currentForegroundTimeMs` for live sessions
- Debug init log now prints device manufacturer, model, OS version and
  app version/build number so collection failures are immediately visible

## [2.0.6] - 2026-05-30

### Fixed
- Default apiUrl corrected
- Pinned Flutter version to 3.32.0 in CI to fix dart format mismatch

## [2.0.5] - 2026-05-30

### Fixed
- `ProcessInfo.currentRss` guarded with try/catch — returns 0.0 on
  web and platforms where the Dart VM RSS is unavailable
- `SchedulerBinding.addTimingsCallback` guarded with try/catch —
  no-ops on platforms that don't support frame timing callbacks
- sqflite `open()` wrapped in try/catch; all DB operations guarded
  with `_available` flag — SDK continues in memory-only mode if
  local storage is unavailable (e.g. restricted sandboxes)
- `dart:io GZipCodec` replaced with `kIsWeb`-conditional compression
  in `ApiClient` — web sends uncompressed JSON, `Content-Encoding`
  header omitted on web
- `Platform.isAndroid / Platform.isIOS` replaced with
  `defaultTargetPlatform` in `device_info.dart` and
  `africa_context.dart` — `dart:io` import removed from both files;
  `DeviceInfoCollector.os` now returns correct value on all platforms
  including web (`"Web"`) and desktop
- `flutter_secure_storage` failures already fall back to
  `shared_preferences` in `identity.dart` — web is covered

## [2.0.4] - 2026-05-29

### Fixed
- Flush exceptions now caught and logged with stack trace via
  `UnilitixLogger.e`; batch still queued for retry on any throw
- Database open now wrapped in try/catch with ✅/❌ debug logging

## [2.0.3] - 2026-05-29

### Changed
- README rewritten for v2.0.x API — correct init signature,
  UnilitixGestureDetector, migration guide, common mistakes table

## [2.0.2] - 2026-05-29

### Fixed
- All timestamps now sent as RFC3339 strings (was milliseconds int)
- Screen tracking event type changed from NAVIGATE to NAV to match backend
- identify() now calls POST /v1/ingest/identify on backend
- orientation now sent lowercase (portrait/landscape)
- syncAttempts and syncFailedBatches now included in session payload on retry
- Screenshot PUT uses Content-Type: image/webp; WebP encoding via image package
- Screenshot init count clamped to 1–200 backend limit
- Custom event properties correctly wrapped in metadata object

## [2.0.1] - 2026-05-29

### Fixed
- AfricaContext wired into session payload: batteryLevel, carrierName,
  totalStorageGb now real values
- Screenshot capture now stores to DB and uploads via presigned URL flow
- foregroundTimeMs now correctly accumulated per session
- offlineEventCount and onlineEventCount now correctly incremented
- Crash events now include current screen name
- recoverPendingCrash() implemented — logs recovered crash batches on launch
- autoTrackRageTaps config now respected in tap handler
- orientation, carrierName, totalStorageGb added to session JSON payload
- Screenshot DB: screenshotCount(), deleteScreenshotsByIds(),
  deleteOldestScreenshots(), and overflow protection in insertScreenshot()
- UnilitixLogger.w() now gated by enabled flag (debug-only)
- Snapshot payload now includes ordinal, viewportWidth, viewportHeight
- TextField/TextFormField/EditableText text masked in snapshots
  when maskInputs = true
- Removed unused archive dependency

## [2.0.0] - 2026-05-29

### Breaking
- Complete rewrite as pure Dart SDK — no longer wraps Android SDK via JNI method channel
- `UnilitixConfig` now takes `apiKey` as a **required named parameter** (was positional in v1)
- Screen names are now Flutter route names (`/home`) instead of Android class names
- Remove `android/build.gradle` external SDK dependency — all tracking is pure Dart

### Added
- Session lifecycle via `WidgetsBindingObserver` — automatic timeout, background/foreground tracking
- Navigator tracking via `UnilitixObserver` with correct Flutter route names
- `UnilitixGestureDetector` widget for tap and rage-tap tracking
- Rage-tap detection: 3+ taps within 100 px / 1 s window
- Widget-tree snapshot capture via `RenderObject` traversal
- Screenshot capture via `RepaintBoundary.toImage()`
- Crash tracking: `FlutterError.onError` + `PlatformDispatcher.onError`
- `sqflite` offline queue with exponential-backoff retry (5 attempts, 1 s–5 min)
- Gzip compression on all API payloads
- `flutter_secure_storage` encrypted user ID and anonymous ID
- `UnilitixPrivate` widget to mask sensitive content from snapshots
- Africa-first: offline capture, WiFi-only uploads, network transition counting
- Battery level, network quality, carrier name context on every session
- `OptManager` persists opt-out preference across restarts

## [1.0.7] - 2026-05-29

* Android: migrate dependency from JitPack to Maven Central
  (`com.github.Unilitix-hq:unilitix-android` →
  `com.unilitix:unilitix-android:1.4.1`)
* Android: remove JitPack repository URL from build.gradle —
  Maven Central is now the only required repository

## [1.0.6] - 2026-05-28

* CI: bump `actions/checkout` to v5 (Node 24-compatible, ahead of
  June 2 deprecation deadline)
* CI: add Dependabot config to auto-bump GitHub Actions weekly

## [1.0.5] - 2026-05-28

* Added `topics:` to pubspec.yaml for pub.dev discoverability
* Added `documentation:` URL to pubspec.yaml
* README: replaced "iOS: Coming soon" with issue tracker link
* README: fixed bare code fence in Verify section → `text`
* Dartdoc comments added to `isInitialized`, `config`, and `UnilitixLogger`
* Added `.pubignore` to exclude stale scaffold files from the archive
* Added `.github/workflows/publish.yml` for automated publish on tag push
* Added `CONTRIBUTING.md`
* CHANGELOG: dated all entries

## [1.0.4] - 2026-05-28

* Bumped Android SDK dependency to 1.4.1
* Android: debug verification log now automatic in debug builds
* Android: removed dead UnilitixWorkerFactory

## [1.0.3] - 2026-05-28

* Removed stale scaffold plugin file from Android directory
* README: added import line to Quick Start snippet
* README: added version comment to install block

## [1.0.2] - 2026-05-28

* Debug verification log after `Unilitix.init()`: shows SDK
  initialized ✅, session started ✅, and observer attachment
  status ⚠️
* After 5 s in debug mode, warns if no screen events were
  received — prompts developer to add `Unilitix.observer` to
  `MaterialApp.navigatorObservers`
* `UnilitixObserver` now sets an attached flag on first route
  push so the init summary can reflect live observer status

## [1.0.1] - 2026-05-26

* Fix: sampleRate type mismatch — Float vs Double
  in Android native module

## [1.0.0] - 2026-05-26

* Initial release of the Unilitix Flutter SDK
* One-line initialization: `await Unilitix.init('api_key')`
* Automatic session tracking
* Automatic screen tracking via `UnilitixObserver`
* Custom event tracking with `Unilitix.track()`
* User identification with `Unilitix.identify()`
* Crash reporting and rage tap detection
* Offline event buffering with automatic retry
* Privacy controls: `optOut()`, `optIn()`, `reset()`
* Debug mode with console logging
* Android support (API 21+)
