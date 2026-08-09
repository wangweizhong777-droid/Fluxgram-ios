package com.example.nastok

import android.widget.ImageView
import org.junit.Assert.assertEquals
import org.junit.Test

class ThumbnailScalePolicyTest {
    @Test
    fun landscapeThumbnailsCropCenterToFillTheCard() {
        assertEquals(ImageView.ScaleType.CENTER_CROP, thumbnailScaleType(320, 180))
    }

    @Test
    fun portraitThumbnailsFitInsideTheCardWithoutStretching() {
        assertEquals(ImageView.ScaleType.FIT_CENTER, thumbnailScaleType(180, 320))
    }

    @Test
    fun squareThumbnailsFitInsideTheCardWithoutStretching() {
        assertEquals(ImageView.ScaleType.FIT_CENTER, thumbnailScaleType(240, 240))
    }
}
