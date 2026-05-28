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
