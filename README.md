# Unilitix Flutter SDK

**Version:** 2.0.71 · [pub.dev](https://pub.dev/packages/unilitix) · [GitHub](https://github.com/unilitix/unilitix-flutter)

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
  unilitix: ^2.0.71
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
[Unilitix] SDK initialized ✅ v2.0.71
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

---

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

## Privacy Masking

Exclude sensitive widgets from session recordings:

```dart
UnilitixPrivate(
  child: CreditCardForm(),
)
```

> ⚠️ `UnilitixPrivate` excludes widgets from the **wireframe snapshot** only. It does not mask pixel screenshots. To prevent sensitive content in screenshots, set `captureScreenshots: false` in `UnilitixConfig`.

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
    flushIntervalSeconds: 30,            // how often to upload data
    sessionTimeoutSeconds: 1800,         // session inactivity timeout (30 min)
    uploadScreenshotsOnWifiOnly: false,  // restrict uploads to WiFi
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
// Stop tracking (e.g. user opts out)
Unilitix.optOut();

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

If upgrading from v2.0.70 or earlier to v2.0.71, users will receive a new anonymous ID on first launch. This is a one-time break — anonymous IDs are now stable across all future app updates.

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
