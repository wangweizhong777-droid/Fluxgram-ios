package com.example.nastok.data

import org.junit.Assert.assertFalse
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class NewVideoBaselineTest {
    @Test
    fun existingIndexWithoutBaselineNeedsBaselineRepair() {
        val result = RescanResult(total = 9931, added = 0, removed = 0)

        assertTrue(shouldRepairMissingNewVideoBaseline(indexedCount = 9931, lastSeenNew = 0L))
        assertFalse(shouldMarkScanAsSeenBaseline(previousCount = 9931, lastSeenNew = 0L, result = result))
    }

    @Test
    fun firstSuccessfulScanShouldBecomeSeenBaseline() {
        val result = RescanResult(total = 9931, added = 9931, removed = 0)

        assertTrue(shouldMarkScanAsSeenBaseline(previousCount = 0, lastSeenNew = 0L, result = result))
    }

    @Test
    fun laterScanWithNewVideosKeepsNewBadge() {
        val result = RescanResult(total = 9932, added = 1, removed = 0)

        assertFalse(shouldMarkScanAsSeenBaseline(previousCount = 9931, lastSeenNew = 1780118049130L, result = result))
        assertFalse(shouldRepairMissingNewVideoBaseline(indexedCount = 9932, lastSeenNew = 1780118049130L))
    }

    @Test
    fun successfulRescanStartsANewNewVideoWindowAtScanStart() {
        val scanStartedAt = 1780118049130L
        val previousLastSeenNew = 1780000000000L
        val result = RescanResult(total = 3500, added = 123, removed = 0)

        assertEquals(
            scanStartedAt - 1,
            newVideoBaselineAfterSuccessfulScan(
                previousCount = 3377,
                previousLastSeenNew = previousLastSeenNew,
                scanStartedAt = scanStartedAt,
                result = result,
            ),
        )
    }

    @Test
    fun firstSuccessfulScanStillMarksEverythingAsSeen() {
        val scanStartedAt = 1780118049130L
        val scanFinishedAt = 1780118059130L
        val result = RescanResult(total = 9931, added = 9931, removed = 0)

        assertEquals(
            scanFinishedAt,
            newVideoBaselineAfterSuccessfulScan(
                previousCount = 0,
                previousLastSeenNew = 0L,
                scanStartedAt = scanStartedAt,
                scanFinishedAt = scanFinishedAt,
                result = result,
            ),
        )
    }
}
