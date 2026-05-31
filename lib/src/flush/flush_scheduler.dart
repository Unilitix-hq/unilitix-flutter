import 'dart:async';
import 'dart:convert';

import '../capture/snapshot_buffer.dart';
import '../events/event_buffer.dart';
import '../session/session_manager.dart';
import '../storage/event_database.dart';
import '../storage/pending_event.dart';
import '../network/api_client.dart';
import '../network/network_monitor.dart';
import '../performance/performance_monitor.dart';
import '../logger/logger.dart';
import '../util/json_util.dart';

/// Schedules periodic event flushing and handles retry logic.
///
/// Two separate flush paths:
///   - Events flush  → POST /v1/ingest/events  (every 30 s or on track())
///   - Session flush → POST /v1/ingest/session (session end only)
class FlushScheduler {
  final int intervalSeconds;
  final EventBuffer buffer;
  final SessionManager sessionManager;
  final EventDatabase database;
  final ApiClient apiClient;
  final NetworkMonitor networkMonitor;
  final PerformanceMonitor performanceMonitor;
  final Future<Map<String, dynamic>> Function() buildSessionPayload;
  final bool uploadScreenshotsOnWifiOnly;
  final SnapshotBuffer? snapshotBuffer;

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
    this.snapshotBuffer,
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

