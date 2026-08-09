package com.example.nastok.net

import okhttp3.OkHttpClient
import java.security.cert.X509Certificate
import java.util.concurrent.TimeUnit
import javax.net.ssl.HostnameVerifier
import javax.net.ssl.SSLContext
import javax.net.ssl.TrustManager
import javax.net.ssl.X509TrustManager

/** Builds an OkHttpClient that trusts self-signed certificates.
 *  fnOS WebDAV over HTTPS almost always uses a self-signed cert on the LAN,
 *  so the default trust store would reject it. Safe here because traffic stays
 *  on the local network to a device the user owns.
 *
 *  The client is a singleton — all callers share one connection pool and thread pool,
 *  avoiding resource leaks from creating many independent clients. */
object TrustingHttpClient {

    private const val LOCAL_CONNECT_TIMEOUT_MS = 1_800L

    val instance: OkHttpClient by lazy { create() }
    private val localProbeInstance: OkHttpClient by lazy { create(connectTimeoutMs = LOCAL_CONNECT_TIMEOUT_MS) }

    fun build(): OkHttpClient = instance
    fun localProbe(): OkHttpClient = localProbeInstance

    private fun create(connectTimeoutMs: Long = TimeUnit.SECONDS.toMillis(15)): OkHttpClient {
        val trustAll = object : X509TrustManager {
            override fun checkClientTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun checkServerTrusted(chain: Array<out X509Certificate>?, authType: String?) {}
            override fun getAcceptedIssuers(): Array<X509Certificate> = arrayOf()
        }
        val sslContext = SSLContext.getInstance("TLS")
        sslContext.init(null, arrayOf<TrustManager>(trustAll), java.security.SecureRandom())

        return OkHttpClient.Builder()
            .sslSocketFactory(sslContext.socketFactory, trustAll)
            .hostnameVerifier(HostnameVerifier { _, _ -> true })
            .connectTimeout(connectTimeoutMs, TimeUnit.MILLISECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }
}
