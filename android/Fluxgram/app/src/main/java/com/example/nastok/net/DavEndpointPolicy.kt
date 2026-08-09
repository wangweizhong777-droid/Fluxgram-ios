package com.example.nastok.net

import java.io.InterruptedIOException
import java.net.ConnectException
import java.net.SocketException
import java.net.UnknownHostException
import javax.net.ssl.SSLException

/** Chooses the LAN WebDAV address first and exposes a narrowly-scoped remote fallback. */
data class DavEndpointSettings(
    val localBaseUrl: String,
    val remoteGatewayBaseUrl: String = "",
)

object DavEndpointPolicy {
    fun localUrl(settings: DavEndpointSettings, path: String): String =
        settings.localBaseUrl.trim().trimEnd('/') + DavUrl.encodePath(path)

    fun remoteUrl(settings: DavEndpointSettings, path: String): String? {
        val base = settings.remoteGatewayBaseUrl.trim().trimEnd('/')
        return base.takeIf { it.isNotEmpty() }?.plus(DavUrl.encodePath(path))
    }

    fun shouldFallback(error: Throwable): Boolean {
        var current: Throwable? = error
        while (current != null) {
            if (current is ConnectException || current is UnknownHostException ||
                current is SocketException || current is InterruptedIOException || current is SSLException
            ) return true
            current = current.cause
        }
        return false
    }
}
