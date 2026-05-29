import 'package:flutter/foundation.dart';

import '../events/event.dart';
import '../logger/logger.dart';
import '../core/sdk_scope.dart';

/// Installs crash hooks for Flutter and async errors.
class CrashTracker {
  final void Function(UnilitixEvent event) onCrashEvent;
  final List<Map<String, dynamic>> breadcrumbs;

  FlutterExceptionHandler? _previousFlutterHandler;

  CrashTracker({
    required this.onCrashEvent,
    required this.breadcrumbs,
  });

  void install() {
    _previousFlutterHandler = FlutterError.onError;

    // 1. Flutter framework errors
    FlutterError.onError = (details) {
      _recordCrash(details.exception, details.stack);
      _previousFlutterHandler?.call(details);
    };

    // 2. Async errors outside Flutter framework
    PlatformDispatcher.instance.onError = (error, stack) {
      _recordCrash(error, stack);
      return false;
    };
  }

  void uninstall() {
    FlutterError.onError = _previousFlutterHandler;
    PlatformDispatcher.instance.onError = null;
  }

  void _recordCrash(Object error, StackTrace? stack) {
    UnilitixLogger.e('Crash captured', error, stack);
    final event = UnilitixEvent(type: EventTypes.crash)
      ..exceptionType = error.runtimeType.toString()
      ..exceptionMessage = error.toString()
      ..stackTrace = stack?.toString()
      ..breadcrumbs = List.of(breadcrumbs);
    SdkScope.onCrash?.call(error, stack);
    onCrashEvent(event);
  }

  /// On next launch, check for a crash persisted during the previous session.
  Future<void> recoverPendingCrash() async {
    // Crash recovery is handled by the flush scheduler reading
    // crash events from the database on startup.
  }
}
