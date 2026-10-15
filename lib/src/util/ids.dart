import 'dart:math';

final Random _rand = Random.secure();

/// Generates an RFC 4122 version-4 UUID using a cryptographically secure RNG.
///
/// Used for session ids and, since 2.1, for every event id so the server can
/// discard duplicate uploads (`INSERT ... ON CONFLICT (id) DO NOTHING`).
String generateUuidV4() {
  final bytes = List<int>.generate(16, (_) => _rand.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  String hex(int b) => b.toRadixString(16).padLeft(2, '0');
  final h = bytes.map(hex).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-'
      '${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
