package com.example.nastok

import android.graphics.Bitmap
import android.widget.ImageView

fun thumbnailScaleType(width: Int, height: Int): ImageView.ScaleType =
    if (width > height) ImageView.ScaleType.CENTER_CROP else ImageView.ScaleType.FIT_CENTER

fun ImageView.setThumbnailBitmap(bitmap: Bitmap) {
    scaleType = thumbnailScaleType(bitmap.width, bitmap.height)
    setImageBitmap(bitmap)
}
