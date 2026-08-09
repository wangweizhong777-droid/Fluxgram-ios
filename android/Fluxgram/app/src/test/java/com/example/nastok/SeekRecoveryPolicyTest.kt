package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SeekRecoveryPolicyTest {
    @Test
    fun userSeekBufferingDoesNotRestartThePlayer() {
        assertFalse(
            shouldRecoverSeekOnBuffering(
                isBuffering = true,
                hasRendered = true,
                playWhenReady = true,
                pendingSeekGeneration = 7,
                currentSeekGeneration = 7,
                recoveredSeekGeneration = -1,
            )
        )
    }

    @Test
    fun doesNotRecoverTheSameSeekTwice() {
        assertFalse(
            shouldRecoverSeekOnBuffering(
                isBuffering = true,
                hasRendered = true,
                playWhenReady = true,
                pendingSeekGeneration = 7,
                currentSeekGeneration = 7,
                recoveredSeekGeneration = 7,
            )
        )
    }

    @Test
    fun ignoresOrdinaryBufferingThatWasNotCausedByUserSeek() {
        assertFalse(
            shouldRecoverSeekOnBuffering(
                isBuffering = true,
                hasRendered = true,
                playWhenReady = true,
                pendingSeekGeneration = -1,
                currentSeekGeneration = 7,
                recoveredSeekGeneration = -1,
            )
        )
    }

    @Test
    fun waitsForRealBufferingSignal() {
        assertFalse(
            shouldRecoverSeekOnBuffering(
                isBuffering = false,
                hasRendered = true,
                playWhenReady = true,
                pendingSeekGeneration = 7,
                currentSeekGeneration = 7,
                recoveredSeekGeneration = -1,
            )
        )
    }

    @Test
    fun hidesSpinnerForBufferingImmediatelyAfterUserSeek() {
        assertFalse(
            shouldShowBufferingSpinner(
                isBuffering = true,
                hasRendered = true,
                hasActiveSeek = true,
            )
        )
    }

    @Test
    fun showsSpinnerForInitialBufferingBeforeFirstFrame() {
        assertTrue(
            shouldShowBufferingSpinner(
                isBuffering = true,
                hasRendered = false,
                hasActiveSeek = false,
            )
        )
    }

    @Test
    fun showsSpinnerForOrdinaryBufferingNotCausedBySeek() {
        assertTrue(
            shouldShowBufferingSpinner(
                isBuffering = true,
                hasRendered = true,
                hasActiveSeek = false,
            )
        )
    }

    @Test
    fun playerErrorAfterASettledSeekUsesOrdinaryRetry() {
        val state = FastSeekState()
        val request = state.start(targetMs = 2_000L, durationMs = 10_000L)
        state.settle(request.id, actualMs = 2_000L)

        assertEquals(
            PlayerErrorRetryPlan.Ordinary,
            playerErrorRetryPlan(state.recover(request.id)),
        )
    }

    @Test
    fun playerErrorAfterTheOneSeekRecoveryUsesOrdinaryRetry() {
        val state = FastSeekState()
        val request = state.start(targetMs = 2_000L, durationMs = 10_000L)

        assertEquals(
            PlayerErrorRetryPlan.FastSeek(request.targetMs),
            playerErrorRetryPlan(state.recover(request.id)),
        )
        assertEquals(
            PlayerErrorRetryPlan.Ordinary,
            playerErrorRetryPlan(state.recover(request.id)),
        )
    }

    @Test
    fun recoveryStartedDefersReadySuccessUntilTheSeekLaterSettles() {
        assertFalse(shouldHandleReadySuccess(FastSeekReadyResult.RECOVERY_STARTED))
        assertTrue(shouldHandleReadySuccess(FastSeekReadyResult.SETTLED))
    }
}
