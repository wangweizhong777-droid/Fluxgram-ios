package com.example.nastok.net

import com.example.nastok.data.NasSettings
import okhttp3.Credentials
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response

object DavRequestHeaders {
    fun values(
        username: String,
        password: String,
        remoteGatewayToken: String,
        isRemote: Boolean,
    ): Map<String, String> = buildMap {
        if (username.isNotBlank()) put("Authorization", Credentials.basic(username, password))
        if (isRemote && remoteGatewayToken.isNotBlank()) put("X-TGAPP-Token", remoteGatewayToken)
    }

    fun apply(
        builder: Request.Builder,
        username: String,
        password: String,
        remoteGatewayToken: String,
        isRemote: Boolean,
    ) {
        values(username, password, remoteGatewayToken, isRemote).forEach(builder::header)
    }

    fun apply(builder: Request.Builder, settings: NasSettings, isRemote: Boolean) = apply(
        builder = builder,
        username = settings.username,
        password = settings.password,
        remoteGatewayToken = settings.effectiveRemoteGatewayToken,
        isRemote = isRemote,
    )

    fun values(settings: NasSettings, isRemote: Boolean): Map<String, String> = values(
        username = settings.username,
        password = settings.password,
        remoteGatewayToken = settings.effectiveRemoteGatewayToken,
        isRemote = isRemote,
    )
}

fun NasSettings.davEndpointSettings() = DavEndpointSettings(
    localBaseUrl = normalizedBaseUrl,
    remoteGatewayBaseUrl = if (isRemoteGatewayConfigured) normalizedRemoteGatewayBaseUrl else "",
)

/** Executes direct WebDAV requests first, retrying exactly once via the HTTPS gateway on network failures. */
object DavRequestExecutor {
    fun execute(
        client: OkHttpClient,
        settings: NasSettings,
        path: String,
        requestFor: (url: String, isRemote: Boolean) -> Request,
    ): Response {
        val endpoints = settings.davEndpointSettings()
        val localUrl = DavEndpointPolicy.localUrl(endpoints, path)
        try {
            return client.newCall(requestFor(localUrl, false)).execute()
        } catch (error: Exception) {
            val remoteUrl = DavEndpointPolicy.remoteUrl(endpoints, path)
            if (!DavEndpointPolicy.shouldFallback(error) || remoteUrl == null) throw error
            return client.newCall(requestFor(remoteUrl, true)).execute()
        }
    }
}
