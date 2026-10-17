import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../capture/snapshot_buffer.dart';
import '../events/event_buffer.dart';
import '../session/session.dart';
import '../session/session_manager.dart';
import '../storage/event_database.dart';
import '../storage/pending_event.dart';
import '../network/api_client.dart';
import '../network/network_monitor.dart';
import '../network/retry_policy.dart';
import '../performance/performance_monitor.dart';
import '../logger/logger.dart';

/// Schedules periodic event flushing and owns the retry/backoff state.
///
/// Periodic flush — runs every [intervalSeconds].
/// Executes all 4 stages:
/// 1. Session upsert (skipped when nothing in the record has changed)
/// 2. Events batch
/// 3. Snapshots (background, best-effort)
/// 4. Screenshots upload (background, best-effort)
/// Also retries previously failed batches, oldest first, one at a time.
///
/// **One attempt per cycle.** Every request is made once. A transient
/// failure (no response, 5xx, 429) opens a backoff window — exponential with
/// jitter, or exactly what a `Retry-After` header asks for — during which
/// every cycle returns immediately and data accumulates in the on-device
/// queue. A permanent rejection (other 4xx) drops that batch: the same bytes
/// can never succeed and would otherwise be re-sent for a week. A 401/403
/// pauses uploads until the next launch.
///
/// A [_flushing] guard prevents concurrent runs.
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

  /// Clock, injectable for tests.
  final DateTime Function() now;

  Timer? _timer;
  bool _flushing = false;
  bool _disposed = false;

  /// Set once the API rejects the key (401/403). A revoked or wrong key never
  /// recovers on its own, so uploads stop for the rest of the process instead
  /// of retrying every cycle; data stays in the on-device queue and is sent on
  /// a later launch once the key is fixed.
  bool _authRejected = false;

  /// True after the API rejected the SDK key; uploads are paused until restart.
  bool get authRejected => _authRejected;

  /// 401 and 403 mean the key itself is wrong, not that the request was.
  static bool isAuthFailure(int status) => status == 401 || status == 403;

  // ── Backoff ────────────────────────────────────────────────────────────────

  int _consecutiveFailures = 0;
  DateTime? _backoffUntil;

  /// Number of consecutive transient failures; resets on the first success.
  @visibleForTesting
  int get consecutiveFailures => _consecutiveFailures;

  /// End of the current backoff window, or null when uploads may proceed.
  @visibleForTesting
  DateTime? get backoffUntil => _backoffUntil;

  /// True while a backoff window is open.
  bool get inBackoff {
    final until = _backoffUntil;
    if (until == null) return false;
    if (now().isBefore(until)) return true;
    _backoffUntil = null;
    return false;
  }

  /// Records the outcome of a request and updates the backoff/auth state.
  /// Returns the result for chaining.
  ApiResult _note(ApiResult r, String what) {
    if (r.ok) {
      if (_consecutiveFailures > 0) {
        UnilitixLogger.d('$what succeeded — backoff cleared');
      }
      _consecutiveFailures = 0;
      _backoffUntil = null;
      return r;
    }
    if (r.isAuthFailure) {
      if (!_authRejected) {
        _authRejected = true;
        UnilitixLogger.e(
          'Unilitix API key rejected (${r.status}). Uploads are paused '
          'until the app restarts — check the key passed to Unilitix.init(). '
          'Captured data stays on-device and is sent once the key is valid.',
        );
      }
      return r;
    }
    if (r.retryable) {
      final delay = RetryPolicy.delayFor(
        _consecutiveFailures,
        retryAfterSeconds: r.retryAfterSeconds,
      );
      _consecutiveFailures++;
      _backoffUntil = now().add(delay);
      UnilitixLogger.w('$what: ${r.describe()} — backing off '
          '${delay.inSeconds}s (failure #$_consecutiveFailures)');
      return r;
    }
    // Rejected (4xx): no backoff — the server is healthy, this payload is not.
    UnilitixLogger.e('$what rejected by the API (${r.describe()}) — dropped');
    return r;
  }

  /// Serialises every event upload: periodic flush, background drain and
  /// retries all go through this one gate, so at most one events request is
  /// in flight and batches leave in capture order.
  Future<void> _uploadGate = Future.value();

  Future<T> _serialized<T>(Future<T> Function() work) {
    final completer = Completer<T>();
    _uploadGate = _uploadGate.then((_) async {
      try {
        completer.complete(await work());
      } catch (e, st) {
        completer.completeError(e, st);
      }
    });
    return completer.future;
  }

  /// Consent gates. [isOptedOut] (consent denied) means nothing is collected
  /// or uploaded and local stubs are deleted. [canUpload] is false while
  /// consent is denied *or pending*: every upload entry point returns without
  /// a network call, but what was captured stays in the on-device queue so it
  /// can be sent once consent is granted.
  final bool Function() isOptedOut;
  final bool Function() canUpload;

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
    bool Function()? isOptedOut,
    bool Function()? canUpload,
    DateTime Function()? now,
  })  : isOptedOut = isOptedOut ?? _neverOptedOut,
        canUpload = canUpload ?? _alwaysUpload,
        now = now ?? DateTime.now;

  static bool _neverOptedOut() => false;
  static bool _alwaysUpload() => true;

  void start() {
    _timer = Timer.periodic(
      Duration(seconds: intervalSeconds),
      (_) => flush(),
    );
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _disposed = true;
  }

  /// True when no upload may happen right now, for any reason.
  bool get _paused => !canUpload() || _authRejected || inBackoff;

  /// Periodic flush — runs all 4 stages every cycle.
  /// Stages 3+4 (snapshots/screenshots) are best-effort and run in background.
  Future<void> flush() async {
    if (_paused) return;
    if (_flushing) return;
    _flushing = true;
    try {
      // Stage 1: flush session
      final sessionOk = await _flushSession();
      if (!sessionOk) return;

      // Stage 2: flush events
      final eventsOk = await _flushEvents();
      if (!eventsOk) return;

      // Stages 3+4: incremental media upload
      unawaited(Future.wait([
        _flushSnapshots().catchError((_) => false),
        _uploadScreenshots().catchError((_) => false),
      ]));

      // Retry any previously failed events
      await _retryPending();
    } catch (e, st) {
      // A bug in the SDK's own flush path must never reach the host app.
      UnilitixLogger.e('flush failed', e, st);
    } finally {
      _flushing = false;
    }
  }

  /// Drain pending events on app background — no session POST, no screenshots.
  Future<void> flushEventsOnly() async {
    if (_paused) return;
    try {
      await _flushEvents();
    } catch (e, st) {
      UnilitixLogger.e('flushEventsOnly failed', e, st);
    }
  }

  /// Flush a crash as soon as it is recorded. The event is already in the
  /// write-ahead log, so this is an opportunistic upload bounded by [timeout];
  /// if the process dies first, the next launch recovers and uploads it.
  /// Runs even inside a backoff window: it is one request, and a crash is the
  /// one event worth that request.
  Future<void> flushCrash(
      {Duration timeout = const Duration(seconds: 3)}) async {
    if (!canUpload() || _authRejected) return;
    try {
      await database.walFlush();
      await _flushEvents().timeout(timeout);
      await _retryPending(skipPurge: true, limit: 1).timeout(timeout);
    } catch (_) {
      // Timeout or transport error: the WAL and pending queue hold the event.
    }
  }

  /// Full 4-stage flush on session end.
  Future<void> flushOnSessionEnd(Session session) async {
    // Wait for any in-progress periodic flush to complete before running session-end flush.
    // Timeout after 3s — a stalled periodic flush may still be running. In that
    // case we proceed anyway and both flushes run concurrently. Data integrity
    // is preserved since each stage is idempotent.
    int waited = 0;
    while (_flushing && waited < 3000) {
      await Future.delayed(const Duration(milliseconds: 100));
      waited += 100;
    }

    if (_disposed || _authRejected) return;
    if (isOptedOut()) {
      // Opted out: nothing is uploaded and the local stub must not survive to be
      // recovered (and uploaded) on the next launch.
      await database.deletePendingSession(session.id);
      return;
    }
    if (!canUpload() || inBackoff) {
      // Consent pending or server backing off: keep the stub and the queue.
      return;
    }
    _flushing = true;
    try {
      final sessionDelivered = await _flushAll(session: session);
      await _retryPending(skipPurge: true);
      // Only delete the pending stub once the session record is confirmed on the
      // server. If delivery failed the stub survives for recovery on next launch.
      if (sessionDelivered) {
        await database.deletePendingSession(session.id);
      }
    } catch (e, st) {
      UnilitixLogger.e('flushOnSessionEnd failed', e, st);
    } finally {
      _flushing = false;
    }
  }

  // ── 4-stage orchestrator ───────────────────────────────────────────────────

  // Returns true if the session record was successfully delivered to the server
  // (stage 1 succeeded). Events and media have their own retry paths.
  Future<bool> _flushAll({Session? session}) async {
    // Stage 1 — session record must exist on backend before anything else.
    // The end-of-session record always goes out (endedAt changed).
    final sessionOk = await _flushSession(force: true);
    if (!sessionOk) return false;

    // Stage 2 — upload buffered events; abort media stages on failure.
    final eventsOk = await _flushEvents();
    if (!eventsOk) return true; // session delivered — stub can be cleared

    // Stages 3 & 4 — media uploads; best-effort, parallel.
    await Future.wait([
      _flushSnapshots().catchError((_) => false),
      _uploadScreenshots().catchError((_) => false),
    ]);
    return true;
  }

  // ── Stage 1: session ───────────────────────────────────────────────────────

  /// Session id the server has acknowledged, with the fingerprint of the
  /// record it holds and when it was sent. The periodic cycle re-sends the
  /// record only when a non-volatile field changed or [_sessionRefresh] has
  /// elapsed (so durations still advance on the dashboard), instead of one
  /// identical upsert every 30 s for the life of the session.
  String? _ackedSessionId;
  String? _ackedFingerprint;
  DateTime? _ackedAt;

  /// A record the server rejected with a 4xx; not re-sent until it changes.
  String? _rejectedFingerprint;

  static const _sessionRefresh = Duration(minutes: 5);

  /// Fields that change on every build and must not by themselves trigger an
  /// upsert.
  static const _volatileKeys = {
    'foregroundTimeMs',
    'backgroundTimeMs',
    'durationMs',
    'batteryLevel',
    'offlineEventCount',
    'onlineEventCount',
  };

  @visibleForTesting
  static String sessionFingerprint(Map<String, dynamic> payload) {
    final keys = payload.keys.where((k) => !_volatileKeys.contains(k)).toList()
      ..sort();
    final buf = StringBuffer();
    for (final k in keys) {
      buf
        ..write(k)
        ..write('=')
        ..write(jsonEncode(payload[k]))
        ..write(';');
    }
    return buf.toString();
  }

  Future<bool> _flushSession({bool force = false}) async {
    try {
      final sessionPayload = await buildSessionPayload();
      if (sessionPayload == null) return false;
      final sessionId = sessionPayload['sessionId'] as String? ?? '';
      final fp = sessionFingerprint(sessionPayload);

      if (!force && _ackedSessionId == sessionId && _ackedFingerprint == fp) {
        final sentAt = _ackedAt;
        if (sentAt != null && now().difference(sentAt) < _sessionRefresh) {
          return true; // nothing new to say about this session
        }
      }
      if (!force && _rejectedFingerprint == fp) {
        return false; // would be the same 4xx again
      }

      final raw = await apiClient.ingestSession(sessionPayload);
      // 409: session already exists on the server — that is an ack too, so
      // keep it away from _note (which would log a 4xx as a dropped batch).
      final resp =
          raw.status == 409 ? raw : _note(raw, 'Session upsert ($sessionId)');
      if (resp.ok || resp.status == 409) {
        _consecutiveFailures = 0;
        _backoffUntil = null;
        _ackedSessionId = sessionId;
        _ackedFingerprint = fp;
        _ackedAt = now();
        _rejectedFingerprint = null;
        UnilitixLogger.d('Flushed session $sessionId');
        return true;
      }
      if (resp.rejected) {
        // Pre-2.1.1 the SDK reset the session here, which split one visit
        // into many and lost the events already attributed to it. Keep the
        // session; stop re-sending the identical record; surface the reason.
        _rejectedFingerprint = fp;
        UnilitixLogger.e('Session record rejected (${resp.status}): '
            '${resp.body.length > 200 ? resp.body.substring(0, 200) : resp.body}');
        return false;
      }
      return false; // transient or auth — _note already handled it
    } catch (e, stack) {
      UnilitixLogger.e('Session flush failed', e, stack);
      return false;
    }
  }

  // ── Stage 2: events ────────────────────────────────────────────────────────

  Future<bool> _flushEvents() => _serialized(_flushEventsUnlocked);

  Future<bool> _flushEventsUnlocked() async {
    final id = sessionManager.currentSession?.id ??
        sessionManager.lastEndedSession?.id;
    if (id == null) return false;

    final events = buffer.drain();
    if (events.isEmpty) return true;
    final eventIds = events.map((e) => e.id).toList(growable: false);

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

    final eventsJson = events.map((e) => e.toJson()).toList();
    final eventsEncoded = jsonEncode(eventsJson);

    // Make sure the write-ahead rows for these events are on disk before we
    // either delete them (success) or fold them into a retry batch.
    await database.walFlush();

    // Once a batch is in the pending-retry table it is durable there, so its
    // write-ahead rows can go. If queuing fails the events return to memory and
    // their WAL rows stay as the only durable copy.
    Future<bool> queueOrRestore({required bool capturedOffline}) async {
      final queued = await _queueEventsForRetry(id, eventsEncoded,
          eventCount: events.length, capturedOffline: capturedOffline);
      if (queued) {
        await database.walDelete(eventIds);
        return true;
      }
      for (final event in events) {
        buffer.emit(event);
      }
      UnilitixLogger.w(
          'Failed to queue ${events.length} events for retry — restored to buffer');
      return false;
    }

    if (networkMonitor.isOffline()) {
      if (await queueOrRestore(capturedOffline: true)) {
        UnilitixLogger.d('Offline — queued ${events.length} events');
      }
      return false;
    }

    try {
      final resp = _note(
        await apiClient.ingestEvents(sessionId: id, events: eventsJson),
        'Events batch (${events.length})',
      );
      if (resp.ok) {
        await database.walDelete(eventIds);
        UnilitixLogger.d('Flushed ${events.length} events');
        return true;
      }
      if (resp.rejected) {
        // The server will never accept these bytes; keeping them would
        // re-send the same 4xx every cycle for seven days.
        await database.walDelete(eventIds);
        return false;
      }
      if (await queueOrRestore(capturedOffline: false)) {
        UnilitixLogger.w('Event flush failed — queued for retry');
      }
      return false;
    } catch (e, stack) {
      await queueOrRestore(capturedOffline: false);
      UnilitixLogger.e('Event flush failed', e, stack);
      return false;
    }
  }

  Future<bool> _queueEventsForRetry(
    String sessionId,
    String eventsJson, {
    required int eventCount,
    required bool capturedOffline,
  }) async {
    try {
      await database.insertEvent(PendingEvent(
        // Store sessionId only so _retryPending can route to ingestEvents.
        sessionJson: jsonEncode({'sessionId': sessionId}),
        eventsJson: eventsJson,
        eventCount: eventCount,
        createdAt: now().millisecondsSinceEpoch,
        capturedOffline: capturedOffline,
        networkAtCapture: networkMonitor.currentType(),
      ));
      return true;
    } catch (e, stack) {
      UnilitixLogger.e('Failed to persist events to DB', e, stack);
      return false;
    }
  }

  // ── Stage 3: snapshots ─────────────────────────────────────────────────────

  Future<bool> _flushSnapshots() async {
    final buf = snapshotBuffer;
    if (buf == null) return true;

    final id = sessionManager.currentSession?.id ??
        sessionManager.lastEndedSession?.id;
    if (id == null) return false;

    final snapshots = buf.drain();
    if (snapshots.isEmpty) return true;

    try {
      final resp = _note(
        await apiClient.ingestSnapshots({
          'sessionId': id,
          'snapshots': snapshots,
        }),
        'Snapshots (${snapshots.length})',
      );
      if (resp.ok) {
        UnilitixLogger.d('Flushed ${snapshots.length} snapshots');
        return true;
      }
      if (resp.rejected) return false; // dropped; replay is best-effort
      for (final s in snapshots) {
        buf.add(s);
      }
      UnilitixLogger.w('Snapshot flush failed — re-queued ${snapshots.length}');
      return false;
    } catch (e, stack) {
      for (final s in snapshots) {
        buf.add(s);
      }
      UnilitixLogger.e(
          'Snapshot flush failed — re-queued ${snapshots.length}', e, stack);
      return false;
    }
  }

  // ── Stage 4: screenshots ───────────────────────────────────────────────────

  Future<bool> _uploadScreenshots() async {
    if (uploadScreenshotsOnWifiOnly && !networkMonitor.isWifi()) return true;

    final id = sessionManager.currentSession?.id ??
        sessionManager.lastEndedSession?.id;
    if (id == null) return false;

    final pending = await database.getPendingScreenshots(id);
    if (pending.isEmpty) return true;

    // Single batch init with all ordinals.
    final init = await apiClient.initScreenshotUpload(
      sessionId: id,
      count: pending.length,
      ordinals: pending.map((s) => s.ordinal).toList(),
    );
    _note(init.result, 'Screenshot init (${pending.length})');
    final slots = init.slots;
    if (slots == null) {
      if (init.result.rejected) {
        // The server refuses frames for this session; stop storing them.
        for (final s in pending) {
          await database.deleteScreenshotById(s.id!);
        }
      }
      return false;
    }

    // Upload screenshots in batches of 3 — avoids saturating the connection
    // on large sessions which causes request timeouts and white frames in replay.
    const batchSize = 3;
    for (int i = 0; i < pending.length; i += batchSize) {
      if (inBackoff || _authRejected) return false;
      final batch = pending.skip(i).take(batchSize).toList();
      await Future.wait(batch.map((screenshot) async {
        try {
          final matches = slots.where((s) => s.ordinal == screenshot.ordinal);
          if (matches.isEmpty) {
            UnilitixLogger.w(
                'No presigned slot for ordinal ${screenshot.ordinal} — skipping');
            return;
          }
          final slot = matches.first;

          final uploaded = await apiClient.uploadScreenshotBytes(
            slot.presignedUrl,
            screenshot.imageBytes,
          );

          if (!uploaded) {
            UnilitixLogger.w(
              'Screenshot upload failed for ordinal ${screenshot.ordinal} '
              '— leaving in DB for retry',
            );
            return; // skip confirm and delete, leave in DB
          }

          final confirm = _note(
            await apiClient.confirmScreenshotUpload(id, screenshot),
            'Screenshot confirm #${screenshot.ordinal}',
          );
          if (confirm.ok || confirm.rejected) {
            await database.deleteScreenshotById(screenshot.id!);
          }
        } catch (e, stack) {
          UnilitixLogger.e(
            'Screenshot upload error for ordinal ${screenshot.ordinal}',
            e,
            stack,
          );
          // leave in DB for retry — do NOT delete
        }
      }));
    }
    return true;
  }

  // ── Retry ──────────────────────────────────────────────────────────────────

  Future<void> _retryPending({bool skipPurge = false, int limit = 20}) async {
    if (_paused) return;
    final pending = await database.getOldestEvents(limit);
    // Strictly one batch in flight, oldest first: concurrent retries reorder
    // events on the server and multiply load on a degraded link. The first
    // transient failure ends the pass — the server is struggling, and every
    // later batch would meet the same fate.
    for (final p in pending) {
      if (_paused) break;
      final keepGoing = await _serialized(() => _processBatch(p));
      if (!keepGoing) break;
    }
    if (!skipPurge) {
      await database.deleteEventsOlderThan(
        now().subtract(EventDatabase.maxQueueAge),
      );
    }
  }

  /// Sends one queued batch. Returns false when the pass should stop
  /// (transient failure, auth failure).
  Future<bool> _processBatch(PendingEvent p) async {
    final rowId = p.id;
    if (rowId == null) return true;

    // Drop batches that have failed too many times.
    if (p.retryCount >= 10) {
      await database.deletePendingEvent(rowId);
      return true;
    }

    final Map<String, dynamic> sessionData;
    final List<Map<String, dynamic>> eventsList;
    try {
      sessionData = jsonDecode(p.sessionJson) as Map<String, dynamic>;
      eventsList =
          (jsonDecode(p.eventsJson) as List).cast<Map<String, dynamic>>();
    } catch (e) {
      // Corrupt row (truncated write, schema drift): it can never be sent.
      UnilitixLogger.w(
          'Dropping corrupt queued batch $rowId: ${e.runtimeType}');
      await database.deletePendingEvent(rowId);
      return true;
    }

    try {
      // Events-only records have exactly {sessionId} in session_json.
      // Full-session records (legacy) have the complete session payload.
      final isEventsOnly =
          sessionData.length == 1 && sessionData.containsKey('sessionId');

      final ApiResult resp;
      if (isEventsOnly) {
        final sid = sessionData['sessionId'] as String? ?? '';
        resp = await apiClient.ingestEvents(sessionId: sid, events: eventsList);
      } else {
        sessionData['syncAttempts'] = p.syncAttempts;
        sessionData['syncFailedBatches'] = p.syncFailedBatches;
        resp = await apiClient.ingestSession({
          ...sessionData,
          'events': eventsList,
        });
      }
      _note(resp, 'Retry of batch $rowId');

      if (resp.ok) {
        await database.incrementSyncAttempts(rowId);
        await database.deleteEventById(rowId);
        UnilitixLogger.d('Retry succeeded for batch $rowId');
        return true;
      }
      if (resp.rejected) {
        await database.deleteEventById(rowId);
        return true;
      }
      await database.incrementRetryCount(rowId);
      await database.incrementSyncFailedBatches(rowId);
      return false;
    } catch (e, stack) {
      UnilitixLogger.e('Retry of batch $rowId failed', e, stack);
      return false;
    }
  }
}
