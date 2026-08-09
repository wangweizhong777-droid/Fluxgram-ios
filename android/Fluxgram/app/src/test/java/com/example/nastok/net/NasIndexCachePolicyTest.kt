package com.example.nastok.net

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class NasIndexCachePolicyTest {
    @Test
    fun `uses the saved ETag only when the local database has an index for the same source`() {
        val cached = NasIndexVersion(etag = "etag-42", fingerprint = "source-a")

        assertEquals("etag-42", cachedEtagForRequest(cached, "source-a", localVideoCount = 12))
        assertNull(cachedEtagForRequest(cached, "source-a", localVideoCount = 0))
        assertNull(cachedEtagForRequest(cached, "source-b", localVideoCount = 12))
    }
}
