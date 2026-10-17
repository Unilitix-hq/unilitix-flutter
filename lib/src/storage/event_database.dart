import 'dart:async';
import 'package:sqflite/sqflite.dart';

import 'pending_event.dart';
import 'pending_screenshot.dart';
import '../logger/logger.dart';

/// sqflite-backed persistent queue for events and screenshots.
///
/// The retry queue (`pending_events`) is bounded three ways so a device that
/// is offline for weeks, or an app that emits events in a loop, can never
/// fill the user's storage: by events ([maxOfflineEvents]), by bytes
/// ([maxQueueBytes]) and by age ([maxQueueAge]). Oldest batches are evicted
/// first.
class EventDatabase {
  static const _dbName = 'unilitix_events.db';
  static const _version = 5;
  static const _tWal = 'wal_events';

  /// Upper bound on write-ahead rows kept on disk; oldest are evicted beyond it.
  static const _maxWalRows = 5000;
  static const _tEvents = 'pending_events';
  static const _tScreenshots = 'pending_screenshots';
  static const _tSessions = 'pending_sessions';

  /// Queued batches older than this are purged on every flush cycle.
  static const Duration maxQueueAge = Duration(days: 7);

  /// Cap on queued events (sum of `event_count` over the retry queue).
  final int maxOfflineEvents;

  /// Cap on queued bytes (sum of `events_json` length over the retry queue).
  final int maxQueueBytes;
  final int maxScreenshotsPerSession;

  /// Overrides the database location (tests pass `inMemoryDatabasePath`).
  final String? dbPath;

  Database? _db;
  bool _available = true;

  EventDatabase({
    required this.maxOfflineEvents,
    required this.maxScreenshotsPerSession,
    this.maxQueueBytes = 5 * 1024 * 1024,
    this.dbPath,
  });

  bool get isAvailable => _available && _db != null;

