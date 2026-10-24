# VENDORED from unilitix-android 1.7.0 (unilitix-sdk/src/main/cpp/CMakeLists.txt) by scripts/sync-android-native.sh.
# Do not edit here; change the Android SDK and re-run the script.

# Native crash capture for Android 5.0-10 (API 21-29). On API 30+ the SDK
# reads ApplicationExitInfo instead and never loads this library.
cmake_minimum_required(VERSION 3.18.1)
project(unilitix_flutter_native LANGUAGES C)

add_library(unilitix-flutter-native SHARED unilitix_native.c)

# Plain C, no libc++ and no liblog: the library is a few KB per ABI.
target_compile_options(unilitix-flutter-native PRIVATE
    -Os
    -fvisibility=hidden
    -ffunction-sections
    -fdata-sections
    -Wall
    -Wextra)

target_link_options(unilitix-flutter-native PRIVATE
    -Wl,--gc-sections
    -Wl,--exclude-libs,ALL
    # Strip symbols (AGP strips again when packaging; this keeps the AAR small too).
    -Wl,-s
    # Loadable on 16 KB page-size devices (Android 15+, Google Play requirement).
    -Wl,-z,max-page-size=16384)
