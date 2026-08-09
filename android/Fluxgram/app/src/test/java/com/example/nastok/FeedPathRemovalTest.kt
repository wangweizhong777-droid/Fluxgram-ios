package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedPathRemovalTest {
    @Test
    fun removesEveryLoopedCopyOfARecycledVideoFromTheCurrentFeed() {
        assertEquals(
            listOf("one.mp4", "three.mp4"),
            removePathFromFeed(
                listOf("one.mp4", "two.mp4", "three.mp4", "two.mp4"),
                "two.mp4",
            ),
        )
    }

    @Test
    fun excludesRecycleBinPathsFromPlaybackCandidates() {
        assertEquals(
            listOf("/downloads/ddd4/keep.mp4", "/downloads/.fluxtok-trash-copy/keep.mp4"),
            excludeRecycleBinPaths(
                listOf(
                    "/downloads/ddd4/keep.mp4",
                    "/downloads/.fluxtok-trash/id-1/deleted.mp4",
                    "/downloads/.fluxtok-trash-copy/keep.mp4",
                ),
            ),
        )
    }
}
