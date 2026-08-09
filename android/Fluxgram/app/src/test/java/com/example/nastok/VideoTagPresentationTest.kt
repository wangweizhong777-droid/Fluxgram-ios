package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class VideoTagPresentationTest {
    @Test
    fun formatsEachVideoTagWithAHashPrefix() {
        assertEquals("#制服  #高跟鞋", formatVideoTags(listOf("制服", "高跟鞋")))
    }

    @Test
    fun returnsTheExactTagTheUserTapped() {
        val tags = listOf("制服", "高跟鞋", "黑丝袜")

        assertEquals("高跟鞋", tagAtIndex(tags, 1))
    }
}
