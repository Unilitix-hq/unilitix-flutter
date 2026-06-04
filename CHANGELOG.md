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
