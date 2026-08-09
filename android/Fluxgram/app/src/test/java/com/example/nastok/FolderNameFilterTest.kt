package com.example.nastok

import com.example.nastok.data.db.FolderCount
import org.junit.Assert.assertEquals
import org.junit.Test

class FolderNameFilterTest {
    @Test
    fun blankQueryReturnsAllFolders() {
        val folders = listOf(FolderCount("sunny77", 12), FolderCount("travel", 4))

        assertEquals(folders, filterFolderCountsByName(folders, "  "))
    }

    @Test
    fun queryMatchesFolderNameCaseInsensitively() {
        val folders = listOf(
            FolderCount("Sunny77", 12),
            FolderCount("travel", 4),
            FolderCount("camera", 9),
        )

        assertEquals(
            listOf(FolderCount("Sunny77", 12)),
            filterFolderCountsByName(folders, "sunny")
        )
    }

    @Test
    fun queryCanMatchNestedFolderPath() {
        val folders = listOf(FolderCount("ddd4/mp4/sunny77", 12), FolderCount("ddd4/mp4/travel", 4))

        assertEquals(
            listOf(FolderCount("ddd4/mp4/sunny77", 12)),
            filterFolderCountsByName(folders, "mp4/sunny")
        )
    }
}
