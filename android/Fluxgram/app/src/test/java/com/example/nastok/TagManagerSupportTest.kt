package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class TagManagerSupportTest {
    @Test
    fun filtersTagManagerRowsWithoutChangingTheSuggestedOrder() {
        assertEquals(
            listOf("黑丝", "黑色高跟"),
            filterManageableTags(listOf("制服", "黑丝", "黑色高跟", "办公室"), " 黑 "),
        )
    }

    @Test
    fun blankTagManagerSearchKeepsEveryTag() {
        assertEquals(
            listOf("制服", "高跟"),
            filterManageableTags(listOf("制服", "高跟"), "  "),
        )
    }
}
