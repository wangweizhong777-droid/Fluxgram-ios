package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class FolderPathUtilsTest {
    @Test
    fun sameLeafFolderUnderDifferentParentsKeepsSeparateFolderPaths() {
        val paths = listOf(
            "/A/合集/01.mp4",
            "/B/合集/02.mp4",
        )

        assertEquals(listOf("/A/合集", "/B/合集"), paths.map(::folderPathFromVideoPath))
    }

    @Test
    fun folderPathUsesCompleteParentPath() {
        assertEquals(
            "/ddd4/mp4/sunny77",
            folderPathFromVideoPath("/ddd4/mp4/sunny77/episode01.mp4")
        )
    }

    @Test
    fun rootLevelVideoMapsToBlankFolder() {
        assertEquals("", folderPathFromVideoPath("/episode01.mp4"))
    }

    @Test
    fun folderPathNormalizationDropsTrailingSlash() {
        assertEquals("/ddd4/mp4/sunny77", normalizeFolderPath("/ddd4/mp4/sunny77/"))
    }

    @Test
    fun folderPathNormalizationKeepsRealSpaces() {
        assertEquals("/ddd4/ spaced ", normalizeFolderPath("/ddd4/ spaced /"))
    }

    @Test
    fun folderDisplayNameCanHideConfiguredRootPath() {
        assertEquals("门票", folderDisplayName("/ddd4/mp4/门票", "/ddd4/mp4/"))
    }
}
