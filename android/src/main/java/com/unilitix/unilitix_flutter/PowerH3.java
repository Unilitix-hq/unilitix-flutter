package com.unilitix.unilitix_flutter;

/**
 * Point to H3 cell index (latLngToCell), ported from the H3 reference C
 * library v4.5.0 (Apache-2.0, github.com/uber/h3): faceijk.c, coordijk.h,
 * h3Index.c, baseCells.c. Only the encode path is included. The Dart port
 * in lib/src/power/h3.dart mirrors this file line for line; both are
 * checked against vectors produced by the reference library.
 *
 * Pure Java (no Android APIs) so it is unit-testable on the JVM.
 */
final class PowerH3 {
    private PowerH3() {}

    private static final double M_PI_180 = 0.0174532925199432957692369076848861271111;
    private static final double M_2PI = 6.28318530717958647692528676655900576839433;
    private static final double EPSILON = 0.0000000000000001;
    private static final double M_RSIN60 = 1.1547005383792515290182975610039149112953;
    private static final double M_ONESEVENTH = 0.14285714285714285714285714285714285;
    private static final double M_AP7_ROT_RADS = 0.333473172251832115336090755351601070065900389;
    private static final double INV_RES0_U_GNOMONIC = 2.61803398874989588842;
    private static final double M_SQRT7 = 2.6457513110645905905016157536392604257102;
    private static final int MAX_FACE_COORD = 2;

    /** Icosahedron face centers as unit vectors (faceCenterPoint). */
    private static final double[] FACE_CENTER = {
        0.2199307791404606, 0.6583691780274996, 0.7198475378926182,
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
    };

    /** Azimuth of each face's Class II i-axis (faceAxesAzRadsCII[face][0]). */
    private static final double[] FACE_AXIS_AZ = {
        5.619958268523939882, 5.760339081714187279, 0.780213654393430055,
        0.430469363979999913, 6.130269123335111400, 2.692877706530642877,
        2.982963003477243874, 3.532912002790141181, 3.494305004259568154,
        3.003214169499538391, 5.930472956509811562, 0.138378484090254847,
        0.448714947059150361, 0.158629650112549365, 5.891865957979238535,
        2.711123289609793325, 3.294508837434268316, 3.804819692245439833,
        3.664438879055192436, 2.361378999196363184,
    };

    /**
     * faceIjkBaseCells[face][i][j][k] packed as baseCell * 8 + ccwRot60,
     * at index face * 27 + i * 9 + j * 3 + k.
     */
    private static final short[] FACE_IJK_BASE_CELLS = {
      128, 144, 192, 264, 240, 259, 393, 387, 403, 64, 45, 85, 176, 128, 144, 329, 264, 240, 32, 5, 21, 121, 64, 45, 249, 176, 128, // face 0
      16, 48, 112, 80, 88, 139, 193, 187, 203, 0, 13, 77, 40, 16, 48, 145, 80, 88, 33, 29, 61, 65, 0, 13, 129, 40, 16, // face 1
      56, 168, 304, 72, 152, 275, 113, 163, 291, 24, 109, 237, 8, 56, 168, 49, 72, 152, 34, 101, 213, 1, 24, 109, 17, 8, 56, // face 2
      208, 336, 464, 232, 344, 499, 305, 379, 515, 96, 229, 357, 104, 208, 336, 169, 232, 344, 35, 125, 253, 25, 96, 229, 57, 104, 208, // face 3
      248, 328, 392, 352, 424, 491, 465, 523, 603, 120, 181, 269, 224, 248, 328, 337, 352, 424, 36, 69, 133, 97, 120, 181, 209, 224, 248, // face 4
      400, 384, 395, 256, 243, 267, 195, 147, 131, 560, 536, 531, 419, 400, 384, 299, 256, 243, 664, 699, 683, 595, 560, 536, 457, 419, 400, // face 5
      200, 184, 195, 136, 91, 83, 115, 51, 19, 360, 312, 299, 283, 200, 184, 219, 136, 91, 504, 475, 459, 451, 360, 312, 371, 283, 200, // face 6
      288, 160, 115, 272, 155, 75, 307, 171, 59, 440, 320, 219, 435, 288, 160, 411, 272, 155, 576, 483, 371, 587, 440, 320, 571, 435, 288, // face 7
      512, 376, 307, 496, 347, 235, 467, 339, 211, 672, 552, 411, 659, 512, 376, 611, 496, 347, 776, 715, 571, 787, 672, 552, 771, 659, 512, // face 8
      600, 520, 467, 488, 427, 355, 395, 331, 251, 752, 688, 611, 651, 600, 520, 531, 488, 427, 856, 835, 771, 811, 752, 688, 683, 651, 600, // face 9
      456, 472, 507, 592, 627, 635, 667, 739, 763, 296, 315, 363, 416, 456, 472, 563, 592, 627, 192, 187, 203, 259, 296, 315, 403, 416, 456, // face 10
      368, 480, 579, 448, 547, 643, 507, 619, 723, 216, 323, 443, 280, 368, 480, 363, 448, 547, 112, 163, 291, 139, 216, 323, 203, 280, 368, // face 11
      568, 712, 779, 584, 731, 827, 579, 707, 843, 408, 555, 675, 432, 568, 712, 443, 584, 731, 304, 379, 515, 275, 408, 555, 291, 432, 568, // face 12
      768, 832, 859, 784, 883, 923, 779, 891, 955, 608, 691, 755, 656, 768, 832, 675, 784, 883, 464, 523, 603, 499, 608, 691, 515, 656, 768, // face 13
      680, 696, 667, 808, 819, 803, 859, 899, 915, 528, 539, 563, 648, 680, 696, 755, 808, 819, 392, 387, 403, 491, 528, 539, 603, 648, 680, // face 14
      760, 736, 664, 632, 624, 595, 505, 475, 459, 872, 864, 805, 745, 760, 736, 617, 632, 624, 940, 949, 917, 849, 872, 864, 721, 745, 760, // face 15
      720, 616, 504, 640, 544, 451, 577, 483, 371, 848, 744, 637, 793, 720, 616, 705, 640, 544, 939, 877, 765, 905, 848, 744, 841, 793, 720, // face 16
      840, 704, 576, 824, 728, 587, 777, 715, 571, 904, 792, 645, 929, 840, 704, 889, 824, 728, 938, 853, 725, 969, 904, 792, 953, 929, 840, // face 17
      952, 888, 776, 920, 880, 787, 857, 835, 771, 968, 928, 829, 961, 952, 888, 897, 920, 880, 937, 909, 845, 945, 968, 928, 913, 961, 952, // face 18
      912, 896, 856, 800, 816, 811, 665, 699, 683, 944, 960, 925, 865, 912, 896, 737, 800, 816, 936, 973, 957, 873, 944, 960, 761, 865, 912, // face 19
    };

