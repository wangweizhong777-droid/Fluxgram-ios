package com.example.nastok.data

import com.example.nastok.net.NasMediaTrashItem
import org.junit.Assert.assertEquals
import org.junit.Test

class MediaTrashStoreTest {
    @Test
    fun buildsThumbnailSourceFromTheNasRecycleBinPath() {
        val item = NasMediaTrashItem(
            id = "trash-1",
            path = "classic/clip.mp4",
            deletedAt = "2026-07-25T00:00:00.000Z",
            expiresAt = "2026-08-01T00:00:00.000Z",
            thumbnailPath = ".fluxtok-trash/trash-1/classic/clip.mp4",
        )

        assertEquals(
            "/ddd4/mp4/.fluxtok-trash/trash-1/classic/clip.mp4",
            trashThumbnailSourcePath(NasSettings(rootPath = "/ddd4/mp4/"), item),
        )
    }
}