  /// Periodic flush — drains events and retries any pending DB records.
  Future<void> flush() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _flushEvents();
      await _retryPending();
    } finally {
      _flushing = false;
    }
  }

  /// Immediate events-only flush called from track() — bypasses re-entrancy
  /// guard. Safe: drain() is atomic in single-isolate Dart.
  Future<void> flushNow() => _flushEvents();

  /// Called on session end: flush remaining events then send the session record.
  Future<void> flushOnSessionEnd() async {
    await _flushEvents();
    await _flushSession();
  }

  // ── Events path ────────────────────────────────────────────────────────────

  Future<void> _flushEvents() async {
    final events = buffer.drain();
    if (events.isEmpty) return;

    final sessionId = sessionManager.currentSession?.id ?? '';

    for (final event in events) {
      performanceMonitor.enrichEvent(event);
      event.capturedOffline = networkMonitor.isOffline();
      event.networkAtCapture = networkMonitor.currentType();
      if (event.capturedOffline) {
        sessionManager.currentSession?.offlineEventCount++;
      } else {
        sessionManager.currentSession?.onlineEventCount++;
      }
    }

    final eventsJson = jsonEncode(events.map((e) => e.toJson()).toList());

    if (networkMonitor.isOffline()) {
      await _queueEventsForRetry(sessionId, eventsJson, capturedOffline: true);
      UnilitixLogger.d('Offline — queued ${events.length} events');
      return;
    }

    try {
      final ok = await apiClient.ingestEvents(
        sessionId: sessionId,
        events: events.map((e) => e.toJson()).toList(),
      );
      if (ok) {
        UnilitixLogger.d('Flushed ${events.length} events');
        await _flushSnapshots(sessionId);
        await _uploadScreenshots();
      } else {
        await _queueEventsForRetry(sessionId, eventsJson,
            capturedOffline: false);
        UnilitixLogger.w('Event flush failed — queued for retry');
      }
    } catch (e, stack) {
      await _queueEventsForRetry(sessionId, eventsJson, capturedOffline: false);
      UnilitixLogger.e('Event flush failed', e, stack);
    }
  }

  Future<void> _queueEventsForRetry(
    String sessionId,
    String eventsJson, {
    required bool capturedOffline,
  }) async {
    await database.insertEvent(PendingEvent(
      // Store sessionId only so _retryPending can route to ingestEvents.
      sessionJson: jsonEncode({'sessionId': sessionId}),
      eventsJson: eventsJson,
      createdAt: DateTime.now().millisecondsSinceEpoch,
      capturedOffline: capturedOffline,
      networkAtCapture: networkMonitor.currentType(),
    ));
  }

  // ── Session path ───────────────────────────────────────────────────────────

  Future<void> _flushSession() async {
    try {
      final sessionPayload = await buildSessionPayload();
      final sessionId = sessionPayload['sessionId'] as String? ?? '';
      final ok = await apiClient.ingestSession(sessionPayload);
      if (ok) {
        UnilitixLogger.d('Flushed session $sessionId');
      } else {
        UnilitixLogger.w('Session flush failed');
      }
    } catch (e, stack) {
      UnilitixLogger.e('Session flush failed', e, stack);
    }
  }

  // ── Snapshots / screenshots ────────────────────────────────────────────────

  Future<void> _flushSnapshots(String sessionId) async {
    final buf = snapshotBuffer;
    if (buf == null) return;
    final snapshots = buf.drain();
    if (snapshots.isEmpty) return;
    try {
      final ok = await apiClient.ingestSnapshots({
        'sessionId': sessionId,
        'snapshots': snapshots,
      });
      if (ok) {
        UnilitixLogger.d('Flushed ${snapshots.length} snapshots');
      } else {
        UnilitixLogger.w('Snapshot flush rejected — dropping batch');
      }
    } catch (e, stack) {
      UnilitixLogger.e('Snapshot flush failed', e, stack);
    }
  }

  Future<void> _uploadScreenshots() async {
    if (uploadScreenshotsOnWifiOnly && !networkMonitor.isWifi()) {
      UnilitixLogger.d('Skipping screenshots — not on WiFi');
      return;
    }
    final sessionId = sessionManager.currentSession?.id;
    if (sessionId == null) return;

    final all = await database.getPendingScreenshots(sessionId);
    if (all.isEmpty) return;
    final screenshots = all.take(200).toList(); // backend validates 1–200

    for (final s in screenshots) {
      if (s.id == null) continue;
      try {
        final presignedUrl = await apiClient.initScreenshotUpload({
          'sessionId': sessionId,
          'ordinal': s.ordinal,
          'screenName': s.screenName,
          'viewportWidth': s.viewportWidth,
          'viewportHeight': s.viewportHeight,
          'capturedAt': s.capturedAt,
        });
        if (presignedUrl == null) continue;

        final uploaded =
            await apiClient.uploadScreenshotBytes(presignedUrl, s.imageBytes);
        if (!uploaded) continue;

        final confirmed = await apiClient.confirmScreenshotUpload({
          'sessionId': sessionId,
          'ordinal': s.ordinal,
          'capturedAt': JsonUtil.toRfc3339(s.capturedAt),
        });
        if (confirmed) await database.deleteScreenshotById(s.id!);
      } catch (e) {
        UnilitixLogger.e(
            'Screenshot upload failed for ordinal ${s.ordinal}', e);
      }
    }
  }

  // ── Retry ──────────────────────────────────────────────────────────────────

  Future<void> _retryPending() async {
    final pending = await database.getOldestEvents(20);
    for (final p in pending) {
      if (p.id == null) continue;
      await database.incrementSyncAttempts(p.id!);

      final sessionData = jsonDecode(p.sessionJson) as Map<String, dynamic>;
      final eventsList =
          (jsonDecode(p.eventsJson) as List).cast<Map<String, dynamic>>();

      // Events-only records have exactly {sessionId} in session_json.
      // Full-session records (legacy) have the complete session payload.
      final isEventsOnly =
          sessionData.length == 1 && sessionData.containsKey('sessionId');

      final bool ok;
      if (isEventsOnly) {
        final sid = sessionData['sessionId'] as String? ?? '';
        ok = await apiClient.ingestEvents(
          sessionId: sid,
          events: eventsList,
        );
      } else {
        sessionData['syncAttempts'] = p.syncAttempts;
        sessionData['syncFailedBatches'] = p.syncFailedBatches;
        ok = await apiClient.ingestSession({
          ...sessionData,
          'events': eventsList,
        });
      }

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
