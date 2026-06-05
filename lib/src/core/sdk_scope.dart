/// Shared mutable state and inter-component callbacks.
/// Imported by both lib/unilitix.dart and lib/src/ files to avoid
/// circular imports.
class SdkScope {
  static bool observerAttached = false;
  static bool screenEventReceived = false;
  static String? currentScreen;

  static void Function(String screen)? onScreenChange;
  static void Function(String screen, double x, double y)? onTap;
  static void Function(String screen, double dx, double dy)? onScroll;

  /// Called when the observer receives its first navigation event.
  /// Wired by Unilitix to set [Unilitix._observerConnected].
  static void Function()? onObserverConnected;
}
