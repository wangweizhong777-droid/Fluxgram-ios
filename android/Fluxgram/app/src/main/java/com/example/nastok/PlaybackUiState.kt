package com.example.nastok

enum class PlaybackLoadingReason {
    NONE,
    BUFFERING,
    SEEK_RECOVERY,
    RETRYING,
    FAILED_SKIPPED,
}

fun PlaybackLoadingReason.label(): String? = when (this) {
    PlaybackLoadingReason.NONE -> null
    PlaybackLoadingReason.BUFFERING -> "正在缓冲"
    PlaybackLoadingReason.SEEK_RECOVERY -> "正在恢复进度"
    PlaybackLoadingReason.RETRYING -> "正在重试播放"
    PlaybackLoadingReason.FAILED_SKIPPED -> "播放失败，已跳过"
}
