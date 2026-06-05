import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show ClientException;

import '../events/event.dart';
import '../logger/logger.dart';
import '../core/sdk_scope.dart';
import '../storage/event_database.dart';

/// Installs crash hooks for Flutter and async errors.
class CrashTracker {
  final void Function(UnilitixEvent event) onCrashEvent;
  final List<Map<String, dynamic>> breadcrumbs;
  final EventDatabase database;

  FlutterExceptionHandler? _previousFlutterHandler;
  bool _isRecording = false;

  CrashTracker({
    required this.onCrashEvent,
    required this.breadcrumbs,
    required this.database,
  });

  // TODO: expose Unilitix.dispose() that calls _restoreCrashHandlers()
  // for use in test environments and hot restart scenarios.
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
      // In debug: return false so Flutter re-throws and shows the red screen.
      // In release: return true to suppress the rethrow.
      return !kDebugMode;
    };
  }

  /// Records an error caught by a Zone (e.g. runZonedGuarded in Unilitix.runApp).
  void recordZoneError(Object error, StackTrace stack) {
    if (_isRecording) return; // prevent recursive crash recording
    _isRecording = true;
    try {
      _recordCrash(error, stack);
    } finally {
      _isRecording = false;
    }
  }

  void _recordCrash(Object error, StackTrace? stack) {
    // Network errors are not crashes — skip to avoid false positives.
    if (error is ClientException ||
        error.toString().contains('Connection closed') ||
        error.toString().contains('Software caused connection abort')) {
      return;
    }
    UnilitixLogger.e('Crash captured', error, stack);
    final raw = '${error.runtimeType}: ${error.toString()}';
    final title = raw.length > 200 ? raw.substring(0, 200) : raw;
    final event = UnilitixEvent(
      type: EventTypes.crash,
      screen: SdkScope.currentScreen,
    )
      ..title = title
      ..exceptionType = error.runtimeType.toString()
      ..exceptionMessage = error.toString()
      ..stackTrace = stack?.toString()
      ..breadcrumbs = List.of(breadcrumbs);
    onCrashEvent(event);
  }

  /// On next launch, logs any crash batches persisted from the previous session.
  /// Actual retry is handled automatically by FlushScheduler on the next flush.
  Future<void> logPendingCrashesIfAny() async {
    try {
      final rows = await database.getOldestEvents(10);
      final crashBatches = rows.where((r) {
        try {
          final events = jsonDecode(r.eventsJson) as List;
          return events.any((e) => (e as Map)['type'] == 'CRASH');
        } catch (_) {
          return false;
        }
      }).toList();
      if (crashBatches.isNotEmpty) {
        UnilitixLogger.d(
            'Recovered ${crashBatches.length} pending crash batch(es) from DB');
      }
    } catch (e) {
      UnilitixLogger.e('logPendingCrashesIfAny failed', e);
    }
  }
}
