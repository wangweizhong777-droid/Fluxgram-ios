package com.example.nastok.net

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackRouteTest {
    @Test
    fun `local route uses the direct LAN label`() {
        assertEquals("内网直连", PlaybackRoute.LOCAL.label)
    }

    @Test
    fun `remote route is visibly labelled as a relay`() {
        assertEquals("远程中转", PlaybackRoute.REMOTE.label)
    }
}
