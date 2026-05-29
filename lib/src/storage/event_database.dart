import 'dart:async';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'pending_event.dart';
import 'pending_screenshot.dart';

/// sqflite-backed persistent queue for events and screenshots.
class EventDatabase {
  static const _dbName = 'unilitix_events.db';
  static const _version = 1;
  static const _tEvents = 'pending_events';
  static const _tScreenshots = 'pending_screenshots';

  final int maxOfflineEvents;
  Database? _db;

  EventDatabase({required this.maxOfflineEvents});

  Future<void> open() async {
    final path = p.join(await getDatabasesPath(), _dbName);
    _db = await openDatabase(
      path,
      version: _version,
      onCreate: _create,
    );
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('''
      CREATE TABLE $_tEvents (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_json TEXT NOT NULL,
        events_json TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        retry_count INTEGER DEFAULT 0,
        captured_offline INTEGER DEFAULT 0,
        network_at_capture TEXT DEFAULT 'UNKNOWN',
        sync_attempts INTEGER DEFAULT 0,
        sync_failed_batches INTEGER DEFAULT 0
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
  }

  Future<void> insertEvent(PendingEvent event) async {
    final db = _db!;
    final count = await eventCount();
    if (count >= maxOfflineEvents) {
      await deleteOldestEvents(count - maxOfflineEvents + 1);
    }
    await db.insert(_tEvents, event.toMap());
  }

  Future<List<PendingEvent>> getOldestEvents(int limit) async {
    final rows = await _db!.query(
      _tEvents,
      orderBy: 'created_at ASC',
      limit: limit,
    );
    return rows.map(PendingEvent.fromMap).toList();
  }

  Future<void> deleteEventById(int id) async {
    await _db!.delete(_tEvents, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> deleteEventsByIds(List<int> ids) async {
    if (ids.isEmpty) return;
    final placeholders = ids.map((_) => '?').join(',');
    await _db!.delete(_tEvents, where: 'id IN ($placeholders)', whereArgs: ids);
  }

  Future<void> incrementRetryCount(int id) async {
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET retry_count = retry_count + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> incrementSyncAttempts(int id) async {
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET sync_attempts = sync_attempts + 1 WHERE id = ?',
      [id],
    );
  }

  Future<void> incrementSyncFailedBatches(int id) async {
    await _db!.rawUpdate(
      'UPDATE $_tEvents SET sync_failed_batches = sync_failed_batches + 1 WHERE id = ?',
      [id],
    );
  }

  Future<int> eventCount() async {
    final result = await _db!.rawQuery('SELECT COUNT(*) as c FROM $_tEvents');
    return (result.first['c'] as int?) ?? 0;
  }

  Future<void> deleteOldestEvents(int count) async {
    await _db!.rawDelete(
      'DELETE FROM $_tEvents WHERE id IN '
      '(SELECT id FROM $_tEvents ORDER BY created_at ASC LIMIT ?)',
      [count],
    );
  }

  Future<void> remapSessionId(String oldId, String newId) async {
    await _db!.rawUpdate(
      "UPDATE $_tScreenshots SET session_id = ? WHERE session_id = ?",
      [newId, oldId],
    );
  }

  // Screenshots
  Future<void> insertScreenshot(PendingScreenshot s) async {
    await _db!.insert(_tScreenshots, s.toMap());
  }

  Future<List<PendingScreenshot>> getPendingScreenshots(
      String sessionId) async {
    final rows = await _db!.query(
      _tScreenshots,
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'ordinal ASC',
    );
    return rows.map(PendingScreenshot.fromMap).toList();
  }

  Future<void> deleteScreenshotById(int id) async {
    await _db!.delete(_tScreenshots, where: 'id = ?', whereArgs: [id]);
  }

  Future<void> close() async {
    await _db?.close();
    _db = null;
  }
}
