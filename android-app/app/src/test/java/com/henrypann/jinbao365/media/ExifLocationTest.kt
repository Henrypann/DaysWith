package com.henrypann.jinbao365.media

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ExifLocationTest {
    @Test
    fun realGpsRationalsAndRefsArePresent() {
        assertTrue(ExifLocation.present("31/1,13/1,1236/25", "N", "121/1,28/1,1056/25", "E"))
        assertTrue(ExifLocation.present("33/1,52/1,800/25", "S", "151/1,12/1,90/25", "W"))
    }

    @Test
    fun redactedGpsTagsAreNotReportedAsGpsKept() {
        assertFalse(ExifLocation.present("0/0,0/0,0/0", "\u0000", "0/0,0/0,0/0", "\u0000"))
        assertFalse(ExifLocation.present("0/0,0/0,0/0", "N", "0/0,0/0,0/0", "E"))
        assertFalse(ExifLocation.present("31/1,13/1,1236/25", "", "121/1,28/1,1056/25", ""))
    }

    @Test
    fun legitimateZeroCoordinatesAndNoGpsAreDifferent() {
        assertTrue(ExifLocation.present("0/1,0/1,0/1", "N", "0/1,0/1,0/1", "E"))
        assertFalse(ExifLocation.present(null, null, null, null))
    }

    @Test
    fun malformedOrOutOfRangeCoordinatesAreNotPresent() {
        listOf("NaN/1,0/1,0/1", "1/Infinity,0/1,0/1", "91/1,0/1,0/1", "-1/1,0/1,0/1",
            "31/1,60/1,0/1", "31/1,0/1,60/1", "31,0,0", "31/1,0/1").forEach {
            assertFalse(ExifLocation.present(it, "N", "121/1,0/1,0/1", "E"))
        }
        assertTrue(ExifLocation.present("90/1,0/1,0/1", "N", "180/1,0/1,0/1", "E"))
        assertFalse(ExifLocation.present("90/1,0/1,1/1", "N", "180/1,0/1,0/1", "E"))
    }
}
