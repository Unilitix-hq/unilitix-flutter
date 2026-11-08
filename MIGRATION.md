# Migrating from 2.x to 3.0

3.0.0 turns the Flutter SDK into a thin wrapper over the native Unilitix
SDKs (Android `com.unilitix:unilitix-android` 1.11.2, iOS UnilitixCore
0.8.0). Most apps upgrade by changing the version; read the list below for
what behaves differently.

## 1. Update the dependency

```yaml
dependencies:
  unilitix: ^3.0.0
```

```bash
flutter pub get
cd ios && pod install   # iOS
```

Android: the plugin pulls `com.unilitix:unilitix-android` from Maven Central.
Flutter's project template already lists `mavenCentral()`; if your
`android/build.gradle(.kts)` or `settings.gradle(.kts)` restricts
repositories, add it. `minSdk 21` and `compileSdk 35` as before.

## 2. Code changes

| 2.x | 3.0 |
|---|---|
| `UnilitixMaterialApp(home: ...)` | `MaterialApp(navigatorObservers: [Unilitix.observer], builder: (context, child) => UnilitixWidget(child: child!), home: ...)` |
| `UnilitixApp(child: ...)` | remove it (it did nothing since 2.0) |
| `UnilitixEvent`, `EventTypes` | removed (internal types); use `Unilitix.track` |
| `import 'package:unilitix/unilitix.dart'` / `unilitix_flutter.dart` | unchanged |

Everything else compiles unchanged: `Unilitix.init`, `track`, `identify`,
`screen`, `reset`, `flush`, `setConsent`, `optIn`/`optOut`, `consent`,
`captureException`, `addBreadcrumb`, `startSession`/`endSession`,
`runApp`, `observer`, `UnilitixConfig` (every field), `UnilitixWidget`,
`UnilitixGestureDetector`, `UnilitixPrivate`, `UnilitixUnmasked`,
`UnilitixConsent`.

New: `Unilitix.recordException(type, message, {stackTrace, fatal})`.

## 3. Behaviour changes

**Identity (one-time).** The anonymous id and the user id were stored by
the Dart SDK; they now live in the native SDK, which starts with a new
anonymous id and no user id. On the first launch after the upgrade each
install appears as a new anonymous user. Call `Unilitix.identify(userId)`
after login (or on launch for a signed-in user) so sessions link to the user
again. Later updates keep the ids.

**Consent is carried over.** A decision stored by 2.x (`granted`,
`pending`, `denied`, or the pre-2.1 opt-out) is handed to the native SDK on
the first 3.0 launch, before any other call, and then persisted there. A
user who denied stays denied.

**Unsent 2.x data is not migrated.** Events, wireframes and screenshots
that 2.x had queued on the device (SQLite) when the app was updated are not
sent; the old database file is left in place and unused. Ship 3.0 when
your users are online, or call `Unilitix.flush()` in the last 2.x release.

**Delivery follows the contract exactly** (the native SDKs'): 408 is
retried (2.x dropped it), a 402 `Retry-After` is clamped to 1 s–1 h,
properties are normalised (depth 5, 100 keys, 1,024-character strings,
NaN/Infinity become `null`; 2.x failed the whole batch on NaN), the network
type includes `5G` and `ETHERNET`, a repeated `screen()` with the current
name is dropped, and `reset()` starts a new session.

**Errors.**
- An uncaught Dart error is `CRASH` with `fatal: true` (2.x: `fatal:
  false`); still marks the session crashed.
- Native crashes, ANRs and app hangs are reported by the native SDK, once
  (the 2.x plugin's own handlers are gone). If your app also initialised
  the Unilitix Android or iOS SDK directly, there is now one SDK instance:
  initialise it once (the second `init` is ignored).
- `addBreadcrumb(data:)` is appended to the message as JSON.

**Session replay.**
- Screenshots need Android 8.0+ (API 26, `PixelCopy`); Android 5–7.1 get
  wireframes only (2.x had a slower Dart fallback).
- Frames are encoded natively and stored by the native SDK; nothing changes
  in masking (`maskAllText`, `maskInputs`, `maskImages`, `maskScreenshots`,
  `UnilitixPrivate`, `UnilitixUnmasked` work as before).
- `replaySampleRate` is decided once per session by the native SDK.

**Taps.** Android: as before (sent from Dart, no position inside
`UnilitixPrivate`). iOS: recorded by UnilitixCore, which sees Flutter's
touches and uses the route names from `UnilitixObserver`, but cannot see
`UnilitixPrivate`: a tap there keeps its position. Turn `autoTrackTaps` off
if tap positions on a screen are sensitive (a PIN pad drawn in Flutter).

**Scroll events** (`SCROLL`) are no longer sent (only the removed
`UnilitixMaterialApp` sent them).

**Web and desktop.** Not supported: the SDK compiles but does nothing (a
debug warning at `init`). 2.x's web support stored data in Dart and is gone
with the Dart engine.

**Options.** Every `UnilitixConfig` field is still accepted. They are
applied (and out-of-range values clamped) by the native SDK, with the same
defaults. `appHangTimeoutMs` configures UnilitixCore's watchdog (iOS);
`powerOutageContribution` still works on both platforms.

## 4. Verify

Run in debug with `debug: true`:

```
[Unilitix] SDK initialized  ✅  v3.0.0 (native session 1a2b3c4d…, consent granted)
```

then track an event and check it on the dashboard.
