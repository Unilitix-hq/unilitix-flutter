# Unilitix Flutter SDK

African-first mobile UX analytics for Flutter.
Track sessions, screens, events and crashes
with a single line of code.

[![pub.dev](https://img.shields.io/pub/v/unilitix.svg)](https://pub.dev/packages/unilitix)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

## Install

```bash
flutter pub add unilitix
# pubspec.yaml — adds unilitix: ^1.0.2
```

## Quick start

### 1. Initialize in `main.dart`

```dart
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Unilitix.init('your_api_key');
  runApp(MyApp());
}
```

Get your API key at [app.unilitix.com](https://app.unilitix.com)
→ Settings → Apps → Create App.

### 2. Add automatic screen tracking

```dart
MaterialApp(
  navigatorObservers: [Unilitix.observer],
)
```

That's it. Sessions, screen flows, taps and crashes
are tracked automatically.

## Track custom events

```dart
Unilitix.track('purchase_completed', {
  'amount': 5000,
  'currency': 'NGN',
});
```

## Identify users

```dart
// Call after login
Unilitix.identify('user_123', {
  'name': 'Tosin',
  'plan': 'pro',
  'country': 'Nigeria',
});

// Call on logout
Unilitix.reset();
```

## Configuration

All options have sensible defaults.
Only override what you need:

```dart
await Unilitix.init(
  'your_api_key',
  config: UnilitixConfig(
    debug: true,                 // console logging
    autoTrackScreens: true,      // auto screen tracking
    autoTrackTaps: true,         // tap heatmaps
    autoTrackCrashes: true,      // crash reports
    autoTrackRageTaps: true,     // frustration detection
    flushIntervalSeconds: 30,    // upload frequency
    sessionTimeoutSeconds: 1800, // session idle timeout
    maskInputs: true,            // hide sensitive fields
    sampleRate: 1.0,             // 100% of sessions
  ),
);
```

## Privacy

```dart
// User opts out of analytics
Unilitix.optOut();

// User opts back in
Unilitix.optIn();
```

## Requirements

| Platform | Minimum version      |
|----------|----------------------|
| Android  | API 21 (Android 5.0) |
| iOS      | Coming soon          |

## Support

- Docs: [docs.unilitix.com](https://docs.unilitix.com)
- Email: support@unilitix.com
- Issues: [GitHub Issues](https://github.com/Unilitix-hq/unilitix-flutter/issues)
