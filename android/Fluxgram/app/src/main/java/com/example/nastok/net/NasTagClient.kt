package com.example.nastok.net

import android.util.Log
import com.example.nastok.data.NasSettings
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import org.json.JSONArray
import org.json.JSONObject
import java.net.URLEncoder

internal fun tagUpdatePayload(tags: List<String>): String =
    JSONObject().put("tags", JSONArray(tags)).toString()

internal fun tagSuggestionsUrl(baseUrl: String, folder: String): String {
    val encodedFolder = URLEncoder.encode(folder, "UTF-8").replace("+", "%20")
    return "${baseUrl.trimEnd('/')}/api/tags?subdir=$encodedFolder&limit=500"
}

internal fun tagDeleteUrl(baseUrl: String, tag: String): String {
    val encodedTag = URLEncoder.encode(tag, "UTF-8").replace("+", "%20")
    return "${baseUrl.trimEnd('/')}/api/tags?tag=$encodedTag"
}

internal fun tagRenameUrl(baseUrl: String, tag: String): String = tagDeleteUrl(baseUrl, tag)

internal fun tagRenamePayload(name: String): String = JSONObject().put("name", name).toString()

data class NasTagSummary(
    val name: String,
    val usageCount: Int,
)

internal fun parseTagSummaries(body: String): List<NasTagSummary> {
    val values = JSONObject(body).optJSONArray("tags") ?: return emptyList()
    return buildList {
        for (index in 0 until values.length()) {
            val item = values.optJSONObject(index) ?: continue
            val name = item.optString("name").trim()
            if (name.isNotEmpty()) add(NasTagSummary(name, item.optInt("usageCount").coerceAtLeast(0)))
        }
    }
}

internal fun taggedMediaUrl(baseUrl: String, tags: List<String>, taggedOnly: Boolean): String {
    val base = "${baseUrl.trimEnd('/')}/api/tagged-media"
    return when {
        taggedOnly -> "$base?tagged=true"
        tags.isNotEmpty() -> {
            val encodedTags = URLEncoder.encode(tags.joinToString(","), "UTF-8").replace("+", "%20")
            "$base?tags=$encodedTags"
        }
        else -> base
    }
}

internal fun allTaggedMediaUrl(baseUrl: String): String =
    "${baseUrl.trimEnd('/')}/api/tagged-media?tagged=true&limit=20000"

internal fun parseTaggedMediaTags(body: String): Map<String, List<String>> {
    val media = JSONObject(body).optJSONArray("media") ?: return emptyMap()
    return buildMap {
        for (index in 0 until media.length()) {
            val item = media.optJSONObject(index) ?: continue
            val path = item.optString("path").trim().takeIf { it.isNotEmpty() } ?: continue
            val values = item.optJSONArray("tags") ?: continue
            val tags = buildList {
                for (tagIndex in 0 until values.length()) {
                    values.optString(tagIndex).trim().takeIf { it.isNotEmpty() }?.let(::add)
                }
            }
            if (tags.isNotEmpty()) put(path, tags)
        }
    }
}

internal fun mediaProfileUrl(baseUrl: String, relativePath: String): String {
    val encodedPath = URLEncoder.encode(relativePath, "UTF-8").replace("+", "%20")
    return "${baseUrl.trimEnd('/')}/api/media-profile?path=$encodedPath"
}

internal fun mediaDetailUrl(baseUrl: String, relativePath: String): String {
    val encodedPath = URLEncoder.encode(relativePath, "UTF-8").replace("+", "%20")
    return "${baseUrl.trimEnd('/')}/api/media-detail?path=$encodedPath"
}

internal fun inboxMediaUrl(baseUrl: String, limit: Int = 500): String {
    val normalizedLimit = limit.coerceIn(1, 2000)
    return "${baseUrl.trimEnd('/')}/api/download-history?inbox=true&limit=$normalizedLimit"
}

internal fun parseInboxMediaPaths(body: String): List<String> {
    val values = JSONObject(body).optJSONArray("history") ?: return emptyList()
    return buildList {
        for (index in 0 until values.length()) {
            val item = values.optJSONObject(index) ?: continue
            val folder = item.optString("downloadSubdir").trim().trim('/')
            val file = item.optString("fileName").trim().trim('/')
            if (file.isNotEmpty() && !file.contains("..") && !file.contains('\\')) {
                add(if (folder.isEmpty()) file else "$folder/$file")
            }
        }
    }.distinct()
}

