package com.example.nastok

data class PlaybackChromeState(
    val progressVisible: Boolean,
    val controlsVisible: Boolean,
) {
    val singleTapAction: PlaybackTapAction
        get() = if (progressVisible) {
            PlaybackTapAction.TOGGLE_PLAYBACK
        } else {
            PlaybackTapAction.REVEAL_CHROME
        }

    fun next(event: PlaybackChromeEvent): PlaybackChromeState = when (event) {
        PlaybackChromeEvent.PLAY,
        PlaybackChromeEvent.PAUSE,
        PlaybackChromeEvent.SCRUB_START,
        PlaybackChromeEvent.USER_TOUCH -> copy(progressVisible = true, controlsVisible = true)
        PlaybackChromeEvent.PROGRESS_TIMEOUT -> copy(progressVisible = false)
        PlaybackChromeEvent.CONTROLS_TIMEOUT -> copy(controlsVisible = false)
    }
}

enum class PlaybackTapAction {
    REVEAL_CHROME,
    TOGGLE_PLAYBACK,
}

enum class PlaybackChromeEvent {
    PLAY,
    PAUSE,
    SCRUB_START,
    USER_TOUCH,
    PROGRESS_TIMEOUT,
    CONTROLS_TIMEOUT,
}
