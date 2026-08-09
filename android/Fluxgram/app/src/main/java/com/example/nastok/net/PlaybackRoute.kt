package com.example.nastok.net

import com.example.nastok.data.NasSettings
import java.util.concurrent.ConcurrentHashMap

enum class PlaybackRoute(val label: String) {
    LOCAL("内网直连"),
    REMOTE("远程中转"),
}

class PlaybackRouteTracker {
    private val routes = ConcurrentHashMap<String, PlaybackRoute>()

    fun record(sessionKey: String, route: PlaybackRoute) {
        routes[sessionKey] = route
    }

    fun routeFor(sessionKey: String): PlaybackRoute? = routes[sessionKey]
}

internal object PlaybackRouteStore {
    private val tracker = PlaybackRouteTracker()

    fun record(settings: NasSettings, route: PlaybackRoute) {
        tracker.record(sessionKey(settings), route)
    }

    fun routeFor(settings: NasSettings): PlaybackRoute? = tracker.routeFor(sessionKey(settings))

    private fun sessionKey(settings: NasSettings): String =
        "${settings.normalizedBaseUrl}|${settings.normalizedRemoteGatewayBaseUrl}"
}