internal fun mediaProfilesUrl(baseUrl: String, liked: Boolean = false, favorited: Boolean = false): String {
    val base = "${baseUrl.trimEnd('/')}/api/media-profiles"
    return when {
        liked -> "$base?liked=true"
        favorited -> "$base?favorited=true"
        else -> base
    }
}

internal fun mediaTrashUrl(baseUrl: String): String = "${baseUrl.trimEnd('/')}/api/media-trash"

data class NasMediaTrashItem(
    val id: String,
    val path: String,
    val deletedAt: String,
    val expiresAt: String,
    val thumbnailPath: String = "",
)

internal fun parseMediaTrashItems(body: String): List<NasMediaTrashItem> {
    val values = JSONObject(body).optJSONArray("items") ?: return emptyList()
    return buildList {
        for (index in 0 until values.length()) {
            val item = values.optJSONObject(index) ?: continue
            val id = item.optString("id").trim()
            val path = item.optString("path").trim()
            val deletedAt = item.optString("deletedAt").trim()
            val expiresAt = item.optString("expiresAt").trim()
            if (id.isNotEmpty() && path.isNotEmpty() && expiresAt.isNotEmpty()) {
                add(NasMediaTrashItem(
                    id = id,
                    path = path,
                    deletedAt = deletedAt,
                    expiresAt = expiresAt,
                    thumbnailPath = item.optString("thumbnailPath").trim(),
                ))
            }
        }
    }
}

private fun parseMediaTrashItem(body: String): NasMediaTrashItem? {
    val item = JSONObject(body).optJSONObject("item") ?: return null
    return parseMediaTrashItems(JSONObject().put("items", JSONArray().put(item)).toString()).firstOrNull()
}

internal fun mediaProfileUpdatePayload(
    liked: Boolean? = null,
    favorited: Boolean? = null,
    note: String? = null,
): String = JSONObject().apply {
    liked?.let { put("liked", it) }
    favorited?.let { put("favorited", it) }
    note?.let { put("note", it) }
}.toString()

data class NasMediaProfile(
    val liked: Boolean = false,
    val favorited: Boolean = false,
    val note: String = "",
    val sourceLabel: String = "",
    val sourceUrl: String = "",
)

data class NasMediaDetail(
    val id: String = "",
    val fileName: String = "",
    val fileSize: Long = 0L,
    val relativePath: String = "",
    val outputFile: String = "",
    val status: String = "",
    val downloadedAt: String = "",
    val tags: List<String> = emptyList(),
    val note: String = "",
    val inbox: Boolean = false,
    val sourceTitle: String = "",
    val sourceText: String = "",
    val sourceLabel: String = "",
    val sourceUrl: String = "",
    val sourceDialogId: String = "",
    val sourceMessageId: Int = 0,
    val sourceRootMessageId: Int = 0,
    val ruleId: String = "",
    val ruleApplied: Boolean = false,
)

internal fun parseMediaDetail(body: String): NasMediaDetail? {
    val item = JSONObject(body)
    if (!item.optBoolean("found")) return null
    val source = item.optJSONObject("source")
    val rule = item.optJSONObject("rule")
    val tags = item.optJSONArray("tags")
    return NasMediaDetail(
        id = item.optString("id").trim(),
        fileName = item.optString("fileName").trim(),
        fileSize = item.optLong("fileSize").coerceAtLeast(0L),
        relativePath = item.optString("relativePath").trim(),
        outputFile = item.optString("outputFile").trim(),
        status = item.optString("status").trim(),
        downloadedAt = item.optString("downloadedAt").trim(),
        tags = buildList {
            for (index in 0 until (tags?.length() ?: 0)) {
                tags?.optString(index)?.trim()?.takeIf { it.isNotEmpty() }?.let(::add)
            }
        },
        note = item.optString("note").trim(),
        inbox = item.optBoolean("inbox"),
        sourceTitle = source?.optString("title")?.trim().orEmpty(),
        sourceText = source?.optString("text")?.trim().orEmpty(),
        sourceLabel = source?.optString("label")?.trim().orEmpty(),
        sourceUrl = source?.optString("url")?.trim().orEmpty(),
        sourceDialogId = source?.optString("dialogId")?.trim().orEmpty(),
        sourceMessageId = source?.optInt("messageId")?.coerceAtLeast(0) ?: 0,
        sourceRootMessageId = source?.optInt("rootMessageId")?.coerceAtLeast(0) ?: 0,
        ruleId = rule?.optString("id")?.trim().orEmpty(),
        ruleApplied = rule?.optBoolean("applied") ?: false,
    )
}

