/// Point to H3 cell index (`latLngToCell`), ported from the H3 reference C
/// library v4.5.0 (Apache-2.0, github.com/uber/h3): faceijk.c, coordijk.h,
/// h3Index.c, baseCells.c. Only the encode path is included (about 4 KB of
/// tables). It mirrors `android/src/main/java/.../PowerH3.java` line for line;
/// the Java port is checked against 330,000 reference outputs, and both are
/// checked against reference vectors in their unit tests.
library;

import 'dart:math' as math;

const double _mPi180 = 0.0174532925199432957692369076848861271111;
const double _m2Pi = 6.28318530717958647692528676655900576839433;
const double _epsilon = 0.0000000000000001;
const double _mRsin60 = 1.1547005383792515290182975610039149112953;
const double _mOneSeventh = 0.14285714285714285714285714285714285;
const double _mAp7RotRads = 0.333473172251832115336090755351601070065900389;
const double _invRes0UGnomonic = 2.61803398874989588842;
const double _mSqrt7 = 2.6457513110645905905016157536392604257102;
const int _maxFaceCoord = 2;
const int _kAxesDigit = 1;

/// Icosahedron face centers as unit vectors (faceCenterPoint).
const List<double> _faceCenter = [
  0.2199307791404606, 0.6583691780274996, 0.7198475378926182, //
  -0.2139234834501421, 0.1478171829550703, 0.9656017935214205,
  0.1092625278784797, -0.4811951572873210, 0.8697775121287253,
  0.7428567301586791, -0.3593941678278028, 0.5648005936517033,
  0.8112534709140969, 0.3448953237639384, 0.4721387736413930,
  -0.1055498149613921, 0.9794457296411413, 0.1718874610009365,
  -0.8075407579970092, 0.1533552485898818, 0.5695261994882688,
  -0.2846148069787907, -0.8644080972654206, 0.4144792552473539,
  0.7405621473854482, -0.6673299564565524, -0.0789837646326737,
  0.8512303986474293, 0.4722343788582681, -0.2289137388687808,
  -0.7405621473854481, 0.6673299564565524, 0.0789837646326737,
  -0.8512303986474292, -0.4722343788582682, 0.2289137388687808,
  0.1055498149613919, -0.9794457296411413, -0.1718874610009365,
  0.8075407579970092, -0.1533552485898819, -0.5695261994882688,
  0.2846148069787908, 0.8644080972654204, -0.4144792552473539,
  -0.7428567301586791, 0.3593941678278027, -0.5648005936517033,
  -0.8112534709140971, -0.3448953237639382, -0.4721387736413930,
  -0.2199307791404607, -0.6583691780274996, -0.7198475378926182,
  0.2139234834501420, -0.1478171829550704, -0.9656017935214205,
  -0.1092625278784796, 0.4811951572873210, -0.8697775121287253,
];

/// Azimuth of each face's Class II i-axis (faceAxesAzRadsCII[face][0]).
const List<double> _faceAxisAz = [
  5.619958268523939882, 5.760339081714187279, 0.780213654393430055, //
  0.430469363979999913, 6.130269123335111400, 2.692877706530642877,
  2.982963003477243874, 3.532912002790141181, 3.494305004259568154,
  3.003214169499538391, 5.930472956509811562, 0.138378484090254847,
  0.448714947059150361, 0.158629650112549365, 5.891865957979238535,
  2.711123289609793325, 3.294508837434268316, 3.804819692245439833,
  3.664438879055192436, 2.361378999196363184,
];

