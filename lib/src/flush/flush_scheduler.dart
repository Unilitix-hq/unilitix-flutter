import 'dart:async';
import 'dart:convert';
import 'dart:math' show min;

import '../capture/snapshot_buffer.dart';
import '../events/event_buffer.dart';
import '../session/session_manager.dart';
import '../storage/event_database.dart';
import '../storage/pending_event.dart';
import '../network/api_client.dart';
import '../network/network_monitor.dart';
import '../performance/performance_monitor.dart';
import '../logger/logger.dart';

/// Schedules periodic event flushing and handles retry logic.
///
/// Session-end flush order (4-stage sequential via [_flushAll]):
///   Stage 1 — POST /v1/ingest/session    (must return true; gates everything)
///   Stage 2 — POST /v1/ingest/events     (must return true; gates Stages 3 and 4)
///   Stage 3 — POST /v1/ingest/snapshots  (best-effort; runs in parallel with Stage 4)
///   Stage 4 — R2 presigned upload        (best-effort; runs in parallel with Stage 3)
class FlushScheduler {
  final int intervalSeconds;
  final EventBuffer buffer;
  final SessionManager sessionManager;
  final EventDatabase database;
  final ApiClient apiClient;
  final NetworkMonitor networkMonitor;
  final PerformanceMonitor performanceMonitor;
  final Future<Map<String, dynamic>?> Function() buildSessionPayload;
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

  /// Periodic flush — drains buffered events and retries pending DB records.
  /// Session POST, snapshots, and screenshots are deferred to session end.
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

  /// Drain pending events on app background — no session POST, no screenshots.
  Future<void> flushEventsOnly() => _flushEvents();

  /// Full 4-stage flush on session end.
  Future<void> flushOnSessionEnd() async {
    if (_flushing) return;
    _flushing = true;
    try {
      await _flushAll();
      await _retryPending(skipPurge: true);
    } finally {
      _flushing = false;
    }
  }

  // ── 4-stage orchestrator ───────────────────────────────────────────────────

  Future<void> _flushAll() async {
    // Stage 1 — session record must exist on backend before anything else.
    final sessionOk = await _flushSession();
    if (!sessionOk) return;

    // Stage 2 — upload buffered events; abort media stages on failure.
    final eventsOk = await _flushEvents();
    if (!eventsOk) return;

    // Stages 3 & 4 — media uploads; best-effort, parallel.
    await Future.wait([
      _flushSnapshots().catchError((_) => false),
      _uploadScreenshots().catchError((_) => false),
    ]);
  }

  // ── Stage 1: session ───────────────────────────────────────────────────────

  Future<bool> _flushSession() async {
    try {
      final sessionPayload = await buildSessionPayload();
      if (sessionPayload == null) return false;
      final sessionId = sessionPayload['sessionId'] as String? ?? '';
      final resp = await apiClient.ingestSessionRaw(sessionPayload);
      if (resp == null) {
        UnilitixLogger.w('Session flush failed — no response');
        return false;
      }
      if (resp.statusCode == 400 || resp.statusCode == 409) {
        // Server rejected this session record — reset so the next cycle
        // generates a fresh session rather than retrying a bad payload.
        UnilitixLogger.w('Session rejected (${resp.statusCode}) — resetting session');
        sessionManager.resetSession();
        return false;
      }
      if (resp.statusCode >= 200 && resp.statusCode < 300) {
        UnilitixLogger.d('Flushed session $sessionId');
        return true;
      }
      UnilitixLogger.w('Session flush failed (${resp.statusCode})');
      return false;
    } catch (e, stack) {
      UnilitixLogger.e('Session flush failed', e, stack);
      return false;
    }
  }

  // ── Stage 2: events ────────────────────────────────────────────────────────

