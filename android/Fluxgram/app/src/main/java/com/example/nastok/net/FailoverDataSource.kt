package com.example.nastok.net

import android.net.Uri
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.TransferListener
import com.example.nastok.data.NasSettings
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap

/** ExoPlayer data source that uses LAN WebDAV first, then remembers a short remote fallback window. */
class FailoverDataSourceFactory(
    private val settings: NasSettings,
    private val localFactory: DataSource.Factory,
    private val remoteFactory: DataSource.Factory,
) : DataSource.Factory {
    override fun createDataSource(): DataSource = FailoverDataSource(settings, localFactory, remoteFactory)
}

internal fun shouldRetryReadViaRemote(
    isReadingRemote: Boolean,
    remoteAvailable: Boolean,
    error: IOException,
    consecutiveLocalFailures: Int,
): Boolean =
    !isReadingRemote &&
        remoteAvailable &&
        consecutiveLocalFailures >= MIN_LOCAL_READ_FAILURES_BEFORE_REMOTE &&
        DavEndpointPolicy.shouldFallback(error)

private const val MIN_LOCAL_READ_FAILURES_BEFORE_REMOTE = 3

private class FailoverDataSource(
    private val settings: NasSettings,
    private val localFactory: DataSource.Factory,
    private val remoteFactory: DataSource.Factory,
) : DataSource {
    private val listeners = mutableListOf<TransferListener>()
    private var active: DataSource? = null
    private var activeIsRemote = false
    private var originalDataSpec: DataSpec? = null
    private var bytesRead = 0L
    private var consecutiveLocalReadFailures = 0

    override fun addTransferListener(transferListener: TransferListener) {
        listeners += transferListener
    }

    override fun open(dataSpec: DataSpec): Long {
        originalDataSpec = dataSpec
        bytesRead = 0L
        consecutiveLocalReadFailures = 0
        if (RemoteGatewaySession.shouldPreferRemote(settings)) {
            remoteSpec(dataSpec)?.let { return openSource(remoteFactory, it, isRemote = true) }
        }
        return try {
            openSource(localFactory, dataSpec, isRemote = false).also {
                // A successful LAN open proves that the local route is healthy.
                // Clear a previous temporary remote preference immediately so a
                // Wi-Fi session does not keep seeking through the WAN fallback.
                RemoteGatewaySession.markLocalAvailable(settings)
            }
        } catch (error: IOException) {
            closeActiveQuietly()
            val remoteDataSpec = remoteSpec(dataSpec)
            if (!DavEndpointPolicy.shouldFallback(error) || remoteDataSpec == null) throw error
            RemoteGatewaySession.markLocalUnavailable(settings)
            openSource(remoteFactory, remoteDataSpec, isRemote = true)
        }
    }

    override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
        while (true) {
            val source = requireNotNull(active) { "Data source is not open" }
            try {
                return source.read(buffer, offset, length).also {
                    if (!activeIsRemote) consecutiveLocalReadFailures = 0
                    recordRead(it)
                }
            } catch (error: IOException) {
                if (activeIsRemote) throw error

                consecutiveLocalReadFailures++
                val resume = originalDataSpec?.subrange(bytesRead)
                val remoteDataSpec = resume?.let(::remoteSpec)
                if (shouldRetryReadViaRemote(
                        activeIsRemote,
                        remoteDataSpec != null,
                        error,
                        consecutiveLocalReadFailures,
                    )
                ) {
                    closeActiveQuietly()
                    RemoteGatewaySession.markLocalUnavailable(settings)
                    openSource(remoteFactory, requireNotNull(remoteDataSpec), isRemote = true)
                    return requireNotNull(active).read(buffer, offset, length)
                        .also(::recordRead)
                }

                // A transient LAN read failure should not force a WAN hop. Reopen the
                // local request at the exact byte offset and let the next loop retry it.
                closeActiveQuietly()
                openSource(localFactory, requireNotNull(resume), isRemote = false)
            }
        }
    }

    override fun getUri(): Uri? = active?.uri

    override fun getResponseHeaders(): Map<String, List<String>> = active?.responseHeaders ?: emptyMap()

    override fun close() {
        try {
            active?.close()
        } finally {
            active = null
            originalDataSpec = null
            bytesRead = 0L
            consecutiveLocalReadFailures = 0
        }
    }

    private fun openSource(factory: DataSource.Factory, dataSpec: DataSpec, isRemote: Boolean): Long {
        val source = factory.createDataSource()
        listeners.forEach(source::addTransferListener)
        return try {
            val length = source.open(dataSpec)
            active = source
            activeIsRemote = isRemote
            PlaybackRouteStore.record(settings, if (isRemote) PlaybackRoute.REMOTE else PlaybackRoute.LOCAL)
            length
        } catch (error: IOException) {
            runCatching { source.close() }
            throw error
        }
    }

    private fun recordRead(read: Int): Int = read.also { if (it > 0) bytesRead += it }

    private fun remoteSpec(dataSpec: DataSpec): DataSpec? {
        val path = dataSpec.uri.path ?: return null
        val remoteUrl = DavEndpointPolicy.remoteUrl(settings.davEndpointSettings(), path) ?: return null
        return dataSpec.withUri(Uri.parse(remoteUrl))
    }

    private fun closeActiveQuietly() {
        runCatching { active?.close() }
        active = null
        activeIsRemote = false
    }
}

private object RemoteGatewaySession {
    private const val FALLBACK_WINDOW_MS = 30_000L
    private val remoteUntil = ConcurrentHashMap<String, Long>()

    fun shouldPreferRemote(settings: NasSettings, nowMs: Long = System.currentTimeMillis()): Boolean =
        settings.isRemoteGatewayConfigured && (remoteUntil[key(settings)] ?: 0L) > nowMs

    fun markLocalUnavailable(settings: NasSettings, nowMs: Long = System.currentTimeMillis()) {
        remoteUntil[key(settings)] = nowMs + FALLBACK_WINDOW_MS
    }

    fun markLocalAvailable(settings: NasSettings) {
        remoteUntil.remove(key(settings))
    }

    private fun key(settings: NasSettings): String =
        "${settings.normalizedBaseUrl}|${settings.normalizedRemoteGatewayBaseUrl}"
}
