## 1.0.3

* Removed stale scaffold plugin file from Android directory
* README: added import line to Quick Start snippet
* README: added version comment to install block

## 1.0.2

* Debug verification log after `Unilitix.init()`: shows SDK
  initialized ✅, session started ✅, and observer attachment
  status ⚠️
* After 5 s in debug mode, warns if no screen events were
  received — prompts developer to add `Unilitix.observer` to
  `MaterialApp.navigatorObservers`
* `UnilitixObserver` now sets an attached flag on first route
  push so the init summary can reflect live observer status

## 1.0.1

* Fix: sampleRate type mismatch — Float vs Double
  in Android native module

## 1.0.0

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
