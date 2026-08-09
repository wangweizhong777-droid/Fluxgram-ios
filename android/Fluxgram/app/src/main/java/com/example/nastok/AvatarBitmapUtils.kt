package com.example.nastok

import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF

/** Center-crop a bitmap to a square and mask it into a circle for folder avatars. */
fun toCircleAvatar(src: Bitmap): Bitmap {
    val size = avatarCropSize(src.width, src.height)
    val left = (src.width - size) / 2
    val top = (src.height - size) / 2
    val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
    val canvas = Canvas(out)
    val paint = Paint(Paint.ANTI_ALIAS_FLAG)
    val r = size / 2f
    canvas.drawCircle(r, r, r, paint)
    paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
    canvas.drawBitmap(
        src,
        Rect(left, top, left + size, top + size),
        RectF(0f, 0f, size.toFloat(), size.toFloat()),
        paint,
    )
    return out
}

fun avatarCropSize(width: Int, height: Int): Int = minOf(width, height)
