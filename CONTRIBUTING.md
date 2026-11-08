# Contributing to Unilitix Flutter SDK

Thank you for helping improve the SDK. This guide covers everything
you need to get a change merged.

## Prerequisites

- Flutter ≥ 3.10 — run `flutter --version` to check
- An Android device or emulator (API 21+) for integration tests

## Getting started

```bash
git clone https://github.com/Unilitix-hq/unilitix-flutter.git
cd unilitix-flutter
flutter pub get
cd example && flutter pub get && cd ..
```

## Making changes

1. Create a branch: `git checkout -b fix/your-description`
2. Edit code under `lib/` or `android/`.
3. Run the full check suite before opening a PR:

```bash
dart format lib test                 # auto-format
dart analyze --fatal-infos --fatal-warnings
flutter test                         # unit, widget and behaviour tests
flutter pub publish --dry-run        # publish sanity check
```

4. All four commands must exit 0.

## Architecture (3.0.0)

The SDK is a thin wrapper over the native Unilitix SDKs. Behaviour that is
not Flutter-specific (sessions, identity, consent, queue, uploads, retry,
context, native crashes, ANRs, app hangs) belongs in the native SDKs and is
fixed there, not here. This repo holds only:

- `lib/`: Dart error capture, the navigator observer, Android taps,
  widget-tree masking, wireframe walk, screenshot scheduling, the pre-init
  buffer (`lib/src/core/native_bridge.dart`) and power-outage contribution;
- `android/`: the bridge to `com.unilitix:unilitix-android` (Maven Central),
  PixelCopy capture and the power-outage glue;
- `ios/Classes/UnilitixFlutterPlugin.swift`: the bridge to UnilitixCore.

The channel protocol (`com.unilitix/sdk`) is documented on each plugin
class; `test/support/fake_native.dart` is the fake both the unit tests and
the behaviour runner use.

## Native SDK versions

- **Android:** the version is in `android/build.gradle`
  (`com.unilitix:unilitix-android:<version>`) and README "Native SDK
  versions". It must be on Maven Central before a release is tagged.
- **iOS:** `ios/Classes/UnilitixCore/` is vendored from
  [UnilitixCore](https://github.com/Unilitix-hq/unilitix-ios), public facade
  included. Do not edit it here: change UnilitixCore, then re-sync from a
  checkout next to this repo and commit the result:

```bash
scripts/sync-ios-core.sh            # default source: ../unilitix-ios/UnilitixCore
scripts/sync-ios-core.sh path/to/UnilitixCore
```

## Contract fixtures

`lib/src/generated/sdk_contract.dart`, `test/behaviour_fixtures.dart` and
`test/behaviour/*.json` are copied from the api repo (`api/sdk/dart/`,
`api/sdk/behaviour/`); never edit them by hand. After a contract change,
copy them again and update `test/behaviour/COVERAGE.md`.

Plugin unit tests (JUnit), from `example/android`:
`./gradlew :unilitix:testDebugUnitTest`. Integration test on a device or
emulator: `cd example && flutter test integration_test`.

## Dart style

- Follow `package:flutter_lints` rules (enforced by `flutter analyze`).
- Public API members must have `///` doc comments.
- No comments explaining *what* the code does — only *why* if non-obvious.

## Commit messages

Use the conventional-commits prefix that matches your change:

| Prefix | Use for |
|--------|---------|
| `feat:` | new capability |
| `fix:` | bug fix |
| `docs:` | README, CHANGELOG, dartdoc only |
| `chore:` | deps, CI, build tooling |
| `refactor:` | no behaviour change |

## Opening a pull request

- Target the `master` branch.
- Title: same format as commit messages above.
- Link any related GitHub issue in the PR description.
- At least one passing CI run is required before merge.

## Releasing

Releases are automated. Merging to `master` and pushing a `vX.Y.Z`
tag triggers `.github/workflows/publish.yml`, which runs the full
check suite and publishes to pub.dev.

```bash
# After merging your PR — replace X.Y.Z with the new version
git tag vX.Y.Z
git push origin vX.Y.Z
```

## Reporting bugs

Open an issue at
https://github.com/Unilitix-hq/unilitix-flutter/issues

Please include: Flutter version, device/OS, minimal reproduction
steps, and the full error output.

## Questions

Email: support@unilitix.com
