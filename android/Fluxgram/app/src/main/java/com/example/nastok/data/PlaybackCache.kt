package com.example.nastok.data

import android.content.Context
import androidx.media3.database.StandaloneDatabaseProvider
import androidx.media3.datasource.cache.LeastRecentlyUsedCacheEvictor
import androidx.media3.datasource.cache.SimpleCache
import com.example.nastok.PLAYBACK_CACHE_MAX_BYTES
import java.io.File

/** Bounded on-disk cache for video byte ranges used by Media3 playback. */
object PlaybackCache {
    private const val DIR_NAME = "video_playback_cache"

    @Volatile
    private var cache: SimpleCache? = null

    fun get(context: Context): SimpleCache {
        val appContext = context.applicationContext
        return cache ?: synchronized(this) {
            cache ?: SimpleCache(
                cacheDir(appContext),
                LeastRecentlyUsedCacheEvictor(PLAYBACK_CACHE_MAX_BYTES),
                StandaloneDatabaseProvider(appContext),
            ).also { cache = it }
        }
    }

    fun cacheSize(context: Context): Long = cacheDir(context.applicationContext).sizeBytes()

    fun clear(context: Context) {
        synchronized(this) {
            cache?.release()
            cache = null
            cacheDir(context.applicationContext).deleteRecursively()
        }
    }

    private fun cacheDir(context: Context): File = File(context.cacheDir, DIR_NAME)

    private fun File.sizeBytes(): Long {
        if (!exists()) return 0L
        return walkTopDown().filter { it.isFile }.sumOf { it.length() }
    }
}
