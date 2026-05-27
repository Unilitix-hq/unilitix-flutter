part of '../unilitix.dart';

class UnilitixLogger {
  static bool enabled = false;
  static const String _tag = '[Unilitix]';

  static void log(String message) {
    if (enabled) debugPrint('$_tag $message');
  }

  static void error(String message) {
    if (enabled) debugPrint('$_tag ✗ $message');
  }
}
