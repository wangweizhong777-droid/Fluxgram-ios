package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.TimeZone

class FormatUtilsTest {
    @Test
    fun byteSizeUsesReadableUnits() {
        assertEquals("0 B", formatByteSize(0))
        assertEquals("512 B", formatByteSize(512))
        assertEquals("1.5 KB", formatByteSize(1536))
        assertEquals("2.0 MB", formatByteSize(2L * 1024 * 1024))
        assertEquals("1.25 GB", formatByteSize(1280L * 1024 * 1024))
    }

    @Test
    fun byteSizeTruncatesUpperBoundValuesWithinUnit() {
        assertEquals("1023.9 KB", formatByteSize(1024L * 1024 - 1))
        assertEquals("1023.9 MB", formatByteSize(1024L * 1024 * 1024 - 1))
    }

    @Test
    fun scanTimestampUsesLocalPattern() {
        val tz = TimeZone.getTimeZone("UTC")

        assertEquals("2026-06-15 08:30", formatLocalTimestamp(1781512200000L, tz))
    }
}
