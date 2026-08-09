package com.example.nastok.data

import com.example.nastok.net.NasMediaTrashItem
import com.example.nastok.net.NasTagClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

fun trashThumbnailSourcePath(settings: NasSettings, item: NasMediaTrashItem): String? {
    val relativePath = item.thumbnailPath.trim().trimStart('/')
    if (relativePath.isBlank()) return null
    return "${settings.normalizedRootPath}/$relativePath"
}

/** NAS-owned recycle bin. Videos are moved remotely and can be restored for seven days. */
class MediaTrashStore(
    private val client: NasTagClient = NasTagClient(),
) {
    suspend fun move(settings: NasSettings, videoPath: String): NasMediaTrashItem? {
        val relativePath = mediaTagLookupPath(videoPath, settings.normalizedRootPath) ?: return null
        return withContext(Dispatchers.IO) { client.moveToTrash(settings, relativePath) }
    }

    suspend fun items(settings: NasSettings): List<NasMediaTrashItem>? =
        withContext(Dispatchers.IO) { client.fetchMediaTrash(settings) }

    suspend fun restore(settings: NasSettings, id: String): NasMediaTrashItem? =
        withContext(Dispatchers.IO) { client.restoreMediaTrash(settings, id) }
}
