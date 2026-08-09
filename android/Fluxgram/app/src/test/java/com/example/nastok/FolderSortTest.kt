package com.example.nastok

import com.example.nastok.data.db.FolderCount
import org.junit.Assert.assertEquals
import org.junit.Test

class FolderSortTest {
    @Test
    fun videoCountSortUsesDescendingCountThenName() {
        val folders = listOf(
            FolderCount("travel", 3),
            FolderCount("alpha", 8),
            FolderCount("zeta", 8),
        )

        assertEquals(
            listOf(FolderCount("alpha", 8), FolderCount("zeta", 8), FolderCount("travel", 3)),
            sortFolderCounts(folders, FolderSortMode.VIDEO_COUNT)
        )
    }

    @Test
    fun nameSortUsesAscendingFolderName() {
        val folders = listOf(
            FolderCount("zeta", 8),
            FolderCount("alpha", 3),
            FolderCount("", 1),
        )

        assertEquals(
            listOf(FolderCount("", 1), FolderCount("alpha", 3), FolderCount("zeta", 8)),
            sortFolderCounts(folders, FolderSortMode.NAME)
        )
    }
}
