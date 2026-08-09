package com.example.nastok.data

import java.text.Normalizer

/** Converts a WebDAV video path into the root-relative identity used by TGAPP. */
fun mediaTagLookupPath(videoPath: String, rootPath: String): String? {
    val raw = videoPath.trim()
    if (raw.isEmpty() || raw.endsWith('/') || raw.contains('\\') || raw.contains('\u0000')) return null

    val root = rootPath.trim().replace('\\', '/').trimEnd('/').let {
        if (it.startsWith('/')) it else "/$it"
    }
    val relative = when {
        raw.startsWith('/') -> {
            if (!raw.startsWith("$root/")) return null
            raw.removePrefix("$root/")
        }
        else -> raw
    }
    val parts = relative.split('/').filter { it.isNotEmpty() }
    if (parts.isEmpty() || parts.any { it == "." || it == ".." }) return null
    return Normalizer.normalize(parts.joinToString("/"), Normalizer.Form.NFC)
}

/** Converts the NAS tag API's download-root path into FluxTok's root-relative identity. */
fun mediaTagLookupPathFromNasRecord(recordPath: String, rootPath: String): String? {
    val raw = recordPath.trim().replace('\\', '/').trim('/')
    if (raw.isEmpty() || raw.contains('\u0000')) return null
    val root = rootPath.trim().replace('\\', '/').trim('/').let {
        if (it.startsWith('/')) it else it
    }
    val relative = when {
        root.isNotEmpty() && raw == root -> return null
        root.isNotEmpty() && raw.startsWith("$root/") -> raw.removePrefix("$root/")
        else -> raw
    }
    val parts = relative.split('/').filter { it.isNotEmpty() }
    if (parts.isEmpty() || parts.any { it == "." || it == ".." }) return null
    return Normalizer.normalize(parts.joinToString("/"), Normalizer.Form.NFC)
}

/** Normalizes the compact comma-separated format used by the playback editor. */
fun parseManualTags(input: String): List<String> {
    if (input.trim() == "添加标签") return emptyList()
    val unique = LinkedHashMap<String, String>()
    input.split(',', '，', '\n', '\r').forEach { raw ->
        val tag = raw.trim().replace(Regex("\\s+"), " ")
        if (tag.isNotEmpty()) unique.putIfAbsent(tag.lowercase(), tag)
    }
    return unique.values.toList()
}

/** Empty means the global tag catalogue; otherwise scope suggestions to the media folder. */
fun tagSuggestionFolder(videoPath: String, rootPath: String): String? {
    if (videoPath.isBlank()) return ""
    return mediaTagLookupPath(videoPath, rootPath)?.substringBeforeLast('/', "")
}

data class IndexedTagClassification(
    val tagged: List<String>,
    val untagged: List<String>,
)

/** Splits the local index by the NAS-owned tag identities without treating invalid paths as untagged. */
fun classifyIndexedVideosByTags(
    indexedPaths: List<String>,
    rootPath: String,
    taggedPaths: Set<String>,
): IndexedTagClassification {
    val tagged = mutableListOf<String>()
    val untagged = mutableListOf<String>()
    for (path in indexedPaths) {
        val lookupPath = mediaTagLookupPath(path, rootPath) ?: continue
        if (lookupPath in taggedPaths) tagged += path else untagged += path
    }
    return IndexedTagClassification(tagged = tagged, untagged = untagged)
}

/** Small process-local TTL cache. Empty tag results are cached too. */
class MediaTagCache(private val ttlMs: Long) {
    private data class Entry(val tags: List<String>, val savedAtMs: Long)

    private val entries = mutableMapOf<String, Entry>()
    private var snapshotAtMs = Long.MIN_VALUE

    @Synchronized
    fun get(path: String, nowMs: Long = System.currentTimeMillis()): List<String>? {
        val entry = entries[path]
        if (entry != null) {
            if (nowMs - entry.savedAtMs >= ttlMs) {
                entries.remove(path)
                return null
            }
            return entry.tags
        }
        return if (snapshotAtMs != Long.MIN_VALUE && nowMs - snapshotAtMs < ttlMs) emptyList() else null
    }

    @Synchronized
    fun put(path: String, tags: List<String>, nowMs: Long = System.currentTimeMillis()) {
        entries[path] = Entry(tags.toList(), nowMs)
    }

    @Synchronized
    fun markSnapshot(nowMs: Long = System.currentTimeMillis()) {
        snapshotAtMs = nowMs
    }
}
