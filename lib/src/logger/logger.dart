import 'package:flutter/foundation.dart';

/// Debug-only logger for the Unilitix SDK.
class UnilitixLogger {
  /// Set to true to print debug output to the console.
  /// Automatically set by [Unilitix.init] when [UnilitixConfig.debug] is true.
  static bool enabled = false;

  /// Prints a debug message when [enabled] is true.
  static void d(String message) {
    if (enabled) debugPrint('[Unilitix] $message');
  }

  /// Prints a warning when [enabled] is true.
  static void w(String message) {
    if (enabled) debugPrint('[Unilitix] ⚠️  $message');
  }

  /// Prints an error when [enabled] is true or in a debug build. Release
  /// builds of apps that leave `debug` off print nothing: before 2.7.4 every
  /// SDK error (and its stack trace) went to the device log in production.
  static void e(String message, [Object? error, StackTrace? stack]) {
    if (!enabled && !kDebugMode) return;
    debugPrint('[Unilitix] ❌ $message');
    if (error != null) debugPrint(error.toString());
    if (stack != null) debugPrint(stack.toString());
  }
}
