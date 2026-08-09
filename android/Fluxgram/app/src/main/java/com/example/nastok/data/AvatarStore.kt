package com.example.nastok.data

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import com.example.nastok.toCircleAvatar
import com.example.nastok.net.DavUrl
import com.example.nastok.net.DavRequestExecutor
import com.example.nastok.net.DavRequestHeaders
import com.example.nastok.net.TrustingHttpClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.Request
import java.io.File
import java.security.MessageDigest

/** Downloads and caches folder avatar images (the cover image found inside a folder)
 *  over the self-signed-trusting OkHttp client. One small JPEG per image path under
 *  filesDir/avatars/, bounded by an LRU byte budget. */
class AvatarStore(context: Context) {

    private val dir = File(context.filesDir, "avatars").apply { mkdirs() }
    private val client by lazy { TrustingHttpClient.build() }

    @OptIn(kotlinx.coroutines.ExperimentalCoroutinesApi::class)
    private val dispatcher = Dispatchers.IO.limitedParallelism(3)

    private fun fileFor(imagePath: String): File = File(dir, md5(imagePath) + ".jpg")

    /** Return the cached avatar bitmap for [imagePath] on [settings]'s server,
     *  downloading + center-cropping it to a circle on first use. Null if unfetchable. */
    suspend fun get(settings: NasSettings, imagePath: String): Bitmap? = withContext(dispatcher) {
        loadCached(imagePath)?.let { return@withContext it }
        val bytes = download(settings, imagePath) ?: return@withContext null
        val decoded = decodeDownscaled(bytes, MAX_WIDTH) ?: return@withContext null
        val circle = toCircleAvatar(decoded)
        decoded.recycle()
        runCatching {
            fileFor(imagePath).outputStream().use { circle.compress(Bitmap.CompressFormat.PNG, 100, it) }
            trimToBudget()
        }
        circle
    }

    private fun loadCached(imagePath: String): Bitmap? {
        val f = fileFor(imagePath)
        if (!f.exists()) return null
        return try {
            f.setLastModified(System.currentTimeMillis())
            BitmapFactory.decodeFile(f.absolutePath)
        } catch (_: Exception) {
            null
        }
    }

    private fun download(settings: NasSettings, imagePath: String): ByteArray? {
        return try {
            DavRequestExecutor.execute(client, settings, imagePath) { url, isRemote ->
                Request.Builder()
                    .url(url)
                    .also { DavRequestHeaders.apply(it, settings, isRemote) }
                    .build()
            }.use { resp ->
                if (!resp.isSuccessful) null else resp.body?.bytes()
            }
        } catch (_: Exception) {
            null
        }
    }

    /** Decode with inSampleSize so a large cover image doesn't blow up memory. */
    private fun decodeDownscaled(bytes: ByteArray, maxWidth: Int): Bitmap? {
        val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
        BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
        var sample = 1
        while (bounds.outWidth / sample > maxWidth * 2) sample *= 2
        val opts = BitmapFactory.Options().apply { inSampleSize = sample }
        val decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, opts) ?: return null
        if (decoded.width <= maxWidth) return decoded
        val ratio = maxWidth.toFloat() / decoded.width
        val h = (decoded.height * ratio).toInt().coerceAtLeast(1)
        val scaled = Bitmap.createScaledBitmap(decoded, maxWidth, h, true)
        decoded.recycle()
        return scaled
    }

    private fun trimToBudget() {
        val files = dir.listFiles() ?: return
        var total = files.sumOf { it.length() }
        if (total <= MAX_BYTES) return
        files.sortedBy { it.lastModified() }.forEach { f ->
            if (total <= MAX_BYTES) return
            total -= f.length()
            f.delete()
        }
    }

    private fun md5(s: String): String =
        MessageDigest.getInstance("MD5").digest(s.toByteArray()).joinToString("") { "%02x".format(it) }

    companion object {
        private const val MAX_WIDTH = 200
        private const val MAX_BYTES = 20L * 1024 * 1024
    }

    fun cacheSize(): Long = dir.listFiles()?.sumOf { it.length() } ?: 0L

    fun clearAll() { dir.listFiles()?.forEach { it.delete() } }
}
