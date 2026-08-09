package com.example.nastok

class FastSeekState {
    private var nextRequestId = 0L
    private var activeRequest: Request? = null
    private var recoveredRequestId: Long? = null

    fun start(targetMs: Long, durationMs: Long): Request {
        val duration = durationMs.coerceAtLeast(0L)
        val request = Request(
            id = ++nextRequestId,
            targetMs = targetMs.coerceIn(0L, duration),
            durationMs = duration,
        )
        activeRequest = request
        recoveredRequestId = null
        return request
    }

    fun settle(id: Long, actualMs: Long): Settlement? {
        val request = activeRequest?.takeIf { it.id == id } ?: return null

        val actual = actualMs.coerceIn(0L, request.durationMs)
        val toleranceMs = maxOf(
            request.durationMs / 100L * 3L + request.durationMs % 100L * 3L / 100L,
            MINIMUM_TOLERANCE_MS,
        )
        return if (kotlin.math.abs(actual - request.targetMs) <= toleranceMs) {
            activeRequest = null
            Settlement.Playable(actual)
        } else {
            Settlement.Fallback(actual)
        }
    }

    /** Claims the one recovery allowed for the active request, if it is still current. */
    fun recover(id: Long): Request? {
        val request = activeRequest?.takeIf { it.id == id } ?: return null
        if (recoveredRequestId == id) return null
        recoveredRequestId = id
        return request
    }

    fun invalidate() {
        activeRequest = null
        recoveredRequestId = null
    }

    data class Request(
        val id: Long,
        val targetMs: Long,
        val durationMs: Long,
    )

    sealed interface Settlement {
        data class Playable(val actualMs: Long) : Settlement

        data class Fallback(val actualMs: Long) : Settlement
    }

    private companion object {
        const val MINIMUM_TOLERANCE_MS = 1_000L
    }
}
