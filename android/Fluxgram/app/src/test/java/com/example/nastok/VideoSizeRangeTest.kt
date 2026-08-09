package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoSizeRangeTest {
    private val mb = 1024L * 1024L

    @Test
    fun presetsUseNonOverlappingBoundaries() {
        val small = VideoSizeRangePreset.SMALL.range
        val medium = VideoSizeRangePreset.MEDIUM.range

        assertTrue(small.includes(49L * 1024L * 1024L))
        assertFalse(small.includes(50L * 1024L * 1024L))
        assertTrue(medium.includes(50L * 1024L * 1024L))
    }

    @Test
    fun largePresetStopsBeforeOneGigabyteAndHugeStartsThere() {
        val large = VideoSizeRangePreset.LARGE.range
        val huge = VideoSizeRangePreset.HUGE.range
        val oneGb = 1024L * 1024L * 1024L

        assertFalse(large.includes(oneGb))
        assertTrue(huge.includes(oneGb))
    }

    @Test
    fun dialogLabelsDescribePresetRanges() {
        assertEquals(
            listOf("0-50MB", "50-200MB", "200MB-1GB", "1GB以上"),
            VideoSizeRangePreset.entries.map { it.label }
        )
    }

    @Test
    fun parsesCustomMegabyteRange() {
        val range = parseCustomVideoSizeRangeMb("100", "500")

        assertEquals(100L * mb, range?.minBytes)
        assertEquals(500L * mb, range?.maxBytesExclusive)
        assertTrue(range!!.includes(100L * mb))
        assertFalse(range.includes(500L * mb))
    }

    @Test
    fun blankMinimumDefaultsToZeroAndBlankMaximumIsOpenEnded() {
        val range = parseCustomVideoSizeRangeMb("", "")

        assertEquals(0L, range?.minBytes)
        assertNull(range?.maxBytesExclusive)
        assertTrue(range!!.includes(30_000L * mb))
    }

    @Test
    fun rejectsInvalidCustomRanges() {
        assertNull(parseCustomVideoSizeRangeMb("abc", "500"))
        assertNull(parseCustomVideoSizeRangeMb("-1", "500"))
        assertNull(parseCustomVideoSizeRangeMb("500", "500"))
        assertNull(parseCustomVideoSizeRangeMb("501", "500"))
    }
}
