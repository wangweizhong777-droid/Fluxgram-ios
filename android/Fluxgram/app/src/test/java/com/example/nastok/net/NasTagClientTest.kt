package com.example.nastok.net

import org.junit.Assert.assertEquals
import org.junit.Test
import org.json.JSONObject

class NasTagClientTest {
    @Test
    fun parsesBulkMediaTags() {
        val parsed = parseTaggedMediaTags(
            """{"media":[{"path":"ddd4/mp4/a.mp4","tags":["OL"]},{"path":"b.mp4","tags":[]},{"path":"bad.mp4"}]}""",
        )

        assertEquals(mapOf("ddd4/mp4/a.mp4" to listOf("OL")), parsed)
    }


    @Test
    fun parsesMediaDetailsFromTheNasFactRecord() {
        val detail = parseMediaDetail(
            """{
              "found":true,"id":"job-1","fileName":"clip.mp4","fileSize":123,
              "relativePath":"classic/clip.mp4","outputFile":"/ddd4/mp4/classic/clip.mp4",
              "status":"done","downloadedAt":"2026-07-23T00:00:00.000Z",
              "tags":["制服","高跟"],"note":"keep",
              "source":{"dialogId":"123","messageId":88,"rootMessageId":0,"title":"收藏频道","text":"caption","label":"频道 123","url":"https://t.me/c/123/88"},
              "rule":{"id":"rule-1","applied":true}
            }""".trimIndent(),
        )

        assertEquals("classic/clip.mp4", detail?.relativePath)
        assertEquals(listOf("制服", "高跟"), detail?.tags)
        assertEquals("收藏频道", detail?.sourceTitle)
        assertEquals(88, detail?.sourceMessageId)
        assertEquals("rule-1", detail?.ruleId)
    }
    @Test
    fun encodesManualTagsAsAJsonArray() {
        assertEquals(
            "{\"tags\":[\"测试\",\"高跟鞋\"]}",
            tagUpdatePayload(listOf("测试", "高跟鞋")),
        )
    }

    @Test
    fun requestsTheFullTagCatalogueForSuggestions() {
        assertEquals(
            "https://your-gateway.example.com/api/tags?subdir=%E7%BB%8F%E5%85%B8&limit=500",
            tagSuggestionsUrl("https://your-gateway.example.com", "经典"),
        )
    }

    @Test
    fun requestsOnlyPathsThatHaveAtLeastOneTag() {
        assertEquals(
            "https://your-gateway.example.com/api/tagged-media?tagged=true",
            taggedMediaUrl("https://your-gateway.example.com", emptyList(), taggedOnly = true),
        )
    }

    @Test
    fun encodesTheGlobalTagDeleteEndpoint() {
        assertEquals(
            "https://your-gateway.example.com/api/tags?tag=%E9%AB%98%E8%B7%9F",
            tagDeleteUrl("https://your-gateway.example.com", "高跟"),
        )
    }

    @Test
    fun encodesTheGlobalTagRenameEndpointAndPayload() {
        assertEquals(
            "https://your-gateway.example.com/api/tags?tag=uniform",
            tagRenameUrl("https://your-gateway.example.com", "uniform"),
        )
        assertEquals("outfit", JSONObject(tagRenamePayload("outfit")).getString("name"))
    }

    @Test
    fun parsesTagUsageCountsForTheManager() {
        assertEquals(
            listOf(NasTagSummary("uniform", 12), NasTagSummary("heels", 3)),
            parseTagSummaries("{\"tags\":[{\"name\":\"uniform\",\"usageCount\":12},{\"name\":\"heels\",\"usageCount\":3}]}"),
        )
    }

    @Test
    fun encodesTheMediaProfileReadAndPartialUpdateEndpoints() {
        assertEquals(
            "https://your-gateway.example.com/api/media-profile?path=classic%2Fclip.mp4",
            mediaProfileUrl("https://your-gateway.example.com", "classic/clip.mp4"),
        )
        val payload = JSONObject(mediaProfileUpdatePayload(liked = true, favorited = false, note = "keep"))
        assertEquals(true, payload.getBoolean("liked"))
        assertEquals(false, payload.getBoolean("favorited"))
        assertEquals("keep", payload.getString("note"))
    }

    @Test
    fun requestsRemoteFavoriteMediaPaths() {
        assertEquals(
            "https://your-gateway.example.com/api/media-profiles?favorited=true",
            mediaProfilesUrl("https://your-gateway.example.com", favorited = true),
        )
    }

    @Test
    fun requestsAndParsesNasInboxPaths() {
        assertEquals(
            "https://your-gateway.example.com/api/download-history?inbox=true&limit=500",
            inboxMediaUrl("https://your-gateway.example.com", 500),
        )
        assertEquals(
            listOf("classic/one.mp4", "clips/two.mp4"),
            parseInboxMediaPaths("""{"history":[{"downloadSubdir":"classic","fileName":"one.mp4"},{"downloadSubdir":"clips","fileName":"two.mp4"}]}"""),
        )
    }

    @Test
    fun encodesMediaTrashEndpointsAndParsesRetentionItems() {
        assertEquals(
            "https://your-gateway.example.com/api/media-trash",
            mediaTrashUrl("https://your-gateway.example.com"),
        )
        val items = parseMediaTrashItems(
            """{"items":[{"id":"trash-1","path":"classic/clip.mp4","deletedAt":"2026-07-20T00:00:00.000Z","expiresAt":"2026-07-27T00:00:00.000Z"}]}""",
        )
        assertEquals("trash-1", items.single().id)
        assertEquals("classic/clip.mp4", items.single().path)
    }
}
