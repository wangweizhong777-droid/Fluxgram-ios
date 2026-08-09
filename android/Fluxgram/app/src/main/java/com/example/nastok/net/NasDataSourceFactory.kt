package com.example.nastok.net

import android.content.Context
import androidx.media3.datasource.DataSource
import androidx.media3.datasource.cache.CacheDataSource
import androidx.media3.datasource.okhttp.OkHttpDataSource
import com.example.nastok.data.NasSettings
import com.example.nastok.data.PlaybackCache

/** Builds an ExoPlayer-compatible HTTP data source factory that reuses our
 *  self-signed-trusting OkHttp client and sends Basic auth for the WebDAV server. */
object NasDataSourceFactory {

    fun create(context: Context, settings: NasSettings): DataSource.Factory {
        val local = OkHttpDataSource.Factory(TrustingHttpClient.localProbe())
            .setDefaultRequestProperties(DavRequestHeaders.values(settings, isRemote = false))
        val remote = OkHttpDataSource.Factory(TrustingHttpClient.build())
            .setDefaultRequestProperties(DavRequestHeaders.values(settings, isRemote = true))
        return CacheDataSource.Factory()
            .setCache(PlaybackCache.get(context.applicationContext))
            .setUpstreamDataSourceFactory(FailoverDataSourceFactory(settings, local, remote))
            .setFlags(CacheDataSource.FLAG_IGNORE_CACHE_ON_ERROR)
    }
}
