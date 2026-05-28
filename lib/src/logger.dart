part of '../unilitix.dart';

/// Internal logging helper for the Unilitix SDK.
///
/// Set [enabled] to `false` to suppress all SDK console output.
/// Automatically enabled in debug builds via [Unilitix.init].
class UnilitixLogger {
  /// Controls whether log output is printed to the console.
  /// Set automatically by [Unilitix.init] based on [UnilitixConfig.debug]
  /// and [kDebugMode].
  static bool enabled = false;
  static const String _tag = '[Unilitix]';

  /// Prints [message] prefixed with `[Unilitix]` when [enabled] is true.
  static void log(String message) {
    if (enabled) debugPrint('$_tag $message');
  }

  /// Prints an error [message] prefixed with `[Unilitix] ✗` when [enabled]
  /// is true.
  static void error(String message) {
    if (enabled) debugPrint('$_tag ✗ $message');
  }
}
