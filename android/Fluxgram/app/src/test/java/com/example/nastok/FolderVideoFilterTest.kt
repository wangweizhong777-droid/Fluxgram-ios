package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderVideoFilterTest {
    @Test
    fun blankQueryReturnsAllFolderPaths() {
        val paths = listOf("/ddd4/mp4/sunny77/1.mp4", "/ddd4/mp4/sunny77/2.mp4")

        assertEquals(paths, filterFolderVideoPaths(paths, "  "))
    }

    @Test
    fun queryMatchesFileNameCaseInsensitively() {
        val paths = listOf(
            "/ddd4/mp4/sunny77/Beach-Night.mp4",
            "/ddd4/mp4/sunny77/camera-test.mp4",
            "/ddd4/mp4/other/beach.mp4",
        )

        assertEquals(
            listOf("/ddd4/mp4/sunny77/Beach-Night.mp4"),
            filterFolderVideoPaths(paths.take(2), "beach")
        )
    }

    @Test
    fun queryMatchesFullPathWhenNeeded() {
        val paths = listOf("/ddd4/mp4/sunny77/1.mp4", "/ddd4/mp4/travel/1.mp4")

        assertEquals(listOf("/ddd4/mp4/sunny77/1.mp4"), filterFolderVideoPaths(paths, "sunny"))
    }
}
