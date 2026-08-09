package com.example.nastok.net

import android.media.MediaDataSource
import com.example.nastok.data.NasSettings
import okhttp3.OkHttpClient
import okhttp3.Request

/** A [MediaDataSource] that reads a remote video over HTTP Range requests using our
 *  self-signed-trusting OkHttp client. Lets MediaMetadataRetriever pull a single frame
 *  for a thumbnail without downloading the whole file or tripping on the TLS cert.
 *
 *  All reads are synchronous/blocking — call from a background thread. A small
 *  read-ahead buffer keeps the request count low even though MP4 metadata (moov) may
 *  sit at the end of the file and force back-and-forth seeks. */
class OkHttpMediaDataSource(
    private val settings: NasSettings,
    private val path: String,
    private val client: OkHttpClient,
) : MediaDataSource() {

    private var contentLength: Long = -1
    private var bufStart: Long = -1
    private var buf: ByteArray? = null

    override fun getSize(): Long {
        if (contentLength < 0) contentLength = fetchSize()
        return contentLength
    }

    override fun readAt(position: Long, buffer: ByteArray, offset: Int, size: Int): Int {
        if (size == 0) return 0
        val total = size_safe()
        if (total in 0..position) return -1   // at or past EOF

        buf?.let { b ->
            if (position >= bufStart && position < bufStart + b.size) {
                val avail = (bufStart + b.size - position).toInt()
                val n = minOf(avail, size)
                System.arraycopy(b, (position - bufStart).toInt(), buffer, offset, n)
                return n
            }
        }

        val chunk = maxOf(size, READAHEAD).toLong()
        val end = minOf(position + chunk, total) - 1
        val data = fetchRange(position, end) ?: return -1
        if (data.isEmpty()) return -1
        buf = data
        bufStart = position
        val n = minOf(data.size, size)
        System.arraycopy(data, 0, buffer, offset, n)
        return n
    }

    override fun close() {
        buf = null
        bufStart = -1
    }

    private fun size_safe(): Long = if (contentLength >= 0) contentLength else getSize()

    /** Probe total size with a 1-byte Range request; parse it from Content-Range. */
    private fun fetchSize(): Long {
        return try {
            responseFor("bytes=0-0").use { resp ->
                resp.header("Content-Range")?.substringAfterLast('/')?.toLongOrNull()
                    ?: resp.header("Content-Length")?.toLongOrNull()
                    ?: -1
            }
        } catch (_: Exception) {
            -1
        }
    }

    private fun fetchRange(start: Long, end: Long): ByteArray? {
        return try {
            responseFor("bytes=$start-$end").use { resp ->
                if (!resp.isSuccessful) null else resp.body?.bytes()
            }
        } catch (_: Exception) {
            null
        }
    }

    private fun responseFor(range: String) = DavRequestExecutor.execute(client, settings, path) { url, isRemote ->
        Request.Builder()
            .url(url)
            .header("Range", range)
            .also { DavRequestHeaders.apply(it, settings, isRemote) }
            .build()
    }

    companion object {
        // MediaMetadataRetriever probes MP4 metadata in several nearby reads. A larger
        // LAN read-ahead trades a little bandwidth for far fewer HTTP round-trips.
        private const val READAHEAD = 1024 * 1024
    }
}
