# Unilitix Flutter SDK

African-first mobile UX analytics for Flutter. Track sessions, screens, events and crashes with a single line of code.

[![pub package](https://img.shields.io/pub/v/unilitix.svg)](https://pub.dev/packages/unilitix)
[![pub points](https://img.shields.io/pub/points/unilitix)](https://pub.dev/packages/unilitix/score)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![CI](https://github.com/Unilitix-hq/unilitix-flutter/actions/workflows/publish.yml/badge.svg)](https://github.com/Unilitix-hq/unilitix-flutter/actions)

## Install

```yaml
dependencies:
  unilitix: ^2.0.43
```

## Quick start

```dart
import 'package:flutter/material.dart';
import 'package:unilitix/unilitix.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Unilitix.init('YOUR_API_KEY');
  Unilitix.runApp(
    UnilitixGestureDetector(
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return UnilitixMaterialApp( // drop-in for MaterialApp
      home: const HomeScreen(),
    );
  }
}
```

Get your API key at [app.unilitix.com](https://app.unilitix.com) → Settings → Apps.

## Verify your integration

In debug mode you will see:

```text
[Unilitix] SDK initialized ✅ v2.0.35
[Unilitix] Session started ✅ abc123…
[Unilitix] Screen → /home
```

## Track custom events

```dart
Unilitix.track('loan_applied', {
  'amount': 50000,
  'loan_type': 'personal',
  'currency': 'NGN',
});
```

## Identify users

```dart
// After login
Unilitix.identify('user_123', {
  'name': 'Ada Okafor',
  'plan': 'pro',
  'country': 'Nigeria',
});

// After logout
Unilitix.reset();
```

## Configuration

```dart
await Unilitix.init(
  'YOUR_API_KEY',
  config: UnilitixConfig(
    debug: false,
    captureSnapshots: true,
    captureScreenshots: false,
    maskInputs: true,
    flushIntervalSeconds: 30,
    sessionTimeoutSeconds: 1800,
    uploadScreenshotsOnWifiOnly: true,
  ),
);
```

## go_router / custom navigators

```dart
GoRouter(
  observers: [Unilitix.observer],
  routes: [...],
)
```

## Privacy

```dart
Unilitix.optOut(); // user opts out
Unilitix.optIn();  // user opts back in

// Exclude sensitive widgets from recordings
UnilitixPrivate(child: CreditCardWidget())
```

## Requirements

| Platform | Minimum |
|---|---|
| Android | API 21 (Android 5.0) |
| iOS | iOS 13.0+ |
| Web | ✅ Supported |

## Support

- Docs: [docs.unilitix.com](https://docs.unilitix.com)
- Email: support@unilitix.com
- Issues: [GitHub Issues](https://github.com/Unilitix-hq/unilitix-flutter/issues)
