package com.example.nastok.data

import com.example.nastok.net.NasTagClient
import com.example.nastok.net.NasMediaDetail
import com.example.nastok.net.NasTagSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/** Reads NAS-owned tags without affecting playback when the service is unavailable. */
class MediaTagStore(
    private val client: NasTagClient = NasTagClient(),
    private val cache: MediaTagCache = MediaTagCache(CACHE_TTL_MS),
) {
    /**
     * Tag data is shared by the home screen, feed view model and feed activity.
     * Keeping separate stores caused each screen to download the same full tag
     * snapshot again when a feed was opened.
     */
    companion object {
        val shared: MediaTagStore by lazy(LazyThreadSafetyMode.SYNCHRONIZED) { MediaTagStore() }
        private const val CACHE_TTL_MS = 5 * 60 * 1000L
    }

    private var snapshotKey = ""
    private var snapshotAtMs = Long.MIN_VALUE
    private val snapshotLock = kotlinx.coroutines.sync.Mutex()

    suspend fun tagsFor(settings: NasSettings, videoPath: String): List<String>? {
        if (!settings.isTagApiConfigured) return null
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        cache.get(lookupPath)?.let { return it }
        // Do not wait for the optional full-library prefetch. The visible card
        // should use the small per-media request while the bulk snapshot warms
        // in the background.
        return withContext(Dispatchers.IO) {
            client.fetch(settings, lookupPath)?.also { cache.put(lookupPath, it) }
        }
    }

    suspend fun preloadAll(settings: NasSettings): Boolean {
        if (!settings.isTagApiConfigured) return false
        val key = "${settings.normalizedTagApiBaseUrl}|${settings.normalizedRootPath}"
        val now = System.currentTimeMillis()
        if (snapshotKey == key && now - snapshotAtMs < CACHE_TTL_MS) return true
        return snapshotLock.withLock {
            val lockedNow = System.currentTimeMillis()
            if (snapshotKey == key && lockedNow - snapshotAtMs < CACHE_TTL_MS) return true
            val records = withContext(Dispatchers.IO) { client.fetchAllTags(settings) } ?: return false
            records.forEach { (path, tags) ->
                mediaTagLookupPathFromNasRecord(path, settings.normalizedRootPath)?.let { lookupPath ->
                    cache.put(lookupPath, tags, lockedNow)
                }
            }
            cache.markSnapshot(lockedNow)
            snapshotKey = key
            snapshotAtMs = lockedNow
            true
        }
    }

    suspend fun update(settings: NasSettings, videoPath: String, tags: List<String>): List<String>? {
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) {
            client.update(settings, lookupPath, tags)?.also { cache.put(lookupPath, it) }
        }
    }

    suspend fun detailsFor(settings: NasSettings, videoPath: String): NasMediaDetail? {
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) { client.fetchMediaDetail(settings, lookupPath) }
    }

    suspend fun inboxPaths(settings: NasSettings): List<String>? =
        withContext(Dispatchers.IO) { client.fetchInboxPaths(settings) }

    suspend fun updateInbox(settings: NasSettings, videoPath: String, inbox: Boolean): NasMediaDetail? {
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) { client.updateInbox(settings, lookupPath, inbox) }
    }

    suspend fun suggestionsFor(settings: NasSettings, videoPath: String): List<String>? {
        val folder = tagSuggestionFolder(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) { client.fetchSuggestions(settings, folder) }
    }

    suspend fun tagSummaries(settings: NasSettings): List<NasTagSummary>? =
        withContext(Dispatchers.IO) { client.fetchTagSummaries(settings) }

    suspend fun pathsWithTags(settings: NasSettings, tags: List<String>): Set<String>? =
        withContext(Dispatchers.IO) { client.fetchTaggedPaths(settings, tags) }

    suspend fun allTaggedPaths(settings: NasSettings): Set<String>? =
        withContext(Dispatchers.IO) { client.fetchTaggedPaths(settings, taggedOnly = true) }

    suspend fun deleteTag(settings: NasSettings, tag: String): Boolean? =
        withContext(Dispatchers.IO) { client.deleteTag(settings, tag) }

    suspend fun renameTag(settings: NasSettings, sourceTag: String, targetTag: String): Boolean? =
        withContext(Dispatchers.IO) { client.renameTag(settings, sourceTag, targetTag) }

}
