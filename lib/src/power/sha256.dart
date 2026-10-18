/// Minimal SHA-256 (FIPS 180-4) for the power-outage device id, so the SDK
/// does not take a dependency on `package:crypto` for one short hash.
/// Checked against hashlib vectors in test/power_outage_test.dart.
library;

const List<int> _k = [
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, //
  0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174, 0xe49b69c1, 0xefbe4786,
  0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147,
  0x06ca6351, 0x14292967, 0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b,
  0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a,
  0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const int _mask = 0xffffffff;

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & _mask;

/// SHA-256 of [message] as a lowercase hex string.
String sha256Hex(List<int> message) {
  final h = <int>[
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, //
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
  ];

  final data = <int>[...message, 0x80];
  while (data.length % 64 != 56) {
    data.add(0);
  }
  // Message length in bits, big-endian 64-bit, split so no shift exceeds 32.
  final hi = (message.length >> 29) & _mask;
  final lo = (message.length << 3) & _mask;
  for (final word in [hi, lo]) {
    data
      ..add((word >> 24) & 0xff)
      ..add((word >> 16) & 0xff)
      ..add((word >> 8) & 0xff)
      ..add(word & 0xff);
  }

  final w = List<int>.filled(64, 0);
  for (var chunk = 0; chunk < data.length; chunk += 64) {
    for (var i = 0; i < 16; i++) {
      final j = chunk + i * 4;
      w[i] = (data[j] << 24) |
          (data[j + 1] << 16) |
          (data[j + 2] << 8) |
          data[j + 3];
    }
    for (var i = 16; i < 64; i++) {
      final s0 = _rotr(w[i - 15], 7) ^ _rotr(w[i - 15], 18) ^ (w[i - 15] >> 3);
      final s1 = _rotr(w[i - 2], 17) ^ _rotr(w[i - 2], 19) ^ (w[i - 2] >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & _mask;
    }

    var a = h[0], b = h[1], c = h[2], d = h[3];
    var e = h[4], f = h[5], g = h[6], hh = h[7];
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & _mask) & g);
      final t1 = (hh + s1 + ch + _k[i] + w[i]) & _mask;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & _mask;
      hh = g;
      g = f;
      f = e;
      e = (d + t1) & _mask;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & _mask;
    }
    h[0] = (h[0] + a) & _mask;
    h[1] = (h[1] + b) & _mask;
    h[2] = (h[2] + c) & _mask;
    h[3] = (h[3] + d) & _mask;
    h[4] = (h[4] + e) & _mask;
    h[5] = (h[5] + f) & _mask;
    h[6] = (h[6] + g) & _mask;
    h[7] = (h[7] + hh) & _mask;
  }
  return h.map((v) => v.toRadixString(16).padLeft(8, '0')).join();
}