/** Optional read-only client for the TGAPP NAS tag endpoint. */
class NasTagClient {
    private companion object {
        const val LOG_TAG = "NasTagClient"
    }

    private val client = TrustingHttpClient.build()

    fun fetch(settings: NasSettings, relativePath: String): List<String>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching<List<String>?> {
            val encodedPath = URLEncoder.encode(relativePath, "UTF-8").replace("+", "%20")
            val url = "${settings.normalizedTagApiBaseUrl}/api/media-tags?path=$encodedPath"
            val request = Request.Builder()
                .url(url)
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val values = JSONObject(response.body?.string().orEmpty()).optJSONArray("tags")
                    ?: return@use emptyList<String>()
                buildList<String> {
                    for (index in 0 until values.length()) {
                        values.optString(index).trim().takeIf { it.isNotEmpty() }?.let(::add)
                    }
                }
            }
        }.getOrNull()
    }

    fun fetchMediaDetail(settings: NasSettings, relativePath: String): NasMediaDetail? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaDetailUrl(settings.normalizedTagApiBaseUrl, relativePath))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaDetail(response.body?.string().orEmpty())
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Media detail request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchInboxPaths(settings: NasSettings, limit: Int = 500): List<String>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(inboxMediaUrl(settings.normalizedTagApiBaseUrl, limit))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseInboxMediaPaths(response.body?.string().orEmpty())
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Inbox request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun updateInbox(settings: NasSettings, relativePath: String, inbox: Boolean): NasMediaDetail? {
        if (!settings.isTagApiConfigured || relativePath.isBlank()) return null
        return runCatching {
            val request = Request.Builder()
                .url("${settings.normalizedTagApiBaseUrl}/api/media-inbox")
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .put(JSONObject().put("path", relativePath).put("inbox", inbox)
                    .toString().toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaDetail(response.body?.string().orEmpty())
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Inbox update failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun update(settings: NasSettings, relativePath: String, tags: List<String>): List<String>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val encodedPath = URLEncoder.encode(relativePath, "UTF-8").replace("+", "%20")
            val payload = tagUpdatePayload(tags)
            val request = Request.Builder()
                .url("${settings.normalizedTagApiBaseUrl}/api/media-tags?path=$encodedPath")
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .put(payload.toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                val body = response.body?.string().orEmpty()
                if (!response.isSuccessful) {
                    Log.w(LOG_TAG, "Tag update rejected: HTTP ${response.code} via ${settings.normalizedTagApiBaseUrl}")
                    return@use null
                }
                val values = JSONObject(body).optJSONArray("tags") ?: return@use null
                val saved = buildList {
                    for (i in 0 until values.length()) {
                        values.optString(i).trim().takeIf { it.isNotEmpty() }?.let(::add)
                    }
                }
                if (saved.size != tags.size) {
                    Log.w(LOG_TAG, "Tag update response mismatch via ${settings.normalizedTagApiBaseUrl}")
                    return@use null
                }
                Log.i(LOG_TAG, "Tag update accepted via ${settings.normalizedTagApiBaseUrl}")
                saved
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Tag update request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchProfile(settings: NasSettings, relativePath: String): NasMediaProfile? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaProfileUrl(settings.normalizedTagApiBaseUrl, relativePath))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaProfile(JSONObject(response.body?.string().orEmpty()).optJSONObject("profile"))
            }
        }.getOrNull()
    }

    fun updateProfile(
        settings: NasSettings,
        relativePath: String,
        liked: Boolean? = null,
        favorited: Boolean? = null,
        note: String? = null,
    ): NasMediaProfile? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaProfileUrl(settings.normalizedTagApiBaseUrl, relativePath))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .put(mediaProfileUpdatePayload(liked, favorited, note).toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaProfile(JSONObject(response.body?.string().orEmpty()).optJSONObject("profile"))
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Media profile update failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchSuggestions(settings: NasSettings, folder: String): List<String>? {
        return fetchTagSummaries(settings, folder)?.map { it.name }
    }

    fun fetchTagSummaries(settings: NasSettings, folder: String = ""): List<NasTagSummary>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val url = tagSuggestionsUrl(settings.normalizedTagApiBaseUrl, folder)
            val request = Request.Builder()
                .url(url)
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseTagSummaries(response.body?.string().orEmpty())
            }
        }.getOrNull()
    }

    fun deleteTag(settings: NasSettings, tag: String): Boolean? {
        if (!settings.isTagApiConfigured || tag.isBlank()) return null
        return runCatching {
            val request = Request.Builder()
                .url(tagDeleteUrl(settings.normalizedTagApiBaseUrl, tag))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .delete()
                .build()
            client.newCall(request).execute().use { response -> response.isSuccessful }
        }.getOrNull()
    }

    fun renameTag(settings: NasSettings, sourceTag: String, targetTag: String): Boolean? {
        if (!settings.isTagApiConfigured || sourceTag.isBlank() || targetTag.isBlank()) return null
        return runCatching {
            val request = Request.Builder()
                .url(tagRenameUrl(settings.normalizedTagApiBaseUrl, sourceTag))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .put(tagRenamePayload(targetTag).toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response -> response.isSuccessful }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Tag rename request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchTaggedPaths(
        settings: NasSettings,
        tags: List<String> = emptyList(),
        taggedOnly: Boolean = false,
    ): Set<String>? {
        if (!settings.isTagApiConfigured || (tags.isEmpty() && !taggedOnly)) return null
        return runCatching {
            val request = Request.Builder()
                .url(taggedMediaUrl(settings.normalizedTagApiBaseUrl, tags, taggedOnly))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val media = JSONObject(response.body?.string().orEmpty()).optJSONArray("media")
                    ?: return@use emptySet<String>()
                buildSet {
                    for (index in 0 until media.length()) {
                        media.optJSONObject(index)?.optString("path")?.trim()
                            ?.takeIf { it.isNotEmpty() }?.let(::add)
                    }
                }
            }
        }.getOrNull()
    }

    fun fetchAllTags(settings: NasSettings): Map<String, List<String>>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(allTaggedMediaUrl(settings.normalizedTagApiBaseUrl))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseTaggedMediaTags(response.body?.string().orEmpty())
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Bulk tag request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchProfilePaths(
        settings: NasSettings,
        liked: Boolean = false,
        favorited: Boolean = false,
    ): Set<String>? {
        if (!settings.isTagApiConfigured || (!liked && !favorited)) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaProfilesUrl(settings.normalizedTagApiBaseUrl, liked, favorited))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                val media = JSONObject(response.body?.string().orEmpty()).optJSONArray("media")
                    ?: return@use emptySet<String>()
                buildSet {
                    for (index in 0 until media.length()) {
                        media.optJSONObject(index)?.optString("path")?.trim()
                            ?.takeIf { it.isNotEmpty() }?.let(::add)
                    }
                }
            }
        }.getOrNull()
    }

    fun moveToTrash(settings: NasSettings, relativePath: String): NasMediaTrashItem? {
        if (!settings.isTagApiConfigured || relativePath.isBlank()) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaTrashUrl(settings.normalizedTagApiBaseUrl))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .post(JSONObject().put("path", relativePath).toString().toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaTrashItem(response.body?.string().orEmpty())
            }
        }.onFailure { error ->
            Log.w(LOG_TAG, "Media trash request failed via ${settings.normalizedTagApiBaseUrl}", error)
        }.getOrNull()
    }

    fun fetchMediaTrash(settings: NasSettings): List<NasMediaTrashItem>? {
        if (!settings.isTagApiConfigured) return null
        return runCatching {
            val request = Request.Builder()
                .url(mediaTrashUrl(settings.normalizedTagApiBaseUrl))
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .get()
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaTrashItems(response.body?.string().orEmpty())
            }
        }.getOrNull()
    }

    fun restoreMediaTrash(settings: NasSettings, id: String): NasMediaTrashItem? {
        if (!settings.isTagApiConfigured || id.isBlank()) return null
        return runCatching {
            val request = Request.Builder()
                .url("${mediaTrashUrl(settings.normalizedTagApiBaseUrl)}/$id/restore")
                .header("X-TGAPP-Token", settings.effectiveTagApiToken)
                .post(ByteArray(0).toRequestBody("application/json".toMediaType()))
                .build()
            client.newCall(request).execute().use { response ->
                if (!response.isSuccessful) return@use null
                parseMediaTrashItem(response.body?.string().orEmpty())
            }
        }.getOrNull()
    }

    private fun parseMediaProfile(profile: JSONObject?): NasMediaProfile? {
        profile ?: return null
        val source = profile.optJSONObject("source")
        return NasMediaProfile(
            liked = profile.optBoolean("liked"),
            favorited = profile.optBoolean("favorited"),
            note = profile.optString("note").trim(),
            sourceLabel = source?.optString("label")?.trim().orEmpty(),
            sourceUrl = source?.optString("url")?.trim().orEmpty(),
        )
    }
}
