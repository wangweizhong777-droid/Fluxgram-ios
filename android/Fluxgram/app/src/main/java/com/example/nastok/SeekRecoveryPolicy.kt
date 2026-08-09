package com.example.nastok

@Suppress("UNUSED_PARAMETER")
/** Buffering alone never recreates a player; FastSeekState handles active seek recovery instead. */
fun shouldRecoverSeekOnBuffering(
    isBuffering: Boolean,
    hasRendered: Boolean,
    playWhenReady: Boolean,
    pendingSeekGeneration: Int,
    currentSeekGeneration: Int,
    recoveredSeekGeneration: Int,
): Boolean =
    false

fun shouldShowBufferingSpinner(
    isBuffering: Boolean,
    hasRendered: Boolean,
    hasActiveSeek: Boolean,
): Boolean =
    isBuffering && !(hasRendered && hasActiveSeek)

sealed interface PlayerErrorRetryPlan {
    data class FastSeek(val targetMs: Long) : PlayerErrorRetryPlan

    data object Ordinary : PlayerErrorRetryPlan
}

fun playerErrorRetryPlan(recoveryRequest: FastSeekState.Request?): PlayerErrorRetryPlan =
    recoveryRequest?.let { PlayerErrorRetryPlan.FastSeek(it.targetMs) }
        ?: PlayerErrorRetryPlan.Ordinary

enum class FastSeekReadyResult {
    NONE,
    SETTLED,
    RECOVERY_STARTED,
}

fun shouldHandleReadySuccess(result: FastSeekReadyResult): Boolean =
    result != FastSeekReadyResult.RECOVERY_STARTED
