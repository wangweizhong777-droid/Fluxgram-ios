package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FeedRemovalPlaybackPolicyTest {
    @Test
    fun removingCurrentVideoRestartsPlaybackWhenAnotherVideoRemains() {
        assertEquals(2, playbackPositionAfterRemoval(currentPosition = 2, removedPosition = 2, remainingCount = 4))
    }

    @Test
    fun removingAnotherVideoDoesNotRestartCurrentPlayback() {
        assertNull(playbackPositionAfterRemoval(currentPosition = 2, removedPosition = 1, remainingCount = 4))
    }

    @Test
    fun removingLastVideoDoesNotRequestPlayback() {
        assertNull(playbackPositionAfterRemoval(currentPosition = 0, removedPosition = 0, remainingCount = 0))
    }
}
