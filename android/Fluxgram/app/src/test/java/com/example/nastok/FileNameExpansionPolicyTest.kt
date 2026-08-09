package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class FileNameExpansionPolicyTest {
    @Test
    fun `truncated file names start collapsed with an expand action`() {
        val state = fileNameExpansionState(isTruncated = true, expanded = false)

        assertEquals(3, state.maxLines)
        assertEquals("展开", state.actionLabel)
    }

    @Test
    fun `expanded file names show every line and a collapse action`() {
        val state = fileNameExpansionState(isTruncated = true, expanded = true)

        assertEquals(Int.MAX_VALUE, state.maxLines)
        assertEquals("收起", state.actionLabel)
    }

    @Test
    fun `short file names do not show an expansion action`() {
        assertNull(fileNameExpansionState(isTruncated = false, expanded = false).actionLabel)
    }
}
