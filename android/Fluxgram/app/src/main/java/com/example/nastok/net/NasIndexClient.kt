package com.example.nastok.net

import android.content.Context
import java.net.URLEncoder
import java.nio.charset.StandardCharsets
import com.example.nastok.data.NasSettings
import okhttp3.Request
import org.json.JSONObject

data class NasIndexEntry(val path: String, val size: Long)
data class NasIndexAvatar(val folder: String, val path: String)
data class NasIndex(val videos: List<NasIndexEntry>, val avatars: List<NasIndexAvatar>)
data class NasIndexEndpoint(val url: String, val isLocal: Boolean)
data class NasIndexVersion(val etag: String, val fingerprint: String)

internal fun nasIndexUrl(endpoint: NasIndexEndpoint, rootPath: String): String =
    "${endpoint.url}?root=${URLEncoder.encode(rootPath, StandardCharsets.UTF_8.name())}"

sealed interface NasIndexFetchResult {
    data class Loaded(val index: NasIndex) : NasIndexFetchResult
    data object NotModified : NasIndexFetchResult
}

internal fun cachedEtagForRequest(
    version: NasIndexVersion?,
    fingerprint: String,
    localVideoCount: Int,
): String? = version
    ?.takeIf { localVideoCount > 0 && it.fingerprint == fingerprint }
    ?.etag

/** The LAN service is cheap to probe; the HTTPS gateway is the resilient fallback. */
fun nasIndexEndpoints(settings: NasSettings): List<NasIndexEndpoint> {
    if (settings.effectiveRemoteGatewayToken.isBlank()) return emptyList()
    return buildList {
        settings.normalizedLocalGatewayBaseUrl
            .takeIf { it.isNotBlank() }
            ?.let { add(NasIndexEndpoint("$it/api/nastok-index", isLocal = true)) }
        settings.normalizedRemoteGatewayBaseUrl
            .removeSuffix("/api/nastok-webdav")
            .takeIf { it.isNotBlank() }
            ?.let { add(NasIndexEndpoint("$it/api/nastok-index", isLocal = false)) }
    }.distinctBy { it.url }
}

/** Reuses the local Room index after a server-side ETag confirms it is still current. */
class NasIndexClient(context: Context) {
    private val preferences = context.applicationContext
        .getSharedPreferences("nastok_index_cache", Context.MODE_PRIVATE)
    private val localClient = TrustingHttpClient.localProbe()
    private val remoteClient = TrustingHttpClient.build()

    fun fetch(settings: NasSettings, localVideoCount: Int): NasIndexFetchResult? {
        val fingerprint = sourceFingerprint(settings)
        val etag = cachedEtagForRequest(storedVersion(), fingerprint, localVideoCount)
        return nasIndexEndpoints(settings).firstNotNullOfOrNull { endpoint -> runCatching {
            val request = Request.Builder()
                .url(nasIndexUrl(endpoint, settings.normalizedRootPath))
                .apply { etag?.let { header("If-None-Match", it) } }
                .also { DavRequestHeaders.apply(it, settings, isRemote = true) }
                .build()
            val client = if (endpoint.isLocal) localClient else remoteClient
            client.newCall(request).execute().use { response ->
                if (response.code == 304 && etag != null) return@use NasIndexFetchResult.NotModified
                if (!response.isSuccessful) return@use null
                val json = JSONObject(response.body?.string().orEmpty())
                val videos = json.optJSONArray("videos") ?: return@use NasIndexFetchResult.Loaded(NasIndex(emptyList(), emptyList()))
                val avatars = json.optJSONArray("avatars")
                NasIndexFetchResult.Loaded(
                    NasIndex(
                        videos = buildList {
                            for (i in 0 until videos.length()) {
                                val item = videos.optJSONObject(i) ?: continue
                                val path = item.optString("path").trim().takeIf { it.isNotEmpty() } ?: continue
                                add(NasIndexEntry(path, item.optLong("size", 0)))
                            }
                        },
                        avatars = buildList {
                            for (i in 0 until (avatars?.length() ?: 0)) {
                                val item = avatars?.optJSONObject(i) ?: continue
                                val folder = item.optString("folder").trim()
                                val path = item.optString("path").trim()
                                if (folder.isNotEmpty() && path.isNotEmpty()) add(NasIndexAvatar(folder, path))
                            }
                        },
                    ),
                ).also {
                    response.header("ETag")?.let { value -> saveVersion(NasIndexVersion(value, fingerprint)) }
                }
            }
        }.getOrNull() }
    }

    private fun storedVersion(): NasIndexVersion? {
        val etag = preferences.getString(KEY_ETAG, null)?.takeIf { it.isNotBlank() } ?: return null
        val fingerprint = preferences.getString(KEY_FINGERPRINT, null)?.takeIf { it.isNotBlank() } ?: return null
        return NasIndexVersion(etag, fingerprint)
    }

    private fun saveVersion(version: NasIndexVersion) {
        preferences.edit()
            .putString(KEY_ETAG, version.etag)
            .putString(KEY_FINGERPRINT, version.fingerprint)
            .apply()
    }

    private fun sourceFingerprint(settings: NasSettings): String = listOf(
        settings.normalizedRootPath,
        settings.normalizedLocalGatewayBaseUrl,
        settings.normalizedRemoteGatewayBaseUrl,
    ).joinToString("|")

    private companion object {
        const val KEY_ETAG = "etag"
        const val KEY_FINGERPRINT = "fingerprint"
    }
}
