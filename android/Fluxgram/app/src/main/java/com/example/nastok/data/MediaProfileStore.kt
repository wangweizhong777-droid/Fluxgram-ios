package com.example.nastok.data

import com.example.nastok.net.NasMediaProfile
import com.example.nastok.net.NasTagClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** NAS-owned likes, favorites, notes, and source metadata for one stable media identity. */
class MediaProfileStore(
    private val client: NasTagClient = NasTagClient(),
) {
    suspend fun profileFor(settings: NasSettings, videoPath: String): NasMediaProfile? {
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) { client.fetchProfile(settings, lookupPath) }
    }

    suspend fun updateInteraction(
        settings: NasSettings,
        videoPath: String,
        liked: Boolean? = null,
        favorited: Boolean? = null,
    ): NasMediaProfile? {
        val lookupPath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) {
            client.updateProfile(settings, lookupPath, liked = liked, favorited = favorited)
        }
    }

    suspend fun favoritePaths(settings: NasSettings): Set<String>? =
        withContext(Dispatchers.IO) { client.fetchProfilePaths(settings, favorited = true) }
}
