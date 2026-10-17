# Unilitix Flutter SDK

**Version:** 2.1.2 · [pub.dev](https://pub.dev/packages/unilitix) · [GitHub](https://github.com/unilitix/unilitix-flutter)

Unilitix is a mobile analytics SDK built for African markets. It captures session replays, screen flows, custom events, and user identity — with offline-first data delivery and Africa-specific context (network type, carrier, power outage correlation).

---

## Requirements

| Platform | Minimum | Recommended |
|---|---|---|
| Flutter | 3.10+ | 3.22+ |
| Dart | 3.0+ | — |
| Android | API 21+ | API 26+ (full session replay) |
| iOS | 13.0+ | — |

---

## Installation

```bash
flutter pub add unilitix
```

Or add manually to `pubspec.yaml`:

```yaml
dependencies:
  unilitix: ^2.1.2
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
[Unilitix] SDK initialized ✅ v2.1.2
[Unilitix] Session started ✅ abc123…
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

Events are written to the on-device queue immediately and uploaded in batches
(every `flushIntervalSeconds`, default 30 s, or as soon as `flushBatchSize`
events are waiting). Call `Unilitix.flush()` when an event must leave the
device now — for example right before the user signs out.

### Delivery and offline behaviour

- Every request is made once per cycle. If the API is unreachable or returns
  5xx/429 the SDK backs off (exponentially, or as `Retry-After` says) and keeps
  everything on-device; one success clears the backoff.
- The queue is bounded: 1,000 events (`maxOfflineEvents`), 5 MB, 7 days.
  Oldest batches are dropped first.
- A payload the API rejects with another 4xx is dropped and logged; a 401/403
  pauses uploads until the next launch.
- Errors inside the SDK are logged, never thrown into your app, and never
  recorded as crashes.

---

## Crashes and Errors

Crash reporting is on by default (`autoTrackCrashes`). Three things are
recorded, the way Crashlytics and Sentry classify them:

| Type | Source | Marks session crashed |
|---|---|---|
| `EXCEPTION` (non-fatal) | `FlutterError.onError` — errors the framework caught (overflow, build errors) and `captureException` | No |
| `CRASH` (fatal: false) | `PlatformDispatcher.onError` — an uncaught Dart error | Yes |
| `CRASH` (fatal: true) | Native: JVM uncaught exception, `NSException`, fatal signal — recorded by the plugin and reported on the next launch against the session that was running | Yes |

Handlers the app or another SDK installed before `init()` still run. Every
report carries a stable fingerprint (type + top frames, line numbers
ignored) so one bug is counted once across devices; the same fingerprint is
reported at most 3 times per session, and 50 reports per session in total.

```dart
// Report an error you handled yourself
try {
  await payments.charge(card);
} catch (e, st) {
  Unilitix.captureException(e, stackTrace: st);
}

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

Session replay is **enabled by default**. The SDK captures screenshots and widget tree snapshots and uploads them incrementally every 30 seconds.

**Android:** Uses native `PixelCopy` (API 26+) as the primary capture method, with automatic fallback to Dart-based capture for API 21–25. No configuration needed.

**iOS:** Uses `UIView.drawHierarchy` via the Flutter platform channel.

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
| Screen names, tap and scroll coordinates | yes | `autoTrackTaps` |
| Crash and handled-exception stack traces, last 50 breadcrumbs | yes | `autoTrackCrashes` |
| Memory and frame-drop metrics | yes | — |
| Wireframe snapshots (layout only, text redacted) | yes | `captureSnapshots`, `replaySampleRate` |
| Pixel screenshots (text and inputs painted over) | yes | `captureScreenshots`, `replaySampleRate` |
| Precise or coarse location, advertising id, IMEI, contacts, clipboard | **never** | — |

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

The decision is persisted; on later launches it overrides the `consent:`
argument. `optOut()` / `optIn()` are shortcuts for `denied` / `granted`.
`denied` stops capture, clears memory buffers, purges the whole on-device
queue including crash reports and session stubs, and gates every upload path.

The anonymous id is a random UUID stored on the device — it is never derived
from the advertising id, IMEI or any hardware identifier — and `Unilitix.reset()`
rotates it.

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

No additional setup required. Ensure your `android/app/build.gradle` has:

```groovy
compileSdk 35
minSdk 21
```

For NDK-dependent builds, pin the NDK version:

```kotlin
// android/app/build.gradle.kts
android {
  ndkVersion = "27.0.12077973"
}
```

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

No additional `Info.plist` entries are required.

---

## Troubleshooting

### Blank or black frames in session replay (Android)

Ensure your app meets these requirements:
- `compileSdk 35` or higher
- Flutter 3.22+ for full Impeller compatibility
- SDK v2.0.66 or above

### Sessions showing as incomplete

Ensure `Unilitix.observer` is added to `navigatorObservers`. Sessions require at least one navigation event to complete properly.

### Observer warning at startup

```
[Unilitix] Observer ⚠️ not connected
```

This warning fires during SDK init before `MaterialApp` is built. It clears automatically on first navigation. If it persists, confirm `Unilitix.observer` is in `navigatorObservers`.

### Anonymous ID changes after app update

If upgrading from v2.0.70 or earlier to v2.0.74, users will receive a new anonymous ID on first launch. This is a one-time break — anonymous IDs are now stable across all future app updates.

### Events returning 402

Your workspace has reached its event limit. Upgrade your plan or contact support to increase your limit.

---

## Changelog

See [CHANGELOG.md](https://github.com/unilitix/unilitix-flutter/blob/master/CHANGELOG.md) for full release history.

---

## Support

- **Dashboard:** [app.unilitix.com](https://app.unilitix.com)
- **Email:** support@unilitix.com
- **GitHub Issues:** [github.com/unilitix/unilitix-flutter/issues](https://github.com/unilitix/unilitix-flutter/issues)
