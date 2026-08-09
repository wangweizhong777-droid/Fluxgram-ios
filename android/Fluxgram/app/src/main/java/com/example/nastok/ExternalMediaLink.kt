package com.example.nastok

/** Resolves only a NAS-root-relative media path received from Nekogram. */
fun resolveNastokPlaybackPath(rootPath: String, relativePath: String): String? {
    val root = rootPath.trim().trimEnd('/')
    val relative = relativePath.trim().replace('\\', '/')
    if (root.isEmpty() || relative.isEmpty() || relative.startsWith('/')) return null
    val segments = relative.split('/')
    if (segments.any { it.isBlank() || it == "." || it == ".." }) return null
    return "$root/$relative"
}
