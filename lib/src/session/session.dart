import 'dart:math';

String _uuid() {
  final rand = Random.secure();
  final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}

/// A single user session.
class Session {
  final String id;
  final int startedAt;
  int foregroundTimeMs = 0;
  int backgroundTimeMs = 0;
  bool crashed = false;
  int offlineEventCount = 0;
  int onlineEventCount = 0;
  int networkTransitions = 0;
  int? endedAt;

  Session()
      : id = _uuid(),
        startedAt = DateTime.now().millisecondsSinceEpoch;

  int get durationMs =>
      (endedAt ?? DateTime.now().millisecondsSinceEpoch) - startedAt;
}