  Future<void> open() async {
    try {
      final path = dbPath ?? '${await getDatabasesPath()}/$_dbName';
      _db = await openDatabase(
        path,
        version: _version,
        onCreate: _create,
        onUpgrade: _onUpgrade,
      );
    } catch (e) {
      UnilitixLogger.w(
          'Local storage unavailable — events will not persist across restarts');
      _available = false;
    }
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tEvents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_json TEXT NOT NULL,
        events_json TEXT NOT NULL,
        event_count INTEGER DEFAULT 0,
        created_at INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        captured_offline INTEGER DEFAULT 0,
        network_at_capture TEXT DEFAULT 'UNKNOWN',
        sync_attempts INTEGER DEFAULT 0,
        sync_failed_batches INTEGER DEFAULT 0
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_events_created_at ON $_tEvents(created_at)',
    );
    await db.execute('''
      CREATE TABLE $_tSessions (
        id TEXT PRIMARY KEY,
        session_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'pending'
      )
    ''');
    await db.execute('''
      CREATE TABLE $_tScreenshots (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        ordinal INTEGER NOT NULL,
        screen_name TEXT NOT NULL,
        viewport_width INTEGER NOT NULL,
        viewport_height INTEGER NOT NULL,
        captured_at INTEGER NOT NULL,
        image_bytes BLOB NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await _createWal(db);
  }

  /// Write-ahead log: one row per emitted event, written before the event
  /// leaves memory and deleted once the server acknowledges it (or once it has
  /// been folded into a pending retry batch). On the next launch any rows left
  /// here belong to a process that died before flushing; they are turned into
  /// retry batches by [recoverWalToPending].
  Future<void> _createWal(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS $_tWal (
        id TEXT PRIMARY KEY,
        session_id TEXT NOT NULL,
        seq INTEGER,
        event_json TEXT NOT NULL,
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_wal_session ON $_tWal(session_id, seq)',
    );
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_events_created_at ON $_tEvents(created_at)',
      );
    }
    if (oldVersion < 3) {
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tSessions (
          id TEXT PRIMARY KEY,
          session_json TEXT NOT NULL,
          created_at INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'pending'
        )
      ''');
    }
    if (oldVersion < 4) {
      // v3 upgrades never created the screenshots table (only fresh installs
      // did); create it here so upgraded installs can store screenshots too.
      await db.execute('''
        CREATE TABLE IF NOT EXISTS $_tScreenshots (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          session_id TEXT NOT NULL,
          ordinal INTEGER NOT NULL,
          screen_name TEXT NOT NULL,
          viewport_width INTEGER NOT NULL,
          viewport_height INTEGER NOT NULL,
          captured_at INTEGER NOT NULL,
          image_bytes BLOB NOT NULL,
          created_at INTEGER NOT NULL
        )
      ''');
      await _createWal(db);
    }
    if (oldVersion < 5) {
      await db.execute(
          'ALTER TABLE $_tEvents ADD COLUMN event_count INTEGER DEFAULT 0');
    }
  }

  // ── Write-ahead log ────────────────────────────────────────────────────────

  /// Rows waiting to be written to the WAL in one batch.
  final List<Map<String, Object?>> _walPending = [];
  Timer? _walTimer;
  Future<void>? _walInFlight;

  /// How long emitted events are held in memory before the batch is written.
  /// A tap, the navigation it causes and the first scroll on the new screen
  /// arrive within this window and become one disk write instead of three.
  static const walCoalesceWindow = Duration(milliseconds: 100);

  /// Queues an emitted event for the write-ahead log. Rows are written in
  /// batches ([walCoalesceWindow]); [walFlush] forces the write — the flush
  /// scheduler calls it before uploading, and the crash path calls it so a
  /// crash row is on disk before the opportunistic upload. Best-effort: a
  /// storage failure must never break event emission.
  void walInsert(String sessionId, String eventId, int? seq, String eventJson) {
    if (!_available) return;
    _walPending.add({
      'id': eventId,
      'session_id': sessionId,
      'seq': seq,
      'event_json': eventJson,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
    _walTimer ??= Timer(walCoalesceWindow, () => walFlush());
  }

  /// Writes every queued WAL row. Safe to call at any time; concurrent calls
  /// share one write.
  Future<void> walFlush() async {
    _walTimer?.cancel();
    _walTimer = null;
    final inFlight = _walInFlight;
    if (inFlight != null) await inFlight;
    if (_walPending.isEmpty || !_available) return;
    final rows = List<Map<String, Object?>>.from(_walPending);
    _walPending.clear();
    final write = _writeWal(rows);
    _walInFlight = write;
    try {
      await write;
    } finally {
      if (identical(_walInFlight, write)) _walInFlight = null;
    }
  }

  Future<void> _writeWal(List<Map<String, Object?>> rows) async {
    try {
      final batch = _db!.batch();
      for (final r in rows) {
        batch.insert(_tWal, r, conflictAlgorithm: ConflictAlgorithm.ignore);
      }
      await batch.commit(noResult: true);
    } catch (e) {
      UnilitixLogger.w('WAL insert failed: $e');
    }
  }

  /// Number of rows not yet written to the WAL table.
  int get walPendingCount => _walPending.length;

  /// Removes acknowledged (or re-queued) events from the write-ahead log.
  Future<void> walDelete(List<String> eventIds) async {
    if (!_available || eventIds.isEmpty) return;
    await walFlush(); // never delete ahead of a queued insert
    try {
      final batch = _db!.batch();
      for (final id in eventIds) {
        batch.delete(_tWal, where: 'id = ?', whereArgs: [id]);
      }
      await batch.commit(noResult: true);
    } catch (e) {
      UnilitixLogger.w('WAL delete failed: $e');
    }
  }

  Future<int> walCount() async {
    if (!_available) return 0;
    final r = await _db!.rawQuery('SELECT COUNT(*) AS c FROM $_tWal');
    return (r.first['c'] as int?) ?? 0;
  }

  /// Converts every row still in the write-ahead log into pending retry
  /// batches (one per session, in seq order) and clears the log. Called once
  /// at startup: anything here was emitted by a process that never flushed it.
  /// Returns the number of events recovered.
  Future<int> recoverWalToPending() async {
    if (!_available) return 0;
    try {
      await walFlush();
      // Evict beyond the cap first so a runaway session can't fill the disk.
      final count = await walCount();
      if (count > _maxWalRows) {
        await _db!.rawDelete(
          'DELETE FROM $_tWal WHERE id IN (SELECT id FROM $_tWal ORDER BY created_at ASC LIMIT ?)',
          [count - _maxWalRows],
        );
      }
      final rows = await _db!
          .query(_tWal, orderBy: 'session_id ASC, seq ASC, created_at ASC');
      if (rows.isEmpty) return 0;

      final bySession = <String, List<String>>{};
      for (final r in rows) {
        bySession
            .putIfAbsent(r['session_id'] as String, () => [])
            .add(r['event_json'] as String);
      }
      for (final entry in bySession.entries) {
        await insertEvent(PendingEvent(
          sessionJson: '{"sessionId":"${entry.key}"}',
          eventsJson: '[${entry.value.join(',')}]',
          eventCount: entry.value.length,
          createdAt: DateTime.now().millisecondsSinceEpoch,
        ));
      }
      await _db!.delete(_tWal);
      return rows.length;
    } catch (e) {
      UnilitixLogger.w('WAL recovery failed: $e');
      return 0;
    }
  }

  /// Queues a batch for retry, then evicts the oldest batches until the queue
  /// is within [maxOfflineEvents] events and [maxQueueBytes] bytes. The new
  /// batch is inserted first so a single oversized batch is itself evicted
  /// rather than blocking the queue.
  Future<void> insertEvent(PendingEvent event) async {
    if (!_available) return;
    await _db!.transaction((txn) async {
      await txn.insert(_tEvents, event.toMap());
      for (var guard = 0; guard < 1000; guard++) {
        final r = await txn.rawQuery('SELECT COUNT(*) AS c, '
            'COALESCE(SUM(event_count), 0) AS n, '
            'COALESCE(SUM(LENGTH(events_json)), 0) AS b FROM $_tEvents');
        final rows = (r.first['c'] as int?) ?? 0;
        final events = (r.first['n'] as int?) ?? 0;
        final bytes = (r.first['b'] as int?) ?? 0;
        if (rows <= 1 ||
            (events <= maxOfflineEvents && bytes <= maxQueueBytes)) {
          break;
        }
        await txn.rawDelete(
          'DELETE FROM $_tEvents WHERE id = '
          '(SELECT id FROM $_tEvents ORDER BY created_at ASC, id ASC LIMIT 1)',
        );
      }
    });
  }

  /// Totals over the retry queue: rows, events and bytes.
  Future<({int rows, int events, int bytes})> queueStats() async {
    if (!_available) return (rows: 0, events: 0, bytes: 0);
    final r = await _db!.rawQuery('SELECT COUNT(*) AS c, '
        'COALESCE(SUM(event_count), 0) AS n, '
        'COALESCE(SUM(LENGTH(events_json)), 0) AS b FROM $_tEvents');
    return (
      rows: (r.first['c'] as int?) ?? 0,
      events: (r.first['n'] as int?) ?? 0,
      bytes: (r.first['b'] as int?) ?? 0,
    );
  }

  Future<List<PendingEvent>> getOldestEvents(int limit) async {
    if (!_available) return [];
    final rows = await _db!.query(
      _tEvents,
      where: 'retry_count < 10',
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(PendingEvent.fromMap).toList();
  }

  Future<void> deleteEventById(int id) async {
    if (!_available) return;
    await _db!.delete(_tEvents, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deletePendingEvent(int id) => deleteEventById(id);

  Future<void> deleteEventsOlderThan(DateTime cutoff) async {
    if (!_available) return;
    await _db!.rawDelete(
      'DELETE FROM $_tEvents WHERE created_at < ?',
      [cutoff.millisecondsSinceEpoch],
    );
  }

  Future<void> incrementRetryCount(int id) async {
    if (!_available) return;
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> incrementSyncAttempts(int id) async {
    if (!_available) return;
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET sync_attempts = sync_attempts + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> incrementSyncFailedBatches(int id) async {
    if (!_available) return;
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET sync_failed_batches = sync_failed_batches + 1 WHERE id = ?',
      [id],
    );
  }

  Future<int> eventCount() async {
    if (!_available) return 0;
    final result = await _db!.rawQuery('SELECT COUNT(*) as c FROM $_tEvents');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> deleteOldestEvents(int count) async {
    if (!_available) return;
    await _db!.rawDelete(
      'DELETE FROM $_tEvents WHERE id IN '
      '(SELECT id FROM $_tEvents ORDER BY created_at ASC LIMIT ?)',
      [count],
    );
  }

  Future<int> screenshotCount() async {
    if (!_available) return 0;
    final result =
        await _db!.rawQuery('SELECT COUNT(*) as c FROM $_tScreenshots');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> deleteOldestScreenshots(int count) async {
    if (!_available) return;
    await _db!.rawDelete(
      'DELETE FROM $_tScreenshots WHERE id IN '
      '(SELECT id FROM $_tScreenshots ORDER BY created_at ASC LIMIT ?)',
      [count],
    );
  }

  Future<void> insertScreenshot(PendingScreenshot s) async {
    if (!_available) return;
    final count = await screenshotCount();
    if (count >= maxScreenshotsPerSession) {
      await deleteOldestScreenshots(count - maxScreenshotsPerSession + 1);
    }
    await _db!.insert(_tScreenshots, s.toMap());
  }

  Future<List<PendingScreenshot>> getPendingScreenshots(
      String sessionId) async {
    if (!_available) return [];
    final rows = await _db!.query(
      _tScreenshots,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ordinal ASC',
    );
    return rows.map(PendingScreenshot.fromMap).toList();
  }

  Future<void> deleteScreenshotById(int id) async {
    if (!_available) return;
    await _db!.delete(_tScreenshots, where: 'id = ?', whereArgs: [id]);
  }

  /// Upserts a pending session stub. Called twice per session:
  /// 1. On session start with `crashed: true` — acts as a crash sentinel.
  /// 2. On session end with the final payload (`crashed: false`, `endedAt` set)
  ///    — overwrites the sentinel with real data before the network flush.
  /// Deleted by [deletePendingSession] once the server confirms receipt.
  Future<void> savePendingSession(String sessionId, String sessionJson) async {
    if (!_available) return;
    await _db!.insert(
      _tSessions,
      {
        'id': sessionId,
        'session_json': sessionJson,
        'created_at': DateTime.now().millisecondsSinceEpoch,
        'status': 'pending',
      },
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  Future<void> deletePendingSession(String sessionId) async {
    if (!_available) return;
    await _db!.delete(_tSessions, where: 'id = ?', whereArgs: [sessionId]);
  }

  /// Returns true if the pending_events table has any rows whose session_json
  /// references [sessionId]. Used during crash-recovery to decide whether a
  /// stale session still has unsent events worth flushing.
  Future<bool> hasPendingEventsForSession(String sessionId) async {
    if (!_available) return false;
    final rows = await _db!.rawQuery(
      'SELECT COUNT(*) AS count FROM $_tEvents WHERE session_json LIKE ?',
      ['%"sessionId":"$sessionId"%'],
    );
    final count = rows.isNotEmpty ? (rows.first['count'] as int? ?? 0) : 0;
    return count > 0;
  }

  /// Returns sessions saved on start that were never deleted (app crashed/killed).
  Future<List<Map<String, dynamic>>> getPendingSessions() async {
    if (!_available) return [];
    final rows = await _db!.query(_tSessions, orderBy: 'created_at ASC');
    return rows
        .map((r) => {'id': r['id'], 'session_json': r['session_json']})
        .toList();
  }

  /// Deletes every locally queued event, screenshot and session stub. Called on
  /// opt-out so that nothing captured before consent was withdrawn can be
  /// uploaded later by a retry or by crash recovery.
  Future<void> purgeAll() async {
    _walTimer?.cancel();
    _walTimer = null;
    _walPending.clear();
    if (!_available) return;
    final db = _db;
    if (db == null) return;
    await db.transaction((txn) async {
      await txn.delete(_tEvents);
      await txn.delete(_tScreenshots);
      await txn.delete(_tSessions);
      await txn.delete(_tWal);
    });
  }

  Future<void> close() async {
    await walFlush();
    await _db?.close();
    _db = null;
  }
}
