# Unilitix Flutter SDK

**Version:** 3.0.0 · [pub.dev](https://pub.dev/packages/unilitix) · [GitHub](https://github.com/unilitix/unilitix-flutter)

Unilitix is a mobile analytics SDK built for African markets. It captures session replays, screen flows, custom events, and user identity — with offline-first data delivery and Africa-specific context (network type, carrier, power outage correlation).

**3.0.0 is a thin wrapper over the native Unilitix SDKs** (Android
`com.unilitix:unilitix-android`, iOS UnilitixCore), the way Sentry and Datadog
ship Flutter: sessions, identity, consent, the offline queue, uploads and
retries, device and network context, native crashes, ANRs and app hangs run
in the native SDK, so a Flutter app behaves exactly like a native one. The
Dart side keeps what only Dart can see — Dart/Flutter errors, route names,
and masked replay of the widget tree. Upgrading from 2.x? Read
[MIGRATION.md](MIGRATION.md).

---

## Requirements

| Platform | Minimum | Recommended |
|---|---|---|
| Flutter | 3.10+ | 3.22+ |
| Dart | 3.0+ | — |
| Android | API 21+ | API 26+ (screenshots in session replay) |
| iOS | 13.0+ | — |
| Web, desktop | not supported since 3.0.0 (the SDK does nothing there) | — |

### Native SDK versions

| unilitix (Flutter) | Android SDK (Maven Central) | iOS (UnilitixCore, vendored in the pod) |
|---|---|---|
| 3.0.0 | `com.unilitix:unilitix-android:1.11.2` | 0.8.0 |

The Android SDK comes from Maven Central through Gradle; nothing to add if
your project already lists `mavenCentral()` (Flutter's template does).

---

## Installation

```bash
flutter pub add unilitix
```

Or add manually to `pubspec.yaml`:

```yaml
dependencies:
  unilitix: ^3.0.0
```

Then run:

```bash
flutter pub get
```

---

## Quick Start

### 1. Initialize the SDK

In your `main.dart`, initialize Unilitix before running your app:

```dart
import 'package:unilitix/unilitix_flutter.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Unilitix.init('YOUR_API_KEY');
  Unilitix.runApp(MyApp());
}
```

Get your API key from **Dashboard → Settings → Apps**.

---

### 2. Set Up Your App Widget

Add `Unilitix.observer` to `navigatorObservers` and wrap your app content with `UnilitixWidget` inside the `builder`:

```dart
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [Unilitix.observer],
      builder: (context, child) => UnilitixWidget(child: child!),
    );
  }
}
```

> ⚠️ **Always use the `builder` pattern.** Do not wrap `MaterialApp` itself with `UnilitixWidget` — this causes blank frames in session replay.

---

### 3. Verify Integration

Run your app in debug mode. Within 5 seconds you should see:

```
[Unilitix] SDK initialized  ✅  v3.0.0 (native session abc123…, consent granted)
[Unilitix] Screen → /home
```

If you see `Observer ⚠️ not connected`, ensure `Unilitix.observer` is in `navigatorObservers`. The warning clears automatically on first navigation.

---

## Screen Tracking

Screen tracking is **automatic** when `Unilitix.observer` is added. No additional code needed for standard `MaterialApp` routing.

### go_router

```dart
GoRouter(
  observers: [Unilitix.observer],
  routes: [...],
)
```

### Named Routes

For screen names to appear correctly in the dashboard, all routes must have a name:

```dart
Navigator.push(context, MaterialPageRoute(
  settings: RouteSettings(name: '/payment'),
  builder: (context) => PaymentScreen(),
));
```

Without a name, routes appear as `MaterialPageRoute<dynamic>` in your analytics.

---

## Identify Users

Associate sessions with a user ID after login. Call `identify()` in two places:

```dart
// 1. After successful login
await AuthService.login(email, password);
Unilitix.identify(
  user.id,
  {
    "email": user.email,
    "name": user.name,
    "phone": user.phoneNumber,
    "account_type": user.accountType,
  },
);

// 2. On app startup — if already logged in
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Unilitix.init('YOUR_API_KEY');
  final user = await AuthService.getCurrentUser();
  if (user != null) {
    Unilitix.identify(user.id, {"name": user.name, "email": user.email});
  }
  Unilitix.runApp(MyApp());
}
```

> ⚠️ Calling `identify()` only on login means returning users who skip login will appear as anonymous.

---

## Track Custom Events

```dart
Unilitix.track("loan_applied", {
  "amount":    50000,
  "loan_type": "personal",
  "currency":  "NGN",
});
```

Event names should be `snake_case`. Property values can be `String`, `int`, `double`, or `bool`.

Events go to the native SDK's on-device queue and are uploaded in batches
(every `flushIntervalSeconds`, default 30 s, or as soon as `flushBatchSize`
events are waiting). Call `Unilitix.flush()` when an event must leave the
device now — for example right before the user signs out.

Calls made before `init()` completes are kept (up to 200, oldest dropped)
and sent in order right after it.

### Delivery and offline behaviour

Delivery is the native SDK's and follows the Unilitix SDK contract, the same
on every platform: one request per cycle; no response, 408, 429 and 5xx back
off (exponentially, or as `Retry-After` says) and keep the data; 401/403
pause uploads until the next launch; 402 keeps the data and pauses for
`Retry-After` (1 s–1 h) or 15 minutes; other 4xx drop that batch. The queue
holds `maxOfflineEvents` (1,000) events, oldest dropped first. Errors inside
the SDK are logged, never thrown into your app, and never recorded as
crashes.

---

## Crashes and Errors

Crash reporting is on by default (`autoTrackCrashes`). The Dart side reports
what only Dart can see; everything native is the native SDK's:

| Type | Source | Reported by | Marks session crashed |
|---|---|---|---|
| `EXCEPTION` | `FlutterError.onError` (errors the framework caught: overflow, build errors) and `captureException` | Dart → native `recordExternalError(platform: "dart")` | No |
| `CRASH` | `PlatformDispatcher.onError` (an uncaught Dart error), or `captureException(fatal: true)` | Dart → native `recordExternalError` | Yes |
| `CRASH` | JVM uncaught exception, `NSException`, fatal signals in native code (engine, plugins) | Native SDK, on the next launch | Yes |
| `ANR` | Android: the system's ANR records (API 30+) | Native Android SDK | No |
| `ANR` | iOS: main thread blocked for `appHangTimeoutMs` (2 s; 0 turns it off) | UnilitixCore | No |

Every Dart report carries the SDK contract fingerprint (type + first three
frames, line numbers ignored), so one bug is one issue across devices and
platforms; the native SDK applies the per-session caps (3 per fingerprint,
50 in total). A framework error that repeats every frame is sent at most 3
times per session. Handlers the app or another SDK installed before `init()`
still run. If your app runs in its own zone, pass the zone's errors on (and
initialise inside the zone, or Flutter reports a zone mismatch):

```dart
void main() {
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await Unilitix.init('YOUR_API_KEY');
    Unilitix.runApp(MyApp());
  }, (e, st) => Unilitix.captureException(e, stackTrace: st, fatal: true));
}
```

How native crashes, ANRs and app hangs are captured, symbolicated and
grouped is described in the native SDKs' documentation; a Flutter app gets
exactly that behaviour.

```dart
// Report an error you handled yourself
try {
  await payments.charge(card);
} catch (e, st) {
  Unilitix.captureException(e, stackTrace: st);
}

// An error described by its parts (a WebView message, another runtime)
Unilitix.recordException('PaymentDeclined', 'card expired', stackTrace: trace);

// Leave a trail for the next crash report (last 50 kept)
Unilitix.addBreadcrumb('checkout started', category: 'flow', data: {'items': 3});
```

### Obfuscated builds

Release builds with `--obfuscate --split-debug-info` produce stack traces
the dashboard cannot read until the symbols are uploaded. Reports carry
`buildId` and `isolateDsoBase`; upload the matching symbols once per build:

```bash
flutter build apk --release --obfuscate --split-debug-info=build/symbols
UNILITIX_API_KEY=ul_live_… dart run unilitix:unilitix_symbols upload build/symbols \
  --app-version 3.4.0 --build-number 120
```

## Session Replay

Session replay is **enabled by default**. The Dart side decides what to hide
(it knows the widget tree) and when to take a frame (navigation, taps,
layout changes, a heartbeat on static screens); the native SDK samples
sessions (`replaySampleRate`), caps, stores and uploads.

- **Wireframe snapshots** are walked from the widget tree in short slices
  (never more than a few milliseconds of UI time at once) and handed to the
  native SDK.
- **Screenshots** are drawn natively with the masks painted in the same
  pass — `PixelCopy` on Android (API 26+; no screenshots on Android 5–7.1,
  wireframes only), `drawHierarchy` on iOS — and handed to the native SDK
  without crossing back to Dart.

To disable:

```dart
await Unilitix.init(
  'YOUR_API_KEY',
  config: UnilitixConfig(
    captureScreenshots: false,
    captureSnapshots: false,
  ),
);
```

> Session replay requires the **Growth plan** or above.

---

## Privacy and consent

### What the SDK collects by default

| Data | Collected | Switch |
|---|---|---|
| Anonymous id (random UUID, rotated by `reset()`), install id | yes | — |
| Your user id and traits, only after you call `identify()` | yes | call `identify()` or not |
| Device make/model, OS version, screen size, locale, timezone | yes | — |
| App version, build number, package name | yes | — |
| Network type and transitions, carrier name, battery level | yes | — |
| Screen names, tap coordinates | yes | `autoTrackTaps` |
| Crash and handled-exception stack traces, last 50 breadcrumbs | yes | `autoTrackCrashes` |
| Performance metrics the native SDK collects | yes | — |
| Wireframe snapshots (layout only, text redacted) | yes | `captureSnapshots`, `replaySampleRate` |
| Pixel screenshots (text and inputs painted over) | yes | `captureScreenshots`, `replaySampleRate` |
| Plug/unplug events with an H3 cell (~5 km²) and a daily device hash | only if you opt in | `powerOutageContribution` (see below) |
| Precise location or coordinates, advertising id, IMEI, contacts, clipboard | **never** | — |

### Masking

The SDK is private by default, in both replay formats:

- **Text is redacted** (`maskAllText`, on by default). In wireframe snapshots
  every `Text` widget's content becomes same-length bullets; in pixel
  screenshots the bounds of every text widget are painted over on the device
  before the frame is encoded. Wrap copy that is safe and useful to see in
  **`UnilitixUnmasked`**:

```dart
UnilitixUnmasked(child: Text('Checkout'))
```

- **Input fields** (`TextField`, `TextFormField`, `CupertinoTextField`) are
  masked in snapshots and painted over in screenshots (`maskInputs`, on by
  default), even inside an `UnilitixUnmasked` subtree.
- **`UnilitixPrivate`** paints over any subtree in screenshots and collapses
  it in snapshots — for charts, QR codes, documents and avatars:

```dart
UnilitixPrivate(child: BalanceChart())
```

- **Taps inside `UnilitixPrivate`** are recorded without their position on
  Android. On iOS taps are recorded by UnilitixCore, which cannot see Flutter
  widgets: use `autoTrackTaps: false` on screens where tap positions are
  sensitive (PIN pads), or keep such input in a native view.
- **Images** can be blacked out with `maskImages: true` (off by default).
- If the SDK cannot compute the mask regions for a frame, the frame is dropped
  rather than sent unmasked.

```dart
await Unilitix.init(
  'YOUR_API_KEY',
  config: UnilitixConfig(
    maskAllText: true,        // redact all text in snapshots and screenshots (default)
    maskInputs: true,         // mask TextField content (default)
    maskScreenshots: true,    // paint over masked regions in screenshots (default)
    maskImages: false,        // black out images
    replaySampleRate: 1.0,    // fraction of sessions with replay; 0 disables it
  ),
);
```

### Consent

For apps under NDPR, GDPR or similar, start in `pending`: the SDK captures to
its on-device queue but uploads nothing until the user decides.

```dart
await Unilitix.init('YOUR_API_KEY', consent: UnilitixConsent.pending);

// After your consent screen:
await Unilitix.setConsent(UnilitixConsent.granted); // sends everything held
// or
await Unilitix.setConsent(UnilitixConsent.denied);  // deletes everything held
```

The decision is persisted by the native SDK; on later launches it overrides
the `consent:` argument. `optOut()` / `optIn()` are shortcuts for `denied` /
`granted`. `setConsent` may be called before `init`: it is sent right after
the native SDK starts, before any other call. A decision stored by 2.x is
carried over on the first 3.0.0 launch. `denied` stops capture and deletes
everything queued on the device.

The anonymous id is a random UUID stored on the device — it is never derived
from the advertising id, IMEI or any hardware identifier — and `Unilitix.reset()`
rotates it.

---

## Power outage contribution

*New in 2.2.0. Off by default.*

When the grid drops in a neighbourhood, every phone that was plugged in stops
charging within the same minute. With this feature on, the SDK reports
charging transitions against a coarse map cell, and the Unilitix server turns
synchronised drops into a crowd-sourced power-outage map.

### Double opt-in

Nothing is collected unless **all** of these hold:

1. **You enable it:** `UnilitixConfig(powerOutageContribution: true)`.
2. **Your app has coarse location permission** — declared in your manifest /
   Info.plist *and requested by your app*. The SDK never asks for permission
   and never starts location updates; it only reads the location the system
   already has, and only if your app was granted it. Without it, nothing is
   sent for the map.
3. **Consent is `UnilitixConsent.granted`.** While consent is `pending` or
   `denied` this feature collects nothing and holds nothing; moving to
   `pending` or `denied` deletes anything it had queued.

```dart
await Unilitix.init(
  'YOUR_API_KEY',
  config: const UnilitixConfig(
    apiKey: 'YOUR_API_KEY',
    powerOutageContribution: true,
  ),
);
```

### What is sent

`POST /v1/signals/power`:

```json
{
  "cell": "87589c984ffffff",
  "device": "27042224245e18fcd6d8999c93dbef66",
  "events": [
    {"type": "disconnect", "ts": "2025-10-09T08:53:20.000Z"},
    {"type": "sample", "charging": true, "ts": "2025-10-09T09:10:02.000Z"}
  ]
}
```

- **`cell`** — the [H3](https://h3geo.org) resolution-7 cell (~5 km²)
  containing the device, computed **on the device**. Latitude and longitude
  never leave the device. A location fix older than 24 h is not used.
- **`device`** — a hash that changes every UTC day: the first 128 bits of
  SHA-256 over the install id, a random salt that never leaves the device, and
  the date. The server can count distinct devices in a cell on one day, but
  cannot link a device across days or to its analytics sessions. The raw
  install id is never sent with these events.
- **`events`** — `connect` / `disconnect` (plugged in / unplugged) and
  `sample` (whether the device was plugged in at that moment), at most 200 per
  request. Events older than 48 h are dropped, never sent; at most 500 are
  kept on the device.

No user id, anonymous id, session id, device model or app data is attached.

### k-anonymity on the server

The server only uses a cell when enough distinct devices report from it, and
only publishes outage areas, never individual devices or their events. Cells
with too few contributors are not shown.

### How it works per platform

- **Android:** a broadcast receiver for `ACTION_POWER_CONNECTED` /
  `ACTION_POWER_DISCONNECTED` appends one line to a small file in the app's
  no-backup directory (no Flutter engine, no network) — it is disabled in the
  manifest and only enabled at runtime when you opt in. A WorkManager job
  (every 15 min, when a network is available) records a charging sample and
  uploads; the SDK also uploads on every app foreground. The cell comes from
  `LocationManager.getLastKnownLocation` (network / passive provider; no Google
  Play services).
- **iOS:** iOS gives apps no background charging signal, so the SDK records
  samples when the app comes to the foreground and goes to the background, and
  plug changes while it is in the foreground, and uploads on foreground. The
  location is `CLLocationManager().location`, only with when-in-use or always
  authorization.

### What your app must add

**Android** — `android/app/src/main/AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.ACCESS_COARSE_LOCATION" />
```

and request it at runtime yourself (e.g. with `permission_handler`). The SDK
adds the receiver and WorkManager to the merged manifest; it declares no
location permission.

**iOS** — `ios/Runner/Info.plist`:

```xml
<key>NSLocationWhenInUseUsageDescription</key>
<string>Your approximate area helps map power outages near you.</string>
```

and request when-in-use authorization yourself (e.g. with `geolocator` or
`permission_handler`). Reduced ("approximate") accuracy is enough. Mention
coarse location in your App Store privacy label and Play data-safety form.

---

## Advanced Configuration

```dart
await Unilitix.init(
  'YOUR_API_KEY',
  config: UnilitixConfig(
    debug: false,                        // disable SDK logs in production
    captureSnapshots: true,              // wireframe replay
    captureScreenshots: true,            // pixel screenshot replay
    maskInputs: true,                    // mask text field input
    maskAllText: true,                   // redact text in snapshots and screenshots
    flushIntervalSeconds: 30,            // how often to upload data
    sessionTimeoutSeconds: 1800,         // session inactivity timeout (30 min)
    uploadScreenshotsOnWifiOnly: true,   // hold screenshot uploads until Wi-Fi (default)
    maxScreenshotsPerMinute: 20,         // cap for continuously redrawing screens
    screenshotHeartbeatMs: 10000,        // frame at least this often when static
    appHangTimeoutMs: 2000,              // iOS app hangs; 0 turns them off
  ),
);
```

---

## Session Control

```dart
// Manually start a new session
await Unilitix.startSession();

// End the current session
await Unilitix.endSession();

// Force upload all queued data immediately
await Unilitix.flush();
```

---

## Privacy Controls

```dart
// Stop tracking: ends replay capture, discards buffered data and purges the
// on-device queue so nothing captured afterwards leaves the device
await Unilitix.optOut();

// Resume tracking
Unilitix.optIn();

// Clear user identity and reset anonymous ID
Unilitix.reset();
```

---

## Android Setup

No additional setup required (see [Power outage contribution](#power-outage-contribution)
for the one opt-in feature that needs a permission). The plugin depends on
`com.unilitix:unilitix-android` from Maven Central; keep `mavenCentral()` in
your repositories. Ensure your `android/app/build.gradle` has:

```groovy
compileSdk 35
minSdk 21
```

The plugin has no native code of its own since 3.0.0 (native crash capture
is the Android SDK's).

**Apps that also use the Unilitix Android SDK directly** (add-to-app, native
screens): there is one SDK instance per process. Initialise it from Flutter
(`Unilitix.init`) or natively, not both: the second `init` is ignored, so the
first one's API key and options apply to native and Flutter screens alike.

---

## iOS Setup

Add the following to your `ios/Podfile` if not already present:

```ruby
platform :ios, '13.0'
```

Then run:

```bash
cd ios && pod install
```

No additional `Info.plist` entries are required, unless you enable
[power outage contribution](#power-outage-contribution). UnilitixCore is
compiled into the plugin's pod (no separate dependency).

---

## Troubleshooting

### Blank or black frames in session replay (Android)

Ensure your app meets these requirements:
- `compileSdk 35` or higher
- Flutter 3.22+ for full Impeller compatibility
- Android 8.0 (API 26) or later on the device (screenshots use `PixelCopy`)

### Sessions showing as incomplete

Ensure `Unilitix.observer` is added to `navigatorObservers`. Sessions require at least one navigation event to complete properly.

### Observer warning at startup

```
[Unilitix] Observer ⚠️ not connected
```

This warning fires during SDK init before `MaterialApp` is built. It clears automatically on first navigation. If it persists, confirm `Unilitix.observer` is in `navigatorObservers`.

### Anonymous ID changes after app update

Upgrading from 2.x to 3.0.0 gives every install a new anonymous ID on its
first launch (identity moved from Dart storage to the native SDK) and forgets
the user ID: call `identify()` again after login, as most apps already do on
every launch. See [MIGRATION.md](MIGRATION.md). (Upgrading from v2.0.70 or
earlier to v2.0.74 was a similar one-time break.)

### Events returning 402

Your workspace has reached its event limit. Upgrade your plan or contact support to increase your limit.
The SDK keeps what it has captured (within its on-device caps) and pauses
uploads for 15 minutes (or the server's `Retry-After`) at a time, so nothing
is lost while the plan is topped up.

---

## Changelog

See [CHANGELOG.md](https://github.com/unilitix/unilitix-flutter/blob/master/CHANGELOG.md) for full release history.

---

## Support

- **Dashboard:** [app.unilitix.com](https://app.unilitix.com)
- **Email:** support@unilitix.com
- **GitHub Issues:** [github.com/unilitix/unilitix-flutter/issues](https://github.com/unilitix/unilitix-flutter/issues)