/// faceIjkBaseCells[face][i][j][k] packed as baseCell * 8 + ccwRot60, at
/// index face * 27 + i * 9 + j * 3 + k.
const List<int> _faceIjkBaseCells = [
  128, 144, 192, 264, 240, 259, 393, 387, 403, 64, 45, 85, 176, 128, 144, 329,
  264, 240, 32, 5, 21, 121, 64, 45, 249, 176, 128, // face 0
  16, 48, 112, 80, 88, 139, 193, 187, 203, 0, 13, 77, 40, 16, 48, 145, 80, 88,
  33, 29, 61, 65, 0, 13, 129, 40, 16, // face 1
  56, 168, 304, 72, 152, 275, 113, 163, 291, 24, 109, 237, 8, 56, 168, 49, 72,
  152, 34, 101, 213, 1, 24, 109, 17, 8, 56, // face 2
  208, 336, 464, 232, 344, 499, 305, 379, 515, 96, 229, 357, 104, 208, 336, 169,
  232, 344, 35, 125, 253, 25, 96, 229, 57, 104, 208, // face 3
  248, 328, 392, 352, 424, 491, 465, 523, 603, 120, 181, 269, 224, 248, 328,
  337, 352, 424, 36, 69, 133, 97, 120, 181, 209, 224, 248, // face 4
  400, 384, 395, 256, 243, 267, 195, 147, 131, 560, 536, 531, 419, 400, 384,
  299, 256, 243, 664, 699, 683, 595, 560, 536, 457, 419, 400, // face 5
  200, 184, 195, 136, 91, 83, 115, 51, 19, 360, 312, 299, 283, 200, 184, 219,
  136, 91, 504, 475, 459, 451, 360, 312, 371, 283, 200, // face 6
  288, 160, 115, 272, 155, 75, 307, 171, 59, 440, 320, 219, 435, 288, 160, 411,
  272, 155, 576, 483, 371, 587, 440, 320, 571, 435, 288, // face 7
  512, 376, 307, 496, 347, 235, 467, 339, 211, 672, 552, 411, 659, 512, 376,
  611, 496, 347, 776, 715, 571, 787, 672, 552, 771, 659, 512, // face 8
  600, 520, 467, 488, 427, 355, 395, 331, 251, 752, 688, 611, 651, 600, 520,
  531, 488, 427, 856, 835, 771, 811, 752, 688, 683, 651, 600, // face 9
  456, 472, 507, 592, 627, 635, 667, 739, 763, 296, 315, 363, 416, 456, 472,
  563, 592, 627, 192, 187, 203, 259, 296, 315, 403, 416, 456, // face 10
  368, 480, 579, 448, 547, 643, 507, 619, 723, 216, 323, 443, 280, 368, 480,
  363, 448, 547, 112, 163, 291, 139, 216, 323, 203, 280, 368, // face 11
  568, 712, 779, 584, 731, 827, 579, 707, 843, 408, 555, 675, 432, 568, 712,
  443, 584, 731, 304, 379, 515, 275, 408, 555, 291, 432, 568, // face 12
  768, 832, 859, 784, 883, 923, 779, 891, 955, 608, 691, 755, 656, 768, 832,
  675, 784, 883, 464, 523, 603, 499, 608, 691, 515, 656, 768, // face 13
  680, 696, 667, 808, 819, 803, 859, 899, 915, 528, 539, 563, 648, 680, 696,
  755, 808, 819, 392, 387, 403, 491, 528, 539, 603, 648, 680, // face 14
  760, 736, 664, 632, 624, 595, 505, 475, 459, 872, 864, 805, 745, 760, 736,
  617, 632, 624, 940, 949, 917, 849, 872, 864, 721, 745, 760, // face 15
  720, 616, 504, 640, 544, 451, 577, 483, 371, 848, 744, 637, 793, 720, 616,
  705, 640, 544, 939, 877, 765, 905, 848, 744, 841, 793, 720, // face 16
  840, 704, 576, 824, 728, 587, 777, 715, 571, 904, 792, 645, 929, 840, 704,
  889, 824, 728, 938, 853, 725, 969, 904, 792, 953, 929, 840, // face 17
  952, 888, 776, 920, 880, 787, 857, 835, 771, 968, 928, 829, 961, 952, 888,
  897, 920, 880, 937, 909, 845, 945, 968, 928, 913, 961, 952, // face 18
  912, 896, 856, 800, 816, 811, 665, 699, 683, 944, 960, 925, 865, 912, 896,
  737, 800, 816, 936, 973, 957, 873, 944, 960, 761, 865, 912, // face 19
];

/// The 12 pentagon base cells and their two clockwise-offset faces.
const List<int> _pentagons = [4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117];
const List<List<int>> _pentagonCwOffsetFaces = [
  [-1, -1], [2, 6], [1, 5], [3, 7], [0, 9], [4, 8], //
  [11, 15], [12, 16], [10, 19], [13, 17], [14, 18], [-1, -1],
];

