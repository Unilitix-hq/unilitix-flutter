import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' show ClientException;

import '../events/event.dart';
import '../logger/logger.dart';
import '../core/sdk_scope.dart';
import '../storage/event_database.dart';

/// Installs error hooks and classifies what they catch.
///
/// Three tiers, matching how Crashlytics and Sentry report:
///  * `EXCEPTION` (non-fatal) — `FlutterError.onError`: build/layout errors the
///    framework already caught. The app keeps running; the session is not
///    marked crashed. Previously every one of these was recorded as a CRASH,
///    which inflated crash rates with overflow warnings.
///  * `CRASH` (fatal: false) — `PlatformDispatcher.onError`: an uncaught Dart
///    error. Marks the session crashed; the Flutter engine usually survives.
///  * `CRASH` (fatal: true) — native: a JVM uncaught exception, an NSException
///    or a fatal signal recorded by the platform plugin and reported on the
///    next launch.
class CrashTracker {
  final void Function(UnilitixEvent event) onCrashEvent;
  final void Function(UnilitixEvent event)? onExceptionEvent;
  final List<Map<String, dynamic>> breadcrumbs;
  final EventDatabase database;

  static const _sdkChannel = MethodChannel('com.unilitix/sdk');

  FlutterExceptionHandler? _previousFlutterHandler;
  bool _isRecording = false;

  CrashTracker({
    required this.onCrashEvent,
    required this.breadcrumbs,
    required this.database,
    this.onExceptionEvent,
  });

  // TODO: expose Unilitix.dispose() that calls _restoreCrashHandlers()
  // for use in test environments and hot restart scenarios.
  void install() {
    _previousFlutterHandler = FlutterError.onError;

    // 1. Framework-caught errors: non-fatal.
    FlutterError.onError = (details) {
      _record(details.exception, details.stack, type: EventTypes.exception);
      _previousFlutterHandler?.call(details);
    };

    // 2. Uncaught Dart errors: a crash from the user's point of view.
    PlatformDispatcher.instance.onError = (error, stack) {
      _record(error, stack, type: EventTypes.crash);
      // In debug: return false so Flutter re-throws and shows the red screen.
      // In release: return true to suppress the rethrow.
      return !kDebugMode;
    };
  }

  void _record(Object error, StackTrace? stack, {required String type}) {
    if (_isRecording) return;
    _isRecording = true;
    try {
      // Network errors are not crashes — skip to avoid false positives.
      if (error is ClientException ||
          error.toString().contains('Connection closed') ||
          error.toString().contains('Software caused connection abort')) {
        return;
      }
      // A bug in this SDK is not the host app crashing. Every entry point is
      // already guarded; this is the backstop for anything that escapes.
      if (isSdkInternal(stack)) {
        UnilitixLogger.e(
            'Internal SDK error (not recorded as a crash)', error, stack);
        return;
      }
      UnilitixLogger.e(
          type == EventTypes.crash ? 'Crash captured' : 'Exception captured',
          error,
          stack);
      final raw = '${error.runtimeType}: ${error.toString()}';
      final title = raw.length > 200 ? raw.substring(0, 200) : raw;
      final event = UnilitixEvent(type: type, screen: SdkScope.currentScreen)
        ..fatal = false
        ..title = title
        ..exceptionType = error.runtimeType.toString()
        ..exceptionMessage = error.toString()
        ..stackTrace = stack?.toString()
        ..breadcrumbs = List.of(breadcrumbs);
      if (type == EventTypes.crash) {
        onCrashEvent(event);
      } else {
        (onExceptionEvent ?? onCrashEvent)(event);
      }
    } finally {
      _isRecording = false;
    }
  }

  /// True when the top of [stack] is inside this package, i.e. the error was
  /// thrown by SDK code rather than by the app.
  @visibleForTesting
  static bool isSdkInternal(StackTrace? stack) {
    if (stack == null) return false;
    final lines = stack.toString().split('\n');
    for (final line in lines.take(3)) {
      if (line.contains('package:unilitix/')) return true;
      if (line.trim().isNotEmpty && line.contains('package:')) return false;
    }
    return false;
  }

  /// Reads a crash recorded by the native plugin in a previous process and
  /// reports it as a fatal CRASH. Returns true when one was found.
  Future<bool> reportNativeCrashIfAny() async {
    String? raw;
    try {
      raw = await _sdkChannel.invokeMethod<String>('readNativeCrash');
    } catch (_) {
      return false; // platform without the native hook (web, desktop, old plugin)
    }
    if (raw == null || raw.isEmpty) return false;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final platform = m['platform'] as String? ?? 'native';
      final exType = (m['exceptionType'] as String?) ?? 'NativeCrash';
      final signal = m['signal'];
      final msg = (m['exceptionMessage'] as String?) ??
          (signal != null ? 'Fatal signal $signal' : 'Native crash');
      final event = UnilitixEvent(type: EventTypes.crash, screen: null)
        ..fatal = true
        ..title = '$exType: $msg'.length > 200
            ? '$exType: $msg'.substring(0, 200)
            : '$exType: $msg'
        ..exceptionType = exType
        ..exceptionMessage = '[$platform] $msg'
        ..stackTrace = m['stackTrace'] as String?;
      onCrashEvent(event);
      UnilitixLogger.d(
          'Reported native crash from previous launch ($platform)');
      return true;
    } catch (e) {
      UnilitixLogger.w('Could not parse native crash record: $e');
      return false;
    }
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
