import 'package:flutter/widgets.dart';

/// Shared mutable state and inter-component callbacks.
/// Imported by both lib/unilitix.dart and lib/src/ files to avoid
/// circular imports.
class SdkScope {
  static bool observerAttached = false;
  static bool screenEventReceived = false;
  static String? currentScreen;

  /// True while a [UnilitixWidget] is mounted and recording pointer-down
  /// events itself; [UnilitixGestureDetector] then becomes a passthrough so a
  /// tap is never counted twice.
  static bool widgetHandlesTaps = false;

  /// The repaint boundary key the widget wrapper ([UnilitixWidget]) puts
  /// around the app.
  static final GlobalKey repaintKey = GlobalKey();

  static void Function(String screen)? onScreenChange;
  static void Function(String screen, double x, double y)? onTap;

  /// Called when the observer receives its first navigation event.
  static void Function()? onObserverConnected;

  /// Restores the initial state; for tests.
  static void reset() {
    observerAttached = false;
    screenEventReceived = false;
    currentScreen = null;
    widgetHandlesTaps = false;
    onScreenChange = null;
    onTap = null;
    onObserverConnected = null;
  }
}
