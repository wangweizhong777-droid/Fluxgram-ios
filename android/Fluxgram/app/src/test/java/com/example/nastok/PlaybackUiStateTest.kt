package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PlaybackUiStateTest {
    @Test
    fun loadingReasonsMapToReadableLabels() {
        assertEquals("正在缓冲", PlaybackLoadingReason.BUFFERING.label())
        assertEquals("正在恢复进度", PlaybackLoadingReason.SEEK_RECOVERY.label())
        assertEquals("正在重试播放", PlaybackLoadingReason.RETRYING.label())
        assertEquals("播放失败，已跳过", PlaybackLoadingReason.FAILED_SKIPPED.label())
        assertNull(PlaybackLoadingReason.NONE.label())
    }
}
