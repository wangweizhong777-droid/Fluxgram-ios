package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ExternalMediaLinkTest {
    @Test
    fun resolvesAValidatedRelativeNasPathForPlayback() {
        assertEquals(
            "/downloads/classic/clip.mp4",
            resolveNastokPlaybackPath("/downloads", "classic/clip.mp4"),
        )
    }

    @Test
    fun rejectsAbsoluteAndTraversalExternalPaths() {
        assertNull(resolveNastokPlaybackPath("/downloads", "/etc/passwd"))
        assertNull(resolveNastokPlaybackPath("/downloads", "classic/../clip.mp4"))
    }
}
