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

  /// The repaint boundary key shared between [ScreenshotCapture] and the
  /// widget wrappers ([UnilitixWidget], [UnilitixMaterialApp]).
  static final GlobalKey repaintKey = GlobalKey();

  static void Function(String screen)? onScreenChange;
  static void Function(String screen, double x, double y)? onTap;
  static void Function(String screen, double dx, double dy)? onScroll;

  /// Called when the observer receives its first navigation event.
  /// Wired by Unilitix to set [Unilitix._observerConnected].
  static void Function()? onObserverConnected;
}
