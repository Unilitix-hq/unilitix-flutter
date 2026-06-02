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
}