  Future<bool> _flushEvents() async {
    final id = sessionManager.currentSession?.id ??
        sessionManager.lastEndedSession?.id;
    if (id == null) return false;

    final events = buffer.drain();
    if (events.isEmpty) return true;

    for (final event in events) {
      performanceMonitor.enrichEvent(event);
      event.capturedOffline = networkMonitor.isOffline();
      event.networkAtCapture = networkMonitor.currentType();
      final session =
          sessionManager.currentSession ?? sessionManager.lastEndedSession;
      if (event.capturedOffline) {
        session?.offlineEventCount++;
      } else {
        session?.onlineEventCount++;
      }
    }

    final eventsJson = jsonEncode(events.map((e) => e.toJson()).toList());

    if (networkMonitor.isOffline()) {
      await _queueEventsForRetry(id, eventsJson, capturedOffline: true);
      UnilitixLogger.d('Offline — queued ${events.length} events');
      return false;
    }

    try {
      final ok = await apiClient.ingestEvents(
        sessionId: id,
        events: events.map((e) => e.toJson()).toList(),
      );
      if (ok) {
        UnilitixLogger.d('Flushed ${events.length} events');
        return true;
      }
      await _queueEventsForRetry(id, eventsJson, capturedOffline: false);
      UnilitixLogger.w('Event flush failed — queued for retry');
      return false;
    } catch (e, stack) {
      await _queueEventsForRetry(id, eventsJson, capturedOffline: false);
      UnilitixLogger.e('Event flush failed', e, stack);
      return false;
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

  // ── Stage 3: snapshots ─────────────────────────────────────────────────────

  Future<bool> _flushSnapshots() async {
    final buf = snapshotBuffer;
    if (buf == null) return true;

    final id = sessionManager.lastEndedSession?.id ??
        sessionManager.currentSession?.id;
    if (id == null) return false;

    final snapshots = buf.drain();
    if (snapshots.isEmpty) return true;

    try {
      final ok = await apiClient.ingestSnapshots({
        'sessionId': id,
        'snapshots': snapshots,
      });
      if (ok) {
        UnilitixLogger.d('Flushed ${snapshots.length} snapshots');
        return true;
      }
      for (final s in snapshots) { buf.add(s); }
      UnilitixLogger.w('Snapshot flush rejected — re-queued ${snapshots.length}');
      return false;
    } catch (e, stack) {
      for (final s in snapshots) { buf.add(s); }
      UnilitixLogger.e('Snapshot flush failed — re-queued ${snapshots.length}', e, stack);
      return false;
    }
  }

  // ── Stage 4: screenshots ───────────────────────────────────────────────────

  Future<bool> _uploadScreenshots() async {
    if (uploadScreenshotsOnWifiOnly && !networkMonitor.isWifi()) return true;

    final id = sessionManager.lastEndedSession?.id ??
        sessionManager.currentSession?.id;
    if (id == null) return false;

    final pending = await database.getPendingScreenshots(id);
    if (pending.isEmpty) return true;

    // Single batch init with all ordinals.
    final slots = await apiClient.initScreenshotUpload(
      sessionId: id,
      count: pending.length,
      ordinals: pending.map((s) => s.ordinal).toList(),
    );
    if (slots == null) return false;

    // Upload each screenshot to its presigned URL in parallel.
    await Future.wait(
      pending.map((screenshot) async {
        try {
          final slot =
              slots.firstWhere((s) => s.ordinal == screenshot.ordinal);
          await apiClient.uploadScreenshotBytes(
              slot.presignedUrl, screenshot.imageBytes);
          await apiClient.confirmScreenshotUpload(id, screenshot.ordinal);
          await database.deleteScreenshotById(screenshot.id!);
        } catch (e) {
          // leave in DB for retry
        }
      }),
    );
    return true;
  }

  // ── Retry ──────────────────────────────────────────────────────────────────

  Future<void> _retryPending({bool skipPurge = false}) async {
    final pending = await database.getOldestEvents(20);
    for (var i = 0; i < pending.length; i += 5) {
      final chunk = pending.sublist(i, min(i + 5, pending.length));
      await Future.wait(chunk.map(_processBatch));
    }
    if (!skipPurge) {
      await database.deleteEventsOlderThan(
        DateTime.now().subtract(const Duration(days: 7)),
      );
    }
  }

  Future<void> _processBatch(PendingEvent p) async {
    if (p.id == null) return;

    // Drop batches that have failed too many times.
    if (p.retryCount >= 10) {
      await database.deletePendingEvent(p.id!);
      return;
    }

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
      await database.incrementSyncAttempts(p.id!);
      await database.deleteEventById(p.id!);
      UnilitixLogger.d('Retry succeeded for batch ${p.id}');
    } else {
      await database.incrementRetryCount(p.id!);
      await database.incrementSyncFailedBatches(p.id!);
    }
  }
}
