package com.example.nastok.data

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.MediaMetadataRetriever
import android.util.LruCache
import com.example.nastok.net.OkHttpMediaDataSource
import com.example.nastok.net.TrustingHttpClient
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.async
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.TimeUnit

/** Two-level thumbnail cache: a small in-memory LRU plus a bounded disk LRU.
 *
 * Missing thumbnails are generated lazily over HTTP Range requests. Generation is
 * deduplicated app-wide, so the same video cannot be extracted repeatedly when a row is
 * rebound quickly while scrolling. */
class ThumbnailStore(context: android.content.Context) {

    private val appContext = context.applicationContext
    private val dir = File(appContext.filesDir, CACHE_DIR).apply { mkdirs() }
    private val legacyDir = File(appContext.filesDir, LEGACY_CACHE_DIR)
    private val client by lazy {
        TrustingHttpClient.build().newBuilder()
            .callTimeout(THUMB_REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(THUMB_REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()
    }

    init {
        // v1 cached several malformed remote frames. Remove it once instead of forcing
        // the user to clear app storage manually.
        if (legacyDir.exists()) legacyDir.deleteRecursively()
    }

    private fun fileFor(path: String): File = File(dir, md5(path) + ".jpg")

    fun has(path: String): Boolean = fileFor(path).exists()

    /** Save a playback frame as a compact JPEG. Best-effort: thumbnails are optional. */
    fun save(path: String, bitmap: Bitmap) {
        try {
            val scaled = downscale(bitmap, MAX_WIDTH)
            fileFor(path).outputStream().use { out ->
                scaled.compress(Bitmap.CompressFormat.JPEG, JPEG_QUALITY, out)
            }
            if (scaled !== bitmap) scaled.recycle()
            cacheDecodedFile(path)
            trimToBudget()
        } catch (_: Exception) {
            // Keep playback independent from thumbnail failures.
        }
    }

    /** Load a cached thumbnail and refresh its disk-LRU timestamp. */
    fun load(path: String): Bitmap? {
        memoryCache.get(path)?.let { return it }
        val file = fileFor(path)
        if (!file.exists()) return null
        return try {
            file.setLastModified(System.currentTimeMillis())
            BitmapFactory.decodeFile(file.absolutePath)?.also { memoryCache.put(path, it) }
        } catch (_: Exception) {
            null
        }
    }

    /** Return a cached thumbnail, or generate it once for all concurrent callers. */
    suspend fun getOrGenerate(settings: NasSettings, path: String): Bitmap? {
        load(path)?.let { return it }
        val task = inFlight[path] ?: synchronized(inFlight) {
            inFlight[path] ?: createGenerationTask(settings, path)
        }
        task.await()
        return load(path)
    }

    private fun createGenerationTask(settings: NasSettings, path: String): Deferred<Unit> {
        return generationScope.async(start = CoroutineStart.LAZY) {
            if (load(path) == null) {
                val frame = withContext(generationDispatcher) {
                    grabRemoteFrame(settings, path)
                }
                if (frame != null) {
                    save(path, frame)
                    frame.recycle()
                }
            }
        }.also { task ->
            inFlight[path] = task
            task.invokeOnCompletion { inFlight.remove(path, task) }
            task.start()
        }
    }

    /** Pull a representative frame. Frame zero is usually much faster over WebDAV; use
     *  the one-second mark only when the first sync frame cannot be decoded. */
    private fun grabRemoteFrame(settings: NasSettings, path: String): Bitmap? {
        val retriever = MediaMetadataRetriever()
        return try {
            retriever.setDataSource(OkHttpMediaDataSource(settings, path, client))
            val raw = retriever.getFrameAtTime(0, MediaMetadataRetriever.OPTION_CLOSEST_SYNC)
                ?: retriever.getFrameAtTime(
                    1_000_000,
                    MediaMetadataRetriever.OPTION_CLOSEST_SYNC,
                )
                ?: return null
            normalizeRotation(
                raw,
                retriever.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)
                    ?.toIntOrNull() ?: 0,
            )
        } catch (_: Exception) {
            null
        } finally {
            try {
                retriever.release()
            } catch (_: Exception) {
                // Ignore retriever cleanup failures.
            }
        }
    }

    /** Some containers expose an encoded landscape frame plus rotation metadata.
     *  Normalize that once in the cache so grid ImageViews never display it sideways or
     *  with an apparently stretched aspect ratio. */
    private fun normalizeRotation(src: Bitmap, rotation: Int): Bitmap {
        val normalized = ((rotation % 360) + 360) % 360
        if (normalized == 0) return src
        val out = Bitmap.createBitmap(
            src,
            0,
            0,
            src.width,
            src.height,
            Matrix().apply { postRotate(normalized.toFloat()) },
            true,
        )
        if (out !== src) src.recycle()
        return out
    }

    private fun cacheDecodedFile(path: String) {
        val file = fileFor(path)
        BitmapFactory.decodeFile(file.absolutePath)?.let { memoryCache.put(path, it) }
    }

    private fun trimToBudget() {
        val files = dir.listFiles() ?: return
        var total = files.sumOf { it.length() }
        if (total <= MAX_DISK_BYTES) return
        files.sortedBy { it.lastModified() }.forEach { file ->
            if (total <= MAX_DISK_BYTES) return
            total -= file.length()
            file.delete()
        }
    }

    private fun downscale(src: Bitmap, maxWidth: Int): Bitmap {
        if (src.width <= maxWidth) return src
        val ratio = maxWidth.toFloat() / src.width
        val height = (src.height * ratio).toInt().coerceAtLeast(1)
        return Bitmap.createScaledBitmap(src, maxWidth, height, true)
    }

    private fun md5(value: String): String {
        val bytes = MessageDigest.getInstance("MD5").digest(value.toByteArray())
        return bytes.joinToString("") { "%02x".format(it) }
    }

    fun cacheSize(): Long = dir.listFiles()?.sumOf { it.length() } ?: 0L

    fun clearAll() {
        memoryCache.evictAll()
        dir.listFiles()?.forEach { it.delete() }
    }

    companion object {
        private const val CACHE_DIR = "thumbs_v2"
        private const val LEGACY_CACHE_DIR = "thumbs"
        private const val MAX_WIDTH = 320
        private const val JPEG_QUALITY = 80
        private const val MAX_MEMORY_BYTES = 16 * 1024 * 1024
        private const val MAX_DISK_BYTES = 80L * 1024 * 1024
        private const val THUMB_REQUEST_TIMEOUT_SECONDS = 8L

        private val memoryCache = object : LruCache<String, Bitmap>(MAX_MEMORY_BYTES) {
            override fun sizeOf(key: String, value: Bitmap): Int = value.byteCount
        }

        @OptIn(ExperimentalCoroutinesApi::class)
        private val generationDispatcher = Dispatchers.IO.limitedParallelism(5)
        private val generationScope = CoroutineScope(SupervisorJob() + generationDispatcher)
        private val inFlight = ConcurrentHashMap<String, Deferred<Unit>>()
    }
}
