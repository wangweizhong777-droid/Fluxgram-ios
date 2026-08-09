package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class PlaybackChromeStateTest {
    @Test
    fun progressTimeoutHidesOnlyProgressChrome() {
        val state = PlaybackChromeState(progressVisible = true, controlsVisible = true)

        assertEquals(
            PlaybackChromeState(progressVisible = false, controlsVisible = true),
            state.next(PlaybackChromeEvent.PROGRESS_TIMEOUT)
        )
    }

    @Test
    fun controlsTimeoutHidesOnlyControlsChrome() {
        val state = PlaybackChromeState(progressVisible = false, controlsVisible = true)

        assertEquals(
            PlaybackChromeState(progressVisible = false, controlsVisible = false),
            state.next(PlaybackChromeEvent.CONTROLS_TIMEOUT)
        )
    }

    @Test
    fun playAndPauseRevealAllChrome() {
        val hidden = PlaybackChromeState(progressVisible = false, controlsVisible = false)

        assertEquals(
            PlaybackChromeState(progressVisible = true, controlsVisible = true),
            hidden.next(PlaybackChromeEvent.PLAY)
        )
        assertEquals(
            PlaybackChromeState(progressVisible = true, controlsVisible = true),
            hidden.next(PlaybackChromeEvent.PAUSE)
        )
    }

    @Test
    fun singleTapRevealsChromeWhenProgressIsHiddenEvenIfControlsRemainVisible() {
        val progressHidden = PlaybackChromeState(progressVisible = false, controlsVisible = true)

        assertEquals(PlaybackTapAction.REVEAL_CHROME, progressHidden.singleTapAction)
    }

    @Test
    fun singleTapTogglesPlaybackOnlyWhenProgressIsVisible() {
        val progressVisible = PlaybackChromeState(progressVisible = true, controlsVisible = false)

        assertEquals(PlaybackTapAction.TOGGLE_PLAYBACK, progressVisible.singleTapAction)
    }
}
