package com.example.nastok

import org.junit.Assert.assertTrue
import org.junit.Test

class PlaybackBufferConfigTest {
    @Test
    fun `seeking resumes with a short buffer while initial playback retains a stable buffer`() {
        assertTrue(PLAYBACK_MIN_BUFFER_MS >= 10_000)
        assertTrue(PLAYBACK_MAX_BUFFER_MS >= 30_000)
        assertTrue(PLAYBACK_START_BUFFER_MS >= 1_500)
        assertTrue(PLAYBACK_AFTER_REBUFFER_MS <= 500)
        assertTrue(PLAYBACK_MAX_BUFFER_MS >= PLAYBACK_MIN_BUFFER_MS)
    }
}
