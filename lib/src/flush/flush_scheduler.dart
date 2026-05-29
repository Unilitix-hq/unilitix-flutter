import 'dart:async';
import 'dart:convert';

import '../events/event_buffer.dart';
import '../session/session_manager.dart';
import '../storage/event_database.dart';
import '../storage/pending_event.dart';
import '../network/api_client.dart';
import '../network/network_monitor.dart';
import '../performance/performance_monitor.dart';
import '../logger/logger.dart';

/// Schedules periodic event flushing and handles retry logic.
class FlushScheduler {
  final int intervalSeconds;
  final EventBuffer buffer;
  final SessionManager sessionManager;
  final EventDatabase database;
  final ApiClient apiClient;
  final NetworkMonitor networkMonitor;
  final PerformanceMonitor performanceMonitor;
  final Map<String, dynamic> Function() buildSessionPayload;
  final bool uploadScreenshotsOnWifiOnly;

  Timer? _timer;
  bool _flushing = false;

  FlushScheduler({
    required this.intervalSeconds,
    required this.buffer,
    required this.sessionManager,
    required this.database,
    required this.apiClient,
    required this.networkMonitor,
    required this.performanceMonitor,
    required this.buildSessionPayload,
    required this.uploadScreenshotsOnWifiOnly,
  });

  void start() {
    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => flush(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _flushBuffer();
      await _retryPending();
    } finally {
      _flushing = false;
    }
  }

  Future<void> _flushBuffer() async {
    final events = buffer.drain();
    if (events.isEmpty) return;

    for (final event in events) {
      performanceMonitor.enrichEvent(event);
      event.capturedOffline = networkMonitor.isOffline();
      event.networkAtCapture = networkMonitor.currentType();
    }

    final sessionPayload = buildSessionPayload();
    final eventsJson = jsonEncode(events.map((e) => e.toJson()).toList());

    final pending = PendingEvent(
      sessionJson: jsonEncode(sessionPayload),
      eventsJson: eventsJson,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      capturedOffline: networkMonitor.isOffline(),
      networkAtCapture: networkMonitor.currentType(),
    );

    if (networkMonitor.isOffline()) {
      await database.insertEvent(pending);
      UnilitixLogger.d('Offline — queued ${events.length} events');
      return;
    }

    final ok = await apiClient.ingestSession({
      ...sessionPayload,
      'events': events.map((e) => e.toJson()).toList(),
    });

    if (ok) {
      UnilitixLogger.d('Flushed ${events.length} events');
    } else {
      await database.insertEvent(pending);
      UnilitixLogger.w('Flush failed — queued for retry');
    }
  }

  Future<void> _retryPending() async {
    final pending = await database.getOldestEvents(20);
    for (final p in pending) {
      if (p.id == null) continue;
      await database.incrementSyncAttempts(p.id!);

      final sessionData = jsonDecode(p.sessionJson) as Map<String, dynamic>;
      final eventsList =
          (jsonDecode(p.eventsJson) as List).cast<Map<String, dynamic>>();

      final ok = await apiClient.ingestSession({
        ...sessionData,
        'events': eventsList,
      });

      if (ok) {
        await database.deleteEventById(p.id!);
        UnilitixLogger.d('Retry succeeded for batch ${p.id}');
      } else {
        await database.incrementRetryCount(p.id!);
        await database.incrementSyncFailedBatches(p.id!);
      }
    }
  }
}
