package com.example.nastok.data

import android.content.Context
import androidx.datastore.preferences.core.booleanPreferencesKey
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "nas_settings")

/** Persists [NasSettings] and a few standalone UI prefs (mute) via Jetpack DataStore. */
class SettingsStore(private val context: Context) {

    private object Keys {
        val BASE_URL = stringPreferencesKey("base_url")
        val USERNAME = stringPreferencesKey("username")
        val PASSWORD = stringPreferencesKey("password")
        val ROOT_PATH = stringPreferencesKey("root_path")
        val TAG_API_BASE_URL = stringPreferencesKey("tag_api_base_url")
        val TAG_API_TOKEN = stringPreferencesKey("tag_api_token")
        val LOCAL_GATEWAY_BASE_URL = stringPreferencesKey("local_gateway_base_url")
        val REMOTE_GATEWAY_BASE_URL = stringPreferencesKey("remote_gateway_base_url")
        val REMOTE_GATEWAY_TOKEN = stringPreferencesKey("remote_gateway_token")
        val MUTED = booleanPreferencesKey("muted")
        val LAST_SEEN_NEW = androidx.datastore.preferences.core.longPreferencesKey("last_seen_new")
    }

    val settings: Flow<NasSettings> = context.dataStore.data.map { prefs ->
        val default = NasSettings()
        NasSettings(
            baseUrl = prefs[Keys.BASE_URL] ?: default.baseUrl,
            username = prefs[Keys.USERNAME] ?: default.username,
            password = prefs[Keys.PASSWORD] ?: default.password,
            rootPath = prefs[Keys.ROOT_PATH] ?: default.rootPath,
            tagApiBaseUrl = prefs[Keys.TAG_API_BASE_URL] ?: default.tagApiBaseUrl,
            tagApiToken = prefs[Keys.TAG_API_TOKEN] ?: default.tagApiToken,
            localGatewayBaseUrl = prefs[Keys.LOCAL_GATEWAY_BASE_URL] ?: default.localGatewayBaseUrl,
            remoteGatewayBaseUrl = prefs[Keys.REMOTE_GATEWAY_BASE_URL] ?: default.remoteGatewayBaseUrl,
            remoteGatewayToken = prefs[Keys.REMOTE_GATEWAY_TOKEN] ?: default.remoteGatewayToken,
        )
    }

    /** Last user-chosen mute state. Defaults to true (TikTok-style: silent until tap). */
    val muted: Flow<Boolean> = context.dataStore.data.map { it[Keys.MUTED] ?: true }

    suspend fun save(s: NasSettings) {
        context.dataStore.edit { prefs ->
            prefs[Keys.BASE_URL] = s.baseUrl.trim()
            prefs[Keys.USERNAME] = s.username.trim()
            prefs[Keys.PASSWORD] = s.password
            prefs[Keys.ROOT_PATH] = s.rootPath.trim()
            prefs[Keys.TAG_API_BASE_URL] = s.tagApiBaseUrl.trim()
            prefs[Keys.TAG_API_TOKEN] = s.tagApiToken
            prefs[Keys.LOCAL_GATEWAY_BASE_URL] = s.localGatewayBaseUrl.trim()
            prefs[Keys.REMOTE_GATEWAY_BASE_URL] = s.remoteGatewayBaseUrl.trim()
            prefs[Keys.REMOTE_GATEWAY_TOKEN] = s.remoteGatewayToken
        }
    }

    suspend fun setMuted(value: Boolean) {
        context.dataStore.edit { it[Keys.MUTED] = value }
    }

    /** Epoch millis of the last time the user dismissed the "new videos" badge.
     *  Videos with addedAt > this are considered "new". */
    val lastSeenNew: Flow<Long> = context.dataStore.data.map { it[Keys.LAST_SEEN_NEW] ?: 0L }

    suspend fun markNewAsSeen(ts: Long = System.currentTimeMillis()) {
        context.dataStore.edit { it[Keys.LAST_SEEN_NEW] = ts }
    }
}
