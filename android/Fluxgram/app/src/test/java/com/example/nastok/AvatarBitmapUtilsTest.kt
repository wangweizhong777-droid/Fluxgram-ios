package com.example.nastok

import org.junit.Assert.assertEquals
import org.junit.Test

class AvatarBitmapUtilsTest {
    @Test
    fun thumbnailFallbackAvatarCropsToShortestSide() {
        assertEquals(180, avatarCropSize(width = 320, height = 180))
        assertEquals(180, avatarCropSize(width = 180, height = 320))
    }
}
