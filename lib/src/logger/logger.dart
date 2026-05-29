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

  /// Always prints an error message.
  static void e(String message, [Object? error, StackTrace? stack]) {
    debugPrint('[Unilitix] ❌ $message');
    if (error != null) debugPrint(error.toString());
    if (stack != null) debugPrint(stack.toString());
  }
}
