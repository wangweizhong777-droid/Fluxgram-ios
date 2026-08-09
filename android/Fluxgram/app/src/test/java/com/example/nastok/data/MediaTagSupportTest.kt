package com.example.nastok.data

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MediaTagSupportTest {
    @Test
    fun convertsWebDavPathsToRootRelativePaths() {
        assertEquals(
            "经典/第 01 集.mp4",
            mediaTagLookupPath("/ddd4/mp4/经典/第 01 集.mp4", "/ddd4/mp4/"),
        )
        assertEquals(
            "经典/第 01 集.mp4",
            mediaTagLookupPath("经典/第 01 集.mp4", "/ddd4/mp4"),
        )
    }

    @Test
    fun convertsNasTagRecordPathsToTheFluxTokLookupIdentity() {
        assertEquals(
            "library/tagged.mp4",
            mediaTagLookupPathFromNasRecord("ddd4/mp4/library/tagged.mp4", "/ddd4/mp4"),
        )
        assertEquals(
            "library/tagged.mp4",
            mediaTagLookupPathFromNasRecord("library/tagged.mp4", "/ddd4/mp4"),
        )
    }

    @Test
    fun rejectsPathsOutsideTheConfiguredRootOrTraversal() {
        assertNull(mediaTagLookupPath("/other/第 01 集.mp4", "/ddd4/mp4"))
        assertNull(mediaTagLookupPath("/ddd4/mp4/经典/../第 01 集.mp4", "/ddd4/mp4"))
        assertNull(mediaTagLookupPath("/ddd4/mp4/经典/", "/ddd4/mp4"))
    }

    @Test
    fun cacheReturnsFreshValuesAndExpiresOldValues() {
        val cache = MediaTagCache(ttlMs = 1_000)
        cache.put("经典/第 01 集.mp4", listOf("制服", "高跟鞋"), nowMs = 100)

        assertEquals(listOf("制服", "高跟鞋"), cache.get("经典/第 01 集.mp4", nowMs = 1_099))
        assertNull(cache.get("经典/第 01 集.mp4", nowMs = 1_100))
    }

    @Test
    fun cacheKeepsEmptyResultsToAvoidRepeatedNoMatchRequests() {
        val cache = MediaTagCache(ttlMs = 1_000)
        cache.put("经典/未标注.mp4", emptyList(), nowMs = 200)

        assertEquals(emptyList<String>(), cache.get("经典/未标注.mp4", nowMs = 1_199))
    }

    @Test
    fun completeSnapshotTreatsMissingPathsAsEmptyResults() {
        val cache = MediaTagCache(ttlMs = 1_000)
        cache.markSnapshot(nowMs = 200)

        assertEquals(emptyList<String>(), cache.get("missing.mp4", nowMs = 1_199))
        assertNull(cache.get("missing.mp4", nowMs = 1_200))
    }

    @Test
    fun parsesManualTagsWithoutTreatingTheEmptyStateAsATag() {
        assertEquals(emptyList<String>(), parseManualTags("添加标签"))
        assertEquals(
            listOf("制服", "黑丝袜", "高跟鞋"),
            parseManualTags(" 制服，黑丝袜\n高跟鞋, 制服 "),
        )
    }

    @Test
    fun resolvesAnEmptyVideoPathToTheGlobalTagSuggestionScope() {
        assertEquals("", tagSuggestionFolder("", "/ddd4/mp4"))
        assertEquals("经典", tagSuggestionFolder("/ddd4/mp4/经典/第01集.mp4", "/ddd4/mp4"))
    }
    @Test
    fun separatesIndexedVideosByWhetherTheirNasPathHasTags() {
        val paths = listOf(
            "/ddd4/mp4/library/tagged.mp4",
            "/ddd4/mp4/library/untagged.mp4",
            "/outside/ignored.mp4",
        )

        val result = classifyIndexedVideosByTags(
            indexedPaths = paths,
            rootPath = "/ddd4/mp4",
            taggedPaths = setOf("library/tagged.mp4"),
        )

        assertEquals(listOf("/ddd4/mp4/library/tagged.mp4"), result.tagged)
        assertEquals(listOf("/ddd4/mp4/library/untagged.mp4"), result.untagged)
    }
}