    /** The 12 pentagon base cells and their two clockwise-offset faces. */
    private static final int[] PENTAGONS = {4, 14, 24, 38, 49, 58, 63, 72, 83, 97, 107, 117};
    private static final int[][] PENTAGON_CW_OFFSET_FACES = {
        {-1, -1}, {2, 6}, {1, 5}, {3, 7}, {0, 9}, {4, 8},
        {11, 15}, {12, 16}, {10, 19}, {13, 17}, {14, 18}, {-1, -1},
    };

    private static final int K_AXES_DIGIT = 1;
    // UNIT_VECS, indexed by digit 0..6.
    private static final int[][] UNIT_VECS = {
        {0, 0, 0}, {0, 0, 1}, {0, 1, 0}, {0, 1, 1}, {1, 0, 0}, {1, 0, 1}, {1, 1, 0},
    };

    /**
     * The H3 cell containing (latDeg, lngDeg) at [res] as the canonical
     * 15-character lowercase hex string, or null for invalid input.
     */
    static String latLngToCell(double latDeg, double lngDeg, int res) {
        if (res < 0 || res > 15) return null;
        if (Double.isNaN(latDeg) || Double.isNaN(lngDeg) || Double.isInfinite(latDeg)
                || Double.isInfinite(lngDeg) || Math.abs(latDeg) > 90.0 || Math.abs(lngDeg) > 180.0) {
            return null;
        }
        double lat = latDeg * M_PI_180;
        double lng = lngDeg * M_PI_180;

        // latLngToVec3
        double cr = Math.cos(lat);
        double px = Math.cos(lng) * cr;
        double py = Math.sin(lng) * cr;
        double pz = Math.sin(lat);

        // _vec3ToClosestFace
        int face = 0;
        double sqd = 5.0;
        for (int f = 0; f < 20; f++) {
            double dx = FACE_CENTER[f * 3] - px;
            double dy = FACE_CENTER[f * 3 + 1] - py;
            double dz = FACE_CENTER[f * 3 + 2] - pz;
            double sqdT = dx * dx + dy * dy + dz * dz;
            if (sqdT < sqd) {
                face = f;
                sqd = sqdT;
            }
        }

        // _vec3ToHex2d
        double vx;
        double vy;
        double r = Math.acos(1 - sqd * 0.5);
        if (r < EPSILON) {
            vx = 0.0;
            vy = 0.0;
        } else {
            double cx = FACE_CENTER[face * 3];
            double cy = FACE_CENTER[face * 3 + 1];
            double cz = FACE_CENTER[face * 3 + 2];
            double theta = posAngleRads(
                    FACE_AXIS_AZ[face] - posAngleRads(vec3AzimuthRads(cx, cy, cz, px, py, pz)));
            if ((res & 1) == 1) theta = posAngleRads(theta - M_AP7_ROT_RADS);
            r = Math.tan(r);
            r *= INV_RES0_U_GNOMONIC;
            for (int i = 0; i < res; i++) r *= M_SQRT7;
            vx = r * Math.cos(theta);
            vy = r * Math.sin(theta);
        }

        int[] ijk = hex2dToCoordIJK(vx, vy);
        return faceIjkToH3(face, ijk, res);
    }