/// UNIT_VECS, indexed by digit 0..6.
const List<List<int>> _unitVecs = [
  [0, 0, 0], [0, 0, 1], [0, 1, 0], [0, 1, 1], [1, 0, 0], [1, 0, 1],
  [1, 1, 0], //
];

/// The H3 cell containing ([latDeg], [lngDeg]) at [res] as the canonical
/// 15-character lowercase hex string, or null for invalid input.
String? latLngToCell(double latDeg, double lngDeg, int res) {
  if (res < 0 || res > 15) return null;
  if (latDeg.isNaN ||
      lngDeg.isNaN ||
      latDeg.isInfinite ||
      lngDeg.isInfinite ||
      latDeg.abs() > 90.0 ||
      lngDeg.abs() > 180.0) {
    return null;
  }
  final lat = latDeg * _mPi180;
  final lng = lngDeg * _mPi180;

  // latLngToVec3
  final cr = math.cos(lat);
  final px = math.cos(lng) * cr;
  final py = math.sin(lng) * cr;
  final pz = math.sin(lat);

  // _vec3ToClosestFace
  var face = 0;
  var sqd = 5.0;
  for (var f = 0; f < 20; f++) {
    final dx = _faceCenter[f * 3] - px;
    final dy = _faceCenter[f * 3 + 1] - py;
    final dz = _faceCenter[f * 3 + 2] - pz;
    final sqdT = dx * dx + dy * dy + dz * dz;
    if (sqdT < sqd) {
      face = f;
      sqd = sqdT;
    }
  }

  // _vec3ToHex2d
  double vx;
  double vy;
  var r = math.acos(1 - sqd * 0.5);
  if (r < _epsilon) {
    vx = 0.0;
    vy = 0.0;
  } else {
    final cx = _faceCenter[face * 3];
    final cy = _faceCenter[face * 3 + 1];
    final cz = _faceCenter[face * 3 + 2];
    var theta = _posAngleRads(_faceAxisAz[face] -
        _posAngleRads(_vec3AzimuthRads(cx, cy, cz, px, py, pz)));
    if (res.isOdd) theta = _posAngleRads(theta - _mAp7RotRads);
    r = math.tan(r);
    r *= _invRes0UGnomonic;
    for (var i = 0; i < res; i++) {
      r *= _mSqrt7;
    }
    vx = r * math.cos(theta);
    vy = r * math.sin(theta);
  }

  final ijk = _hex2dToCoordIJK(vx, vy);
  return _faceIjkToH3(face, ijk, res);
}

double _posAngleRads(double rads) {
  var tmp = (rads < 0.0) ? rads + _m2Pi : rads;
  if (rads >= _m2Pi) tmp -= _m2Pi;
  return tmp;
}

/// _vec3AzimuthRads(p1 = face center, p2 = point).
double _vec3AzimuthRads(
    double ax, double ay, double az, double bx, double by, double bz) {
  // _vec3TangentBasis(p1): north = northPole - dot(northPole, p1) * p1
  final d = az;
  var nx = 1.0 * 0.0 + -d * ax;
  var ny = 1.0 * 0.0 + -d * ay;
  var nz = 1.0 * 1.0 + -d * az;
  final nn = _norm(nx, ny, nz);
  nx *= nn;
  ny *= nn;
  nz *= nn;
  // east = cross(north, p1)
  final ex = ny * az - nz * ay;
  final ey = nz * ax - nx * az;
  final ez = nx * ay - ny * ax;
  // project p2 onto the tangent plane at p1
  final d2 = bx * ax + by * ay + bz * az;
  var qx = 1.0 * bx + -d2 * ax;
  var qy = 1.0 * by + -d2 * ay;
  var qz = 1.0 * bz + -d2 * az;
  final qn = _norm(qx, qy, qz);
  qx *= qn;
  qy *= qn;
  qz *= qn;
  return math.atan2(qx * ex + qy * ey + qz * ez, qx * nx + qy * ny + qz * nz);
}

/// Scale factor that normalizes (x, y, z), as vec3Normalize.
double _norm(double x, double y, double z) {
  final n = math.sqrt(x * x + y * y + z * z);
  return n > 0.0 ? 1.0 / n : 0.0;
}

