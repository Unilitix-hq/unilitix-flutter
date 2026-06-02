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
dart format lib/                     # auto-format
flutter analyze                      # static analysis
flutter test                         # unit tests
flutter pub publish --dry-run        # publish sanity check
```

4. All four commands must exit 0.

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
git tag v2.0.32
git push origin v2.0.32
```

## Reporting bugs

Open an issue at
https://github.com/Unilitix-hq/unilitix-flutter/issues

Please include: Flutter version, device/OS, minimal reproduction
steps, and the full error output.

## Questions

Email: support@unilitix.com
