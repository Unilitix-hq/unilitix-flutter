/// A batch of events pending upload.
class PendingEvent {
  final int? id;
  final String sessionJson;
  final String eventsJson;
  final int createdAt;
  int retryCount;
  final bool capturedOffline;
  final String networkAtCapture;
  int syncAttempts;
  int syncFailedBatches;

  PendingEvent({
    this.id,
    required this.sessionJson,
    required this.eventsJson,
    required this.createdAt,
    this.retryCount = 0,
    this.capturedOffline = false,
    this.networkAtCapture = 'UNKNOWN',
    this.syncAttempts = 0,
    this.syncFailedBatches = 0,
  });

  Map<String, dynamic> toMap() => {
        if (id != null) 'id': id,
        'session_json': sessionJson,
        'events_json': eventsJson,
        'created_at': createdAt,
        'retry_count': retryCount,
        'captured_offline': capturedOffline ? 1 : 0,
        'network_at_capture': networkAtCapture,
        'sync_attempts': syncAttempts,
        'sync_failed_batches': syncFailedBatches,
      };

  factory PendingEvent.fromMap(Map<String, dynamic> map) => PendingEvent(
        id: map['id'] as int?,
        sessionJson: map['session_json'] as String,
        eventsJson: map['events_json'] as String,
        createdAt: map['created_at'] as int,
        retryCount: map['retry_count'] as int? ?? 0,
        capturedOffline: (map['captured_offline'] as int? ?? 0) == 1,
        networkAtCapture: map['network_at_capture'] as String? ?? 'UNKNOWN',
        syncAttempts: map['sync_attempts'] as int? ?? 0,
        syncFailedBatches: map['sync_failed_batches'] as int? ?? 0,
      );
}
