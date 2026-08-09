package com.example.nastok

fun filterFolderVideoPaths(paths: List<String>, query: String): List<String> {
    val normalizedQuery = query.trim().lowercase()
    if (normalizedQuery.isEmpty()) return paths

    return paths.filter { path ->
        val fileName = path.substringAfterLast('/')
        fileName.lowercase().contains(normalizedQuery) ||
            path.lowercase().contains(normalizedQuery)
    }
}
