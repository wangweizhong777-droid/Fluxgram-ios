package com.example.nastok.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackRouteTrackerTest {
    @Test
    fun `tracks the latest route for each media session`() {
        val tracker = PlaybackRouteTracker()

        assertNull(tracker.routeFor("feed-a"))
        tracker.record("feed-a", PlaybackRoute.LOCAL)
        tracker.record("feed-b", PlaybackRoute.REMOTE)
        tracker.record("feed-a", PlaybackRoute.REMOTE)

        assertEquals(PlaybackRoute.REMOTE, tracker.routeFor("feed-a"))
        assertEquals(PlaybackRoute.REMOTE, tracker.routeFor("feed-b"))
    }
}
