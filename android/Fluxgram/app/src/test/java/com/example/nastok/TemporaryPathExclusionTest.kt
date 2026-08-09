package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class TemporaryPathExclusionTest {
    @Test
    fun folderExclusionMatchesChildrenButNotSimilarPrefixes() {
        val excluded = setOf("/ddd4/mp4/tickets")

        assertTrue(isPathTemporarilyExcluded("/ddd4/mp4/tickets/a.mp4", excluded))
        assertTrue(isPathTemporarilyExcluded("/ddd4/mp4/tickets/sub/b.mp4", excluded))
        assertFalse(isPathTemporarilyExcluded("/ddd4/mp4/tickets-extra/a.mp4", excluded))
        assertFalse(isPathTemporarilyExcluded("/ddd4/mp4/ticket/a.mp4", excluded))
    }

    @Test
    fun excludedFoldersAreNormalizedBeforeFiltering() {
        val paths = listOf(
            "/ddd4/mp4/tickets/a.mp4",
            "/ddd4/mp4/tickets/sub/b.mp4",
            "/ddd4/mp4/other/c.mp4",
        )

        assertEquals(
            listOf("/ddd4/mp4/other/c.mp4"),
            filterTemporarilyExcludedPaths(paths, setOf("/ddd4/mp4/tickets/")),
        )
    }
}
