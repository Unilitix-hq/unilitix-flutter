# Unilitix Flutter SDK

African-first mobile UX analytics for Flutter.
Track sessions, screens, events and crashes with a single line of code.

[![pub package](https://img.shields.io/pub/v/unilitix.svg)](https://pub.dev/packages/unilitix)
[![pub points](https://img.shields.io/pub/points/unilitix)](https://pub.dev/packages/unilitix/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![CI](https://github.com/Unilitix-hq/unilitix-flutter/actions/workflows/publish.yml/badge.svg)](https://github.com/Unilitix-hq/unilitix-flutter/actions/workflows/publish.yml)

## Install

```yaml
# pubspec.yaml
dependencies:
  unilitix: ^2.0.10
```
```bash
flutter pub get
```

## Quick start

Copy this entire block into your `main.dart` and replace `YOUR_API_KEY`:

```dart
import 'package:flutter/material.dart';
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Unilitix.init(
    config: const UnilitixConfig(apiKey: 'YOUR_API_KEY'),
  );

  runApp(
    UnilitixGestureDetector(
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorObservers: [Unilitix.observer], // screen tracking
      home: const HomeScreen(),
    );
  }
}
```

Get your API key at [app.unilitix.com](https://app.unilitix.com) → Settings → Apps → Create App.

## Verify your integration

In debug mode, within 5 seconds of launch you will see:

```text
[Unilitix] ✅ SDK initialized
[Unilitix] ✅ Session started
```

If you see a `⚠️` warning about screen events, confirm `Unilitix.observer` is inside `navigatorObservers` in your `MaterialApp`. Silent in production builds.

## Common mistakes

| ❌ Wrong | ✅ Correct |
|---|---|
| `Unilitix.init('your_api_key')` | `Unilitix.init(config: const UnilitixConfig(apiKey: '...'))` |
| `runApp(const MyApp())` | `runApp(UnilitixGestureDetector(child: const MyApp()))` |
| `UnilitixNavigatorObserver()` | `Unilitix.observer` |

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

All options have sensible defaults. Only override what you need:

```dart
await Unilitix.init(
  config: const UnilitixConfig(
    apiKey: 'YOUR_API_KEY',
    debug: true,                  // console logging
    autoTrackScreens: true,       // screen flow tracking
    autoTrackTaps: true,          // tap heatmaps
    autoTrackCrashes: true,       // crash reports
    autoTrackRageTaps: true,      // frustration detection
    flushIntervalSeconds: 30,     // upload frequency
    sessionTimeoutSeconds: 1800,  // session idle timeout (30 min)
    maskInputs: true,             // hide sensitive fields
    sampleRate: 1.0,              // 100% of sessions
    captureScreenshots: true,     // visual session replay
    captureSnapshots: true,       // widget tree capture
    uploadScreenshotsOnWifiOnly: true, // save mobile data
  ),
);
```

## Session control

```dart
await Unilitix.startSession();
await Unilitix.endSession();
await Unilitix.flush();
```

## Privacy

```dart
Unilitix.optOut();
Unilitix.optIn();
```

Wrap sensitive widgets to exclude them from recordings:

```dart
UnilitixPrivate(
  child: CreditCardWidget(),
)
```

## Migration from v1.x

```dart
// Before (v1.x)
await Unilitix.init('your_api_key');
runApp(const MyApp());

// After (v2.x)
await Unilitix.init(
  config: const UnilitixConfig(apiKey: 'your_api_key'),
);
runApp(
  UnilitixGestureDetector(
    child: const MyApp(),
  ),
);
```

## Requirements

| Platform | Minimum version |
|---|---|
| Android | API 21 (Android 5.0) |
| iOS | In development — [track progress](https://github.com/Unilitix-hq/unilitix-flutter/issues/1) |

## Support

- Docs: [docs.unilitix.com](https://docs.unilitix.com)
- Email: support@unilitix.com
- Issues: [GitHub Issues](https://github.com/Unilitix-hq/unilitix-flutter/issues)
