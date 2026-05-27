part of '../unilitix.dart';

/// Add to [MaterialApp.navigatorObservers] for automatic
/// screen tracking:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Unilitix.observer],
/// )
/// ```
///
/// Screen names are derived from route settings or widget
/// type names automatically.
class UnilitixObserver extends NavigatorObserver {
  UnilitixObserver._();

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    _trackRoute(route);
  }

  @override
  void didReplace({
    Route<dynamic>? newRoute,
    Route<dynamic>? oldRoute,
  }) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) _trackRoute(newRoute);
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) _trackRoute(previousRoute);
  }

  void _trackRoute(Route<dynamic> route) {
    final name = _routeName(route);
    if (name.isEmpty || name == '/') return;
    Unilitix.screen(name);
  }

  String _routeName(Route<dynamic> route) {
    if (route.settings.name != null && route.settings.name!.isNotEmpty) {
      return route.settings.name!;
    }
    final typeName = route.runtimeType.toString();
    return typeName
        .replaceAll('_', '')
        .replaceAll('Route', '')
        .replaceAll('Page', '');
  }
}
