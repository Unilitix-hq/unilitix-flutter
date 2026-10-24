#!/usr/bin/env bash
# Copies the Android SDK's native (NDK) crash capture into this plugin, the
# way scripts/sync-ios-core.sh vendors UnilitixCore on iOS.
#
#   scripts/sync-android-native.sh [path/to/unilitix-android checkout]   (default ../Downloads/tazama-android)
#
# Vendored, with only a header added and these rewrites:
#   - Kotlin packages io.unilitix.sdk.{capture,core,util} -> io.unilitix.flutter.nativecrash
#     (imports of those packages are dropped: everything is one package here);
#   - the library unilitix-native -> unilitix-flutter-native (no clash with the
#     Android SDK's libunilitix-native.so when an app ships both);
#   - the C JNI symbols Java_io_unilitix_sdk_capture_NativeSignalHandler_* ->
#     Java_io_unilitix_flutter_nativecrash_NativeSignalHandler_*, to match.
#
# Not vendored (plugin-owned, never touched here):
#   android/src/main/kotlin/io/unilitix/flutter/nativecrash/PluginSupport.kt
#     (KeyValueStore and Logger, which the SDK defines elsewhere),
#   android/src/main/kotlin/com/unilitix/unilitix_flutter/NativeCrashBridge.kt
#     (install, exit-info scan, records for Dart).
# NativeCrashReporter (consent, session attribution) is not used: the Dart
# side owns both.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="${1:-../Downloads/tazama-android}"
SRC="$ROOT/unilitix-sdk/src/main"
[ -d "$SRC/cpp" ] || { echo "Android SDK sources not found at $SRC" >&2; exit 1; }
VERSION=$(sed -n -E 's/.*SDK_VERSION", "\\"([0-9][0-9.]*)\\"".*/\1/p' "$ROOT/unilitix-sdk/build.gradle.kts" | head -n 1)
[ -n "$VERSION" ] || { echo "SDK_VERSION not found in $ROOT/unilitix-sdk/build.gradle.kts" >&2; exit 1; }

KT_DEST=android/src/main/kotlin/io/unilitix/flutter/nativecrash
CPP_DEST=android/src/main/cpp
mkdir -p "$KT_DEST" "$CPP_DEST"

header() { # comment-prefix, source path relative to the SDK module
  echo "$1 VENDORED from unilitix-android $VERSION (unilitix-sdk/src/main/$2) by scripts/sync-android-native.sh."
  echo "$1 Do not edit here; change the Android SDK and re-run the script."
  echo
}

for rel in \
  java/io/unilitix/sdk/capture/NativeCrash.kt \
  java/io/unilitix/sdk/capture/ProcessExits.kt \
  java/io/unilitix/sdk/capture/NativeSignalHandler.kt \
  java/io/unilitix/sdk/core/Fingerprint.kt; do
  { header "//" "$rel"
    # sed -E: portable to the BSD sed on macOS.
    sed -E -e 's/^package io\.unilitix\.sdk\.(capture|core|util)$/package io.unilitix.flutter.nativecrash/' \
        -e '/^import io\.unilitix\.sdk\.(capture|core|util)\./d' \
        -e 's/unilitix-native/unilitix-flutter-native/g' \
        "$SRC/$rel"; } > "$KT_DEST/$(basename "$rel")"
done

{ header "//" cpp/unilitix_native.c
  sed -e 's/Java_io_unilitix_sdk_capture_NativeSignalHandler_/Java_io_unilitix_flutter_nativecrash_NativeSignalHandler_/g' \
      -e 's/unilitix-native/unilitix-flutter-native/g' \
      "$SRC/cpp/unilitix_native.c"; } > "$CPP_DEST/unilitix_native.c"

{ header "#" cpp/CMakeLists.txt
  sed -e 's/unilitix-native/unilitix-flutter-native/g' \
      -e 's/^project(unilitix_native /project(unilitix_flutter_native /' \
      "$SRC/cpp/CMakeLists.txt"; } > "$CPP_DEST/CMakeLists.txt"

echo "Synced unilitix-android $VERSION native crash capture into $KT_DEST and $CPP_DEST"