List<int> _hex2dToCoordIJK(double x, double y) {
  int i;
  int j;
  final a1 = x.abs();
  final a2 = y.abs();
  final x2 = a2 * _mRsin60;
  final x1 = a1 + x2 / 2.0;
  final m1 = x1.toInt();
  final m2 = x2.toInt();
  final r1 = x1 - m1;
  final r2 = x2 - m2;

  if (r1 < 0.5) {
    if (r1 < 1.0 / 3.0) {
      if (r2 < (1.0 + r1) / 2.0) {
        i = m1;
        j = m2;
      } else {
        i = m1;
        j = m2 + 1;
      }
    } else {
      if (r2 < (1.0 - r1)) {
        j = m2;
      } else {
        j = m2 + 1;
      }
      if ((1.0 - r1) <= r2 && r2 < (2.0 * r1)) {
        i = m1 + 1;
      } else {
        i = m1;
      }
    }
  } else {
    if (r1 < 2.0 / 3.0) {
      if (r2 < (1.0 - r1)) {
        j = m2;
      } else {
        j = m2 + 1;
      }
      if ((2.0 * r1 - 1.0) < r2 && r2 < (1.0 - r1)) {
        i = m1;
      } else {
        i = m1 + 1;
      }
    } else {
      if (r2 < (r1 / 2.0)) {
        i = m1 + 1;
        j = m2;
      } else {
        i = m1 + 1;
        j = m2 + 1;
      }
    }
  }

  // fold across the axes if necessary (j >= 0 here, so ~/ and % match C)
  if (x < 0.0) {
    if ((j % 2) == 0) {
      final axisi = j ~/ 2;
      final diff = i - axisi;
      i = (i - 2.0 * diff).toInt();
    } else {
      final axisi = (j + 1) ~/ 2;
      final diff = i - axisi;
      i = (i - (2.0 * diff + 1)).toInt();
    }
  }
  if (y < 0.0) {
    i = i - (2 * j + 1) ~/ 2;
    j = -1 * j;
  }
  final h = [i, j, 0];
  _normalize(h);
  return h;
}

void _normalize(List<int> c) {
  if (c[0] < 0) {
    c[1] -= c[0];
    c[2] -= c[0];
    c[0] = 0;
  }
  if (c[1] < 0) {
    c[0] -= c[1];
    c[2] -= c[1];
    c[1] = 0;
  }
  if (c[2] < 0) {
    c[0] -= c[2];
    c[1] -= c[2];
    c[2] = 0;
  }
  var min = c[0];
  if (c[1] < min) min = c[1];
  if (c[2] < min) min = c[2];
  if (min > 0) {
    c[0] -= min;
    c[1] -= min;
    c[2] -= min;
  }
}

/// C lround: half away from zero (as Dart's double.round()).
int _lround(double v) => v.round();

void _upAp7(List<int> c) {
  final i = c[0] - c[2];
  final j = c[1] - c[2];
  c[0] = _lround((3 * i - j) * _mOneSeventh);
  c[1] = _lround((i + 2 * j) * _mOneSeventh);
  c[2] = 0;
  _normalize(c);
}

void _upAp7r(List<int> c) {
  final i = c[0] - c[2];
  final j = c[1] - c[2];
  c[0] = _lround((2 * i + j) * _mOneSeventh);
  c[1] = _lround((3 * j - i) * _mOneSeventh);
  c[2] = 0;
  _normalize(c);
}

void _downAp7(List<int> c) {
  final i = c[0];
  final j = c[1];
  final k = c[2];
  // iVec {3,0,1}, jVec {1,3,0}, kVec {0,1,3}
  c[0] = 3 * i + j;
  c[1] = 3 * j + k;
  c[2] = i + 3 * k;
  _normalize(c);
}

void _downAp7r(List<int> c) {
  final i = c[0];
  final j = c[1];
  final k = c[2];
  // iVec {3,1,0}, jVec {0,3,1}, kVec {1,0,3}
  c[0] = 3 * i + k;
  c[1] = i + 3 * j;
  c[2] = j + 3 * k;
  _normalize(c);
}

int _unitIjkToDigit(List<int> ijk) {
  final c = [ijk[0], ijk[1], ijk[2]];
  _normalize(c);
  for (var d = 0; d < 7; d++) {
    final u = _unitVecs[d];
    if (c[0] == u[0] && c[1] == u[1] && c[2] == u[2]) return d;
  }
  return 7;
}

