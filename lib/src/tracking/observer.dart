import 'package:flutter/widgets.dart';

import '../core/sdk_scope.dart';
import '../logger/logger.dart';

/// Add to [MaterialApp.navigatorObservers] for automatic screen tracking:
///
/// ```dart
/// MaterialApp(
///   navigatorObservers: [Unilitix.observer],
/// )
/// ```
class UnilitixObserver extends NavigatorObserver {
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    SdkScope.observerAttached = true;
    final name = _name(route);
    UnilitixLogger.d('Screen → $name');
    SdkScope.onScreenChange?.call(name);
    SdkScope.screenEventReceived = true;
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    if (newRoute != null) {
      final name = _name(newRoute);
      SdkScope.onScreenChange?.call(name);
      SdkScope.screenEventReceived = true;
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    if (previousRoute != null) {
      final name = _name(previousRoute);
      SdkScope.onScreenChange?.call(name);
      SdkScope.screenEventReceived = true;
    }
  }

  String _name(Route<dynamic> route) => route.settings.name?.isNotEmpty == true
      ? route.settings.name!
      : route.runtimeType.toString();
}
