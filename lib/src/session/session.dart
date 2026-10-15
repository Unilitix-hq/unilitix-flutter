import '../util/ids.dart';

/// A single user session.
class Session {
  final String id;
  final int startedAt;

  int _nextSeq = 0;

  /// Returns the next per-session capture sequence number (0-based). The
  /// server uses it to restore capture order when batches arrive out of order
  /// and, together with the event id, to deduplicate retried uploads.
  int takeSeq() => _nextSeq++;
  int foregroundTimeMs = 0;
  int backgroundTimeMs = 0;
  bool crashed = false;
  int offlineEventCount = 0;
  int onlineEventCount = 0;
  int networkTransitions = 0;
  int? endedAt;

  Session()
      : id = generateUuidV4(),
        startedAt = DateTime.now().millisecondsSinceEpoch;

  int get durationMs =>
      (endedAt ?? DateTime.now().millisecondsSinceEpoch) - startedAt;
}
