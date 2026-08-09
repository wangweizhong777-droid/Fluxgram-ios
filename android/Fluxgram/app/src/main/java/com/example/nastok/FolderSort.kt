package com.example.nastok

import com.example.nastok.data.db.FolderCount

enum class FolderSortMode {
    VIDEO_COUNT,
    NAME,
}

fun sortFolderCounts(folders: List<FolderCount>, mode: FolderSortMode): List<FolderCount> {
    return when (mode) {
        FolderSortMode.VIDEO_COUNT -> folders.sortedWith(
            compareByDescending<FolderCount> { it.cnt }.thenBy { it.folder.lowercase() }
        )
        FolderSortMode.NAME -> folders.sortedBy { it.folder.lowercase() }
    }
}