    private static double posAngleRads(double rads) {
        double tmp = (rads < 0.0) ? rads + M_2PI : rads;
        if (rads >= M_2PI) tmp -= M_2PI;
        return tmp;
    }

    /** _vec3AzimuthRads(p1 = face center, p2 = point). */
    private static double vec3AzimuthRads(double ax, double ay, double az,
                                          double bx, double by, double bz) {
        // _vec3TangentBasis(p1): north = northPole - dot(northPole, p1) * p1
        double d = az; // dot((0,0,1), p1)
        double nx = 1.0 * 0.0 + -d * ax;
        double ny = 1.0 * 0.0 + -d * ay;
        double nz = 1.0 * 1.0 + -d * az;
        double nn = norm(nx, ny, nz);
        nx *= nn;
        ny *= nn;
        nz *= nn;
        // east = cross(north, p1)
        double ex = ny * az - nz * ay;
        double ey = nz * ax - nx * az;
        double ez = nx * ay - ny * ax;
        // project p2 onto the tangent plane at p1
        double d2 = bx * ax + by * ay + bz * az;
        double qx = 1.0 * bx + -d2 * ax;
        double qy = 1.0 * by + -d2 * ay;
        double qz = 1.0 * bz + -d2 * az;
        double qn = norm(qx, qy, qz);
        qx *= qn;
        qy *= qn;
        qz *= qn;
        return Math.atan2(qx * ex + qy * ey + qz * ez, qx * nx + qy * ny + qz * nz);
    }

    /** Scale factor that normalizes (x, y, z), as vec3Normalize. */
    private static double norm(double x, double y, double z) {
        double n = Math.sqrt(x * x + y * y + z * z);
        return n > 0.0 ? 1.0 / n : 0.0;
    }

    private static int[] hex2dToCoordIJK(double x, double y) {
        int i;
        int j;
        double a1 = Math.abs(x);
        double a2 = Math.abs(y);
        double x2 = a2 * M_RSIN60;
        double x1 = a1 + x2 / 2.0;
        int m1 = (int) x1;
        int m2 = (int) x2;
        double r1 = x1 - m1;
        double r2 = x2 - m2;

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

        // fold across the axes if necessary
        if (x < 0.0) {
            if ((j % 2) == 0) {
                long axisi = j / 2;
                long diff = i - axisi;
                i = (int) (i - 2.0 * diff);
            } else {
                long axisi = (j + 1) / 2;
                long diff = i - axisi;
                i = (int) (i - (2.0 * diff + 1));
            }
        }
        if (y < 0.0) {
            i = i - (2 * j + 1) / 2;
            j = -1 * j;
        }
        int[] h = {i, j, 0};
        normalize(h);
        return h;
    }

    private static void normalize(int[] c) {
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
        int min = c[0];
        if (c[1] < min) min = c[1];
        if (c[2] < min) min = c[2];
        if (min > 0) {
            c[0] -= min;
            c[1] -= min;
            c[2] -= min;
        }
    }

    /** C lround: half away from zero. */
    private static int lround(double v) {
        return (int) (v < 0 ? -Math.floor(-v + 0.5) : Math.floor(v + 0.5));
    }

    private static void upAp7(int[] c) {
        int i = c[0] - c[2];
        int j = c[1] - c[2];
        c[0] = lround((3 * i - j) * M_ONESEVENTH);
        c[1] = lround((i + 2 * j) * M_ONESEVENTH);
        c[2] = 0;
        normalize(c);
    }

    private static void upAp7r(int[] c) {
        int i = c[0] - c[2];
        int j = c[1] - c[2];
        c[0] = lround((2 * i + j) * M_ONESEVENTH);
        c[1] = lround((3 * j - i) * M_ONESEVENTH);
        c[2] = 0;
        normalize(c);
    }

    private static void downAp7(int[] c) {
        int i = c[0];
        int j = c[1];
        int k = c[2];
        // iVec {3,0,1}, jVec {1,3,0}, kVec {0,1,3}
        c[0] = 3 * i + j;
        c[1] = 3 * j + k;
        c[2] = i + 3 * k;
        normalize(c);
    }

