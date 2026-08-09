package com.example.nastok

fun normalizeFolderPath(folderPath: String): String =
    folderPath.trimEnd('/').let { path ->
        if (path == "/") "" else path
    }

fun folderPathFromVideoPath(videoPath: String): String =
    normalizeFolderPath(videoPath.substringBeforeLast('/', ""))

fun folderDisplayName(folderPath: String): String =
    normalizeFolderPath(folderPath).ifEmpty { "(根目录)" }

fun folderDisplayName(folderPath: String, rootPath: String): String {
    val normalizedFolder = normalizeFolderPath(folderPath)
    val normalizedRoot = normalizeFolderPath(rootPath)
    val relative = normalizedFolder.removePrefix(normalizedRoot).trimStart('/')
    return relative.ifEmpty { normalizedFolder.ifEmpty { "(根目录)" } }
}
