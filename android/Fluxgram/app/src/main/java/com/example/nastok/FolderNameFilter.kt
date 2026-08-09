package com.example.nastok

import com.example.nastok.data.db.FolderCount

fun filterFolderCountsByName(folders: List<FolderCount>, query: String): List<FolderCount> {
    val normalizedQuery = query.trim().lowercase()
    if (normalizedQuery.isEmpty()) return folders

    return folders.filter { item ->
        item.folder.lowercase().contains(normalizedQuery)
    }
}