int _rotate60ccw(int digit) {
  switch (digit) {
    case 1:
      return 5;
    case 5:
      return 4;
    case 4:
      return 6;
    case 6:
      return 2;
    case 2:
      return 3;
    case 3:
      return 1;
    default:
      return digit;
  }
}

int _rotate60cw(int digit) {
  switch (digit) {
    case 1:
      return 3;
    case 3:
      return 2;
    case 2:
      return 6;
    case 6:
      return 4;
    case 4:
      return 5;
    case 5:
      return 1;
    default:
      return digit;
  }
}

/// digits[r] is the digit at resolution r (1..res); digits[0] is unused.
int _leadingNonZeroDigit(List<int> digits, int res) {
  for (var r = 1; r <= res; r++) {
    if (digits[r] != 0) return digits[r];
  }
  return 0;
}

void _rotate60ccwAll(List<int> digits, int res) {
  for (var r = 1; r <= res; r++) {
    digits[r] = _rotate60ccw(digits[r]);
  }
}

void _rotate60cwAll(List<int> digits, int res) {
  for (var r = 1; r <= res; r++) {
    digits[r] = _rotate60cw(digits[r]);
  }
}

void _rotatePent60ccw(List<int> digits, int res) {
  var foundFirstNonZeroDigit = false;
  for (var r = 1; r <= res; r++) {
    digits[r] = _rotate60ccw(digits[r]);
    if (!foundFirstNonZeroDigit && digits[r] != 0) {
      foundFirstNonZeroDigit = true;
      if (_leadingNonZeroDigit(digits, res) == _kAxesDigit) {
        _rotate60ccwAll(digits, res);
      }
    }
  }
}

String? _faceIjkToH3(int face, List<int> ijk, int res) {
  final digits = List<int>.filled(16, 0);
  for (var r = res - 1; r >= 0; r--) {
    final last = [ijk[0], ijk[1], ijk[2]];
    List<int> lastCenter;
    if ((r + 1).isOdd) {
      _upAp7(ijk);
      lastCenter = [ijk[0], ijk[1], ijk[2]];
      _downAp7(lastCenter);
    } else {
      _upAp7r(ijk);
      lastCenter = [ijk[0], ijk[1], ijk[2]];
      _downAp7r(lastCenter);
    }
    final diff = [
      last[0] - lastCenter[0],
      last[1] - lastCenter[1],
      last[2] - lastCenter[2],
    ];
    _normalize(diff);
    digits[r + 1] = _unitIjkToDigit(diff);
  }

  if (ijk[0] > _maxFaceCoord ||
      ijk[1] > _maxFaceCoord ||
      ijk[2] > _maxFaceCoord) {
    return null;
  }
  final packed =
      _faceIjkBaseCells[face * 27 + ijk[0] * 9 + ijk[1] * 3 + ijk[2]];
  final baseCell = packed >> 3;
  final numRots = packed & 7;

  final pent = _pentagons.indexOf(baseCell);
  if (pent >= 0) {
    if (_leadingNonZeroDigit(digits, res) == _kAxesDigit) {
      final cw = _pentagonCwOffsetFaces[pent];
      if (cw[0] == face || cw[1] == face) {
        _rotate60cwAll(digits, res);
      } else {
        _rotate60ccwAll(digits, res);
      }
    }
    for (var i = 0; i < numRots; i++) {
      _rotatePent60ccw(digits, res);
    }
  } else {
    for (var i = 0; i < numRots; i++) {
      _rotate60ccwAll(digits, res);
    }
  }
  return _format(res, baseCell, digits);
}

/// Bit layout: mode (1 = cell) at 59, resolution at 52, base cell at 45, then
/// 15 three-bit digits; digits finer than res are 7. Built with BigInt so the
/// result is also exact where ints are 53-bit (web).
String _format(int res, int baseCell, List<int> digits) {
  var h = (BigInt.one << 59) |
      (BigInt.from(res) << 52) |
      (BigInt.from(baseCell) << 45);
  for (var r = 1; r <= 15; r++) {
    final d = r <= res ? digits[r] : 7;
    h |= BigInt.from(d) << ((15 - r) * 3);
  }
  return h.toRadixString(16);
}