    private static void downAp7r(int[] c) {
        int i = c[0];
        int j = c[1];
        int k = c[2];
        // iVec {3,1,0}, jVec {0,3,1}, kVec {1,0,3}
        c[0] = 3 * i + k;
        c[1] = i + 3 * j;
        c[2] = j + 3 * k;
        normalize(c);
    }

    private static int unitIjkToDigit(int[] ijk) {
        int[] c = {ijk[0], ijk[1], ijk[2]};
        normalize(c);
        for (int d = 0; d < 7; d++) {
            if (c[0] == UNIT_VECS[d][0] && c[1] == UNIT_VECS[d][1] && c[2] == UNIT_VECS[d][2]) {
                return d;
            }
        }
        return 7;
    }

    private static int rotate60ccw(int digit) {
        switch (digit) {
            case 1: return 5;
            case 5: return 4;
            case 4: return 6;
            case 6: return 2;
            case 2: return 3;
            case 3: return 1;
            default: return digit;
        }
    }

    private static int rotate60cw(int digit) {
        switch (digit) {
            case 1: return 3;
            case 3: return 2;
            case 2: return 6;
            case 6: return 4;
            case 4: return 5;
            case 5: return 1;
            default: return digit;
        }
    }

    /** digits[r] is the digit at resolution r (1..res); digits[0] unused. */
    private static int leadingNonZeroDigit(int[] digits, int res) {
        for (int r = 1; r <= res; r++) {
            if (digits[r] != 0) return digits[r];
        }
        return 0;
    }

    private static void rotate60ccwAll(int[] digits, int res) {
        for (int r = 1; r <= res; r++) digits[r] = rotate60ccw(digits[r]);
    }

    private static void rotate60cwAll(int[] digits, int res) {
        for (int r = 1; r <= res; r++) digits[r] = rotate60cw(digits[r]);
    }

    private static void rotatePent60ccw(int[] digits, int res) {
        boolean foundFirstNonZeroDigit = false;
        for (int r = 1; r <= res; r++) {
            digits[r] = rotate60ccw(digits[r]);
            if (!foundFirstNonZeroDigit && digits[r] != 0) {
                foundFirstNonZeroDigit = true;
                if (leadingNonZeroDigit(digits, res) == K_AXES_DIGIT) rotate60ccwAll(digits, res);
            }
        }
    }

    private static int pentagonOrdinal(int baseCell) {
        for (int p = 0; p < PENTAGONS.length; p++) {
            if (PENTAGONS[p] == baseCell) return p;
        }
        return -1;
    }

    private static String faceIjkToH3(int face, int[] ijk, int res) {
        int[] digits = new int[16];
        for (int r = res - 1; r >= 0; r--) {
            int[] last = {ijk[0], ijk[1], ijk[2]};
            int[] lastCenter;
            if (((r + 1) & 1) == 1) {
                upAp7(ijk);
                lastCenter = new int[] {ijk[0], ijk[1], ijk[2]};
                downAp7(lastCenter);
            } else {
                upAp7r(ijk);
                lastCenter = new int[] {ijk[0], ijk[1], ijk[2]};
                downAp7r(lastCenter);
            }
            int[] diff = {last[0] - lastCenter[0], last[1] - lastCenter[1], last[2] - lastCenter[2]};
            normalize(diff);
            digits[r + 1] = unitIjkToDigit(diff);
        }

        if (ijk[0] > MAX_FACE_COORD || ijk[1] > MAX_FACE_COORD || ijk[2] > MAX_FACE_COORD) {
            return null;
        }
        int packed = FACE_IJK_BASE_CELLS[face * 27 + ijk[0] * 9 + ijk[1] * 3 + ijk[2]];
        int baseCell = packed >> 3;
        int numRots = packed & 7;

        int pent = pentagonOrdinal(baseCell);
        if (pent >= 0) {
            if (leadingNonZeroDigit(digits, res) == K_AXES_DIGIT) {
                int[] cw = PENTAGON_CW_OFFSET_FACES[pent];
                if (cw[0] == face || cw[1] == face) {
                    rotate60cwAll(digits, res);
                } else {
                    rotate60ccwAll(digits, res);
                }
            }
            for (int i = 0; i < numRots; i++) rotatePent60ccw(digits, res);
        } else {
            for (int i = 0; i < numRots; i++) rotate60ccwAll(digits, res);
        }
        return format(res, baseCell, digits);
    }

    /**
     * Bit layout: mode (1 = cell) at 59, resolution at 52, base cell at 45,
     * then 15 three-bit digits; digits finer than res are 7.
     */
    private static String format(int res, int baseCell, int[] digits) {
        long h = (1L << 59) | ((long) res << 52) | ((long) baseCell << 45);
        for (int r = 1; r <= 15; r++) {
            long d = r <= res ? digits[r] : 7;
            h |= d << ((15 - r) * 3);
        }
        return Long.toHexString(h);
    }
}
