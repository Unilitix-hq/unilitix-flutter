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
