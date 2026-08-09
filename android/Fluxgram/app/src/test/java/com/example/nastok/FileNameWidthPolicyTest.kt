package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class FileNameWidthPolicyTest {
    @Test
    fun `file names use at most half of the available video width`() {
        assertEquals(540, fileNameMaxWidth(1080))
        assertEquals(900, fileNameMaxWidth(1800))
    }
}
