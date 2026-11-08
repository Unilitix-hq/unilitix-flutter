/// Single source of truth for the Unilitix Flutter SDK version.
/// Update this constant and pubspec.yaml together on every release.
///
/// Sent to the native SDK as the wrapper version (its `setWrapper`), so
/// sessions report which Flutter SDK wrapped which native core.
const String kUnilitixSdkVersion = '3.0.0';

/// The wrapper name reported to the native SDK.
const String kUnilitixWrapperName = 'flutter';
