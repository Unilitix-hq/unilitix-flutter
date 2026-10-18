package com.unilitix.unilitix_flutter;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import org.junit.Test;

/** Vectors from the reference H3 library (h3-py 4.5.0, H3 C 4.x). */
public class PowerH3Test {
    private static final String[][] VECTORS = {
        {"Lagos", "6.5244", "3.3792", "7", "87589c984ffffff"},
        {"Nairobi", "-1.2921", "36.8219", "7", "877a6e42cffffff"},
        {"Accra", "5.6037", "-0.187", "7", "877576970ffffff"},
        {"Abuja", "9.0765", "7.3986", "7", "8758f4691ffffff"},
        {"Johannesburg", "-26.2041", "28.0473", "7", "87bcc352cffffff"},
        {"Cairo", "30.0444", "31.2357", "7", "873e628e6ffffff"},
        {"Kinshasa", "-4.4419", "15.2663", "7", "87838eae6ffffff"},
        {"New York", "40.7128", "-74.006", "7", "872a1072cffffff"},
        {"Lagos res 0", "6.5244", "3.3792", "0", "8059fffffffffff"},
        {"Lagos res 1", "6.5244", "3.3792", "1", "8158bffffffffff"},
        {"Lagos res 9", "6.5244", "3.3792", "9", "89589c984c7ffff"},
        {"Lagos res 15", "6.5244", "3.3792", "15", "8f589c984c5532d"},
        {"Nairobi res 8", "-1.2921", "36.8219", "8", "887a6e42cbfffff"},
        {"origin", "0.0", "0.0", "7", "87754e64dffffff"},
        {"antimeridian", "0.0", "180.0", "7", "877eb5722ffffff"},
        {"south pole", "-90.0", "0.0", "7", "87f29380effffff"},
        {"north pole", "90.0", "0.0", "7", "870326233ffffff"},
        {"Reykjavik", "64.1466", "-21.9426", "7", "87075dd4bffffff"},
        {"Sydney", "-33.8688", "151.2093", "7", "87be0e35cffffff"},
        {"pentagon 870800000ffffff centre", "64.7", "10.536199", "7", "870800000ffffff"},
        {"near pentagon 870800000ffffff", "64.73", "10.516199", "7", "87080002effffff"},
        {"pentagon 871c00000ffffff centre", "50.103201", "-143.47849", "7", "871c00000ffffff"},
        {"near pentagon 871c00000ffffff", "50.133201", "-143.49849", "7", "871c00030ffffff"},
        {"pentagon 873000000ffffff centre", "39.1", "122.3", "7", "873000000ffffff"},
        {"near pentagon 873000000ffffff", "39.13", "122.28", "7", "873000022ffffff"},
        {"pentagon 874c00000ffffff centre", "23.717925", "-67.132326", "7", "874c00000ffffff"},
        {"near pentagon 874c00000ffffff", "23.747925", "-67.152326", "7", "874c00033ffffff"},
    };

    @Test
    public void matchesReferenceVectors() {
        for (String[] v : VECTORS) {
            assertEquals(v[0], v[4], PowerH3.latLngToCell(
                    Double.parseDouble(v[1]), Double.parseDouble(v[2]), Integer.parseInt(v[3])));
        }
    }

    @Test
    public void rejectsInvalidInput() {
        assertNull(PowerH3.latLngToCell(Double.NaN, 0, 7));
        assertNull(PowerH3.latLngToCell(91, 0, 7));
        assertNull(PowerH3.latLngToCell(0, 181, 7));
        assertNull(PowerH3.latLngToCell(0, 0, 16));
    }
}
