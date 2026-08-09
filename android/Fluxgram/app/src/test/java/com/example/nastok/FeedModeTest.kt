package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class FeedModeTest {
    @Test
    fun usesACompactModeInsteadOfPassingEveryUntaggedPathThroughAnIntent() {
        assertEquals(FeedMode.UNTAGGED, tagFeedMode(tagged = false))
        assertEquals(FeedMode.TAGGED, tagFeedMode(tagged = true))
    }

    @Test
    fun inboxModeIsAvailableForTheOrganizationFeed() {
        assertEquals(FeedMode.INBOX, FeedMode.valueOf("INBOX"))
    }
}
