package com.example.nastok.net

import com.example.nastok.data.NasSettings
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.net.URLDecoder

/** One entry returned by a PROPFIND. */
data class DavEntry(
    val path: String,      // server-relative, decoded (e.g. /ddd4/mp4/片/a.mp4)
    val isDir: Boolean,
    val size: Long,
)

/** Minimal WebDAV client: PROPFIND listing + recursive scan, built on OkHttp.
 *  Handles self-signed TLS and URL-encodes path segments so Chinese names work. */
class WebDavClient(
    private val settings: NasSettings,
    private val client: OkHttpClient = TrustingHttpClient.build(),
) {
    /** List immediate children of a directory (Depth: 1). Returns children only,
     *  excluding the directory itself. Throws on HTTP/network error. */
    fun list(dirPath: String): List<DavEntry> {
        val body = PROPFIND_BODY.toRequestBody("application/xml".toMediaType())
        DavRequestExecutor.execute(client, settings, dirPath) { url, isRemote ->
            Request.Builder()
                .url(url)
                .method("PROPFIND", body)
                .header("Depth", "1")
                .also { DavRequestHeaders.apply(it, settings, isRemote) }
                .build()
        }.use { resp ->
            if (!resp.isSuccessful) {
                android.util.Log.e("WebDav", "PROPFIND ${resp.code} for $dirPath")
                throw RuntimeException("PROPFIND ${resp.code} for $dirPath")
            }
            val xml = resp.body?.string().orEmpty()
            return parseMultistatus(xml, dirPath)
        }
    }

    /** Result of a connectivity test, with enough detail to tell the user what's wrong. */
    sealed class TestResult {
        data class Ok(val itemCount: Int) : TestResult()
        object Unreachable : TestResult()        // network/DNS/TLS — server not responding
        object AuthFailed : TestResult()         // 401/403 — bad username/password
        object PathMissing : TestResult()        // 404 — root path doesn't exist
        data class HttpError(val code: Int) : TestResult()
    }

    /** Probe the configured root path with a shallow PROPFIND (Depth 0) so the user can
     *  verify address/credentials/path before scanning. Runs on the calling thread. */
    fun testConnection(): TestResult {
        val body = PROPFIND_BODY.toRequestBody("application/xml".toMediaType())
        return try {
            DavRequestExecutor.execute(client, settings, settings.normalizedRootPath) { url, isRemote ->
                Request.Builder()
                    .url(url)
                    .method("PROPFIND", body)
                    .header("Depth", "1")
                    .also { DavRequestHeaders.apply(it, settings, isRemote) }
                    .build()
            }.use { resp ->
                when {
                    resp.isSuccessful -> {
                        val xml = resp.body?.string().orEmpty()
                        TestResult.Ok(parseMultistatus(xml, settings.normalizedRootPath).size)
                    }
                    resp.code == 401 || resp.code == 403 -> TestResult.AuthFailed
                    resp.code == 404 -> TestResult.PathMissing
                    else -> TestResult.HttpError(resp.code)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e("WebDav", "testConnection failed", e)
            TestResult.Unreachable
        }
    }

    // PARSE_AND_SCAN
    /** Parse a DAV multistatus response into entries, decoding hrefs to server-relative
     *  paths and skipping the queried directory itself. */
    private fun parseMultistatus(xml: String, queriedDir: String): List<DavEntry> {
        val out = ArrayList<DavEntry>()
        val factory = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }
        val parser = factory.newPullParser()
        parser.setInput(xml.reader())

        var href: String? = null
        var isDir = false
        var size = 0L
        var inResourceType = false

        val queriedNorm = normalizeForCompare(queriedDir)

        var event = parser.eventType
        while (event != XmlPullParser.END_DOCUMENT) {
            val name = parser.name
            when (event) {
                XmlPullParser.START_TAG -> when (name) {
                    "response" -> { href = null; isDir = false; size = 0L }
                    "resourcetype" -> inResourceType = true
                    "collection" -> if (inResourceType) isDir = true
                    "href" -> href = parser.nextText().trim()
                    "getcontentlength" -> size = parser.nextText().trim().toLongOrNull() ?: 0L
                }
                XmlPullParser.END_TAG -> when (name) {
                    "resourcetype" -> inResourceType = false
                    "response" -> {
                        val h = href
                        if (h != null) {
                            val path = hrefToPath(h)
                            if (normalizeForCompare(path) != queriedNorm) {
                                out.add(DavEntry(path, isDir, size))
                            }
                        }
                    }
                }
            }
            event = parser.next()
        }
        return out
    }

    /** An href may be a full URL or absolute path, and is percent-encoded. Reduce it
     *  to a decoded server-relative path. */
    private fun hrefToPath(href: String): String {
        var p = href
        val schemeIdx = p.indexOf("://")
        if (schemeIdx >= 0) {
            val afterScheme = p.substring(schemeIdx + 3)
            val slash = afterScheme.indexOf('/')
            p = if (slash >= 0) afterScheme.substring(slash) else "/"
        }
        return try {
            URLDecoder.decode(p, "UTF-8")
        } catch (e: Exception) {
            p
        }
    }

    private fun normalizeForCompare(path: String): String =
        path.trimEnd('/').ifEmpty { "/" }

    /** Recursively walk [startPath], invoking [onVideo] for each video file found,
     *  [onFolderImage] once per folder that contains a usable avatar image (dir path +
     *  chosen image path), and [onProgress] with (videosSoFar, foldersScanned)
     *  periodically. Runs on the calling thread (use a background dispatcher). */
    fun scan(
        startPath: String,
        onVideo: (DavEntry) -> Unit,
        onProgress: (videos: Int, folders: Int) -> Unit,
        onFolderImage: (folderPath: String, imagePath: String) -> Unit = { _, _ -> },
        shouldStop: () -> Boolean = { false },
    ) {
        var videos = 0
        var folders = 0
        val queue = ArrayDeque<String>()
        queue.add(startPath)

        while (queue.isNotEmpty() && !shouldStop()) {
            val dir = queue.removeFirst()
            folders++
            val children = try {
                list(dir)
            } catch (e: Exception) {
                emptyList()  // skip unreadable folders, keep going
            }
            val images = ArrayList<String>()
            for (entry in children) {
                if (entry.isDir) {
                    if (entry.path.trimEnd('/').substringAfterLast('/') == ".fluxtok-trash") continue
                    queue.add(entry.path)
                } else if (isVideo(entry.path) && entry.size > 0) {
                    // size > 0 skips empty/placeholder files that would 416 on playback
                    videos++
                    onVideo(entry)
                } else if (isImage(entry.path) && entry.size > 0) {
                    images.add(entry.path)
                }
            }
            pickAvatar(images)?.let { onFolderImage(dir, it) }
            onProgress(videos, folders)
        }
    }

    private fun isVideo(path: String): Boolean {
        val lower = path.substringAfterLast('.', "").lowercase()
        return lower in VIDEO_EXTS
    }

    private fun isImage(path: String): Boolean {
        val lower = path.substringAfterLast('.', "").lowercase()
        return lower in IMAGE_EXTS
    }

    /** Choose a folder's avatar from its images: prefer conventional cover names, else
     *  fall back to the first image (case-insensitive, alphabetical for stability). */
    private fun pickAvatar(images: List<String>): String? {
        if (images.isEmpty()) return null
        val byName = images.sortedBy { it.substringAfterLast('/').lowercase() }
        val preferred = byName.firstOrNull { img ->
            val name = img.substringAfterLast('/').substringBeforeLast('.').lowercase()
            name in AVATAR_NAMES
        }
        return preferred ?: byName.first()
    }

    /** Full, percent-encoded URL for streaming a video at [path]. */
    fun streamUrl(path: String): String = DavUrl.streamUrl(settings, path)

    companion object {
        private const val PROPFIND_BODY =
            """<?xml version="1.0" encoding="utf-8"?>""" +
            """<d:propfind xmlns:d="DAV:"><d:prop>""" +
            """<d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>"""

        private val VIDEO_EXTS = setOf(
            "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "ts", "mpg", "mpeg", "3gp"
        )

        private val IMAGE_EXTS = setOf("jpg", "jpeg", "png", "webp", "bmp", "gif")

        /** File names (without extension, lowercased) treated as a folder's cover image. */
        private val AVATAR_NAMES = setOf(
            "cover", "folder", "poster", "avatar", "thumb", "thumbnail", "封面", "头像"
        )
    }
}
