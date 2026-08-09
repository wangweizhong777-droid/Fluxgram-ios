package com.example.nastok

object TemporaryPathExclusions {
    private val excludedFolders = linkedSetOf<String>()

    @Synchronized
    fun addFolder(folderPath: String) {
        val normalized = normalizeFolderPath(folderPath)
        if (normalized.isNotEmpty()) excludedFolders.add(normalized)
    }

    @Synchronized
    fun currentFolders(): Set<String> = excludedFolders.toSet()

    @Synchronized
    fun filter(paths: List<String>): List<String> =
        filterTemporarilyExcludedPaths(paths, excludedFolders)

    @Synchronized
    fun clear() {
        excludedFolders.clear()
    }
}

fun filterTemporarilyExcludedPaths(paths: List<String>, excludedFolders: Set<String>): List<String> {
    if (excludedFolders.isEmpty()) return paths
    val normalizedFolders = excludedFolders.mapTo(linkedSetOf(), ::normalizeFolderPath)
    return paths.filterNot { isPathTemporarilyExcluded(it, normalizedFolders) }
}

fun isPathTemporarilyExcluded(path: String, excludedFolders: Set<String>): Boolean {
    val normalizedPath = path.trimEnd('/')
    return excludedFolders.any { folder ->
        val normalizedFolder = normalizeFolderPath(folder)
        normalizedFolder.isNotEmpty() &&
            (normalizedPath == normalizedFolder || normalizedPath.startsWith("$normalizedFolder/"))
    }
}
