package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FastSeekStateTest {
    @Test
    fun startAssignsIncreasingIdsAndClampsTargetToDuration() {
        val state = FastSeekState()

        val beforeStart = state.start(targetMs = -50L, durationMs = 5_000L)
        val afterEnd = state.start(targetMs = 8_000L, durationMs = 5_000L)

        assertEquals(0L, beforeStart.targetMs)
        assertEquals(5_000L, afterEnd.targetMs)
        assertEquals(beforeStart.id + 1L, afterEnd.id)
    }

    @Test
    fun startClampsNegativeDurationAndTargetToZero() {
        val state = FastSeekState()

        val request = state.start(targetMs = 500L, durationMs = -1L)

        assertEquals(0L, request.durationMs)
        assertEquals(0L, request.targetMs)
    }

    @Test
    fun aNewStartMakesThePreviousRequestStale() {
        val state = FastSeekState()
        val previous = state.start(targetMs = 1_000L, durationMs = 10_000L)
        val current = state.start(targetMs = 2_000L, durationMs = 10_000L)

        assertNull(state.settle(previous.id, actualMs = 1_000L))
        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 2_000L),
            state.settle(current.id, actualMs = 2_000L),
        )
    }

    @Test
    fun onlyTheLatestRequestCanClaimOneRecovery() {
        val state = FastSeekState()
        val previous = state.start(targetMs = 1_000L, durationMs = 10_000L)
        val current = state.start(targetMs = 2_000L, durationMs = 10_000L)

        assertNull(state.recover(previous.id))
        assertEquals(current, state.recover(current.id))
        assertNull(state.recover(current.id))
    }

    @Test
    fun settleReturnsPlayableWithinTheLargerTolerance() {
        val state = FastSeekState()
        val shortVideo = state.start(targetMs = 2_000L, durationMs = 10_000L)

        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 3_000L),
            state.settle(shortVideo.id, actualMs = 3_000L),
        )

        val longVideo = state.start(targetMs = 30_000L, durationMs = 100_000L)

        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 33_000L),
            state.settle(longVideo.id, actualMs = 33_000L),
        )
    }

    @Test
    fun settleReturnsFallbackWithClampedActualOutsideTolerance() {
        val state = FastSeekState()
        val request = state.start(targetMs = 8_000L, durationMs = 10_000L)

        assertEquals(
            FastSeekState.Settlement.Fallback(actualMs = 10_000L),
            state.settle(request.id, actualMs = 12_000L),
        )
    }

    @Test
    fun fallbackKeepsTheActiveRequestForItsRecoverySettlement() {
        val state = FastSeekState()
        val request = state.start(targetMs = 8_000L, durationMs = 10_000L)

        assertEquals(
            FastSeekState.Settlement.Fallback(actualMs = 4_000L),
            state.settle(request.id, actualMs = 4_000L),
        )

        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 8_000L),
            state.settle(request.id, actualMs = 8_000L),
        )
    }

    @Test
    fun settleClampsNegativeActualToZero() {
        val state = FastSeekState()
        val request = state.start(targetMs = 0L, durationMs = 10_000L)

        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 0L),
            state.settle(request.id, actualMs = -1L),
        )
    }

    @Test
    fun settleReturnsNullWithoutAnActiveRequest() {
        val state = FastSeekState()

        assertNull(state.settle(id = 1L, actualMs = 0L))
    }

    @Test
    fun invalidateClearsTheActiveRequest() {
        val state = FastSeekState()
        val request = state.start(targetMs = 1_000L, durationMs = 10_000L)

        state.invalidate()

        assertNull(state.settle(request.id, actualMs = 1_000L))
    }

    @Test
    fun invalidationPreventsRecoveryUntilAReplacementRequestStarts() {
        val state = FastSeekState()
        val oldRequest = state.start(targetMs = 1_000L, durationMs = 10_000L)

        state.invalidate()

        assertNull(state.recover(oldRequest.id))
    }

    @Test
    fun settleConsumesTheActiveRequest() {
        val state = FastSeekState()
        val request = state.start(targetMs = 1_000L, durationMs = 10_000L)

        assertEquals(
            FastSeekState.Settlement.Playable(actualMs = 1_000L),
            state.settle(request.id, actualMs = 1_000L),
        )

        assertNull(state.settle(request.id, actualMs = 1_000L))
    }
}
