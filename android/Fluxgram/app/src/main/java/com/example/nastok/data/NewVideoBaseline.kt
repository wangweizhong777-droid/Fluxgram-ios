package com.example.nastok.data

fun shouldMarkScanAsSeenBaseline(
    previousCount: Int,
    lastSeenNew: Long,
    result: RescanResult,
): Boolean =
    lastSeenNew == 0L &&
        previousCount == 0 &&
        result.total > 0 &&
        result.added == result.total

fun shouldRepairMissingNewVideoBaseline(indexedCount: Int, lastSeenNew: Long): Boolean =
    lastSeenNew == 0L && indexedCount > 0

fun newVideoBaselineAfterSuccessfulScan(
    previousCount: Int,
    previousLastSeenNew: Long,
    scanStartedAt: Long,
    scanFinishedAt: Long = System.currentTimeMillis(),
    result: RescanResult,
): Long =
    if (shouldMarkScanAsSeenBaseline(previousCount, previousLastSeenNew, result)) {
        scanFinishedAt
    } else {
        scanStartedAt - 1
    }
