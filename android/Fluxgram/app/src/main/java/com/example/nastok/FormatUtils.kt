package com.example.nastok

import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import kotlin.math.floor

fun formatByteSize(bytes: Long): String = when {
    bytes < 1024 -> "$bytes B"
    bytes < 1024 * 1024 -> "%.1f KB".format(Locale.US, truncate(bytes / 1024.0, 1))
    bytes < 1024L * 1024 * 1024 -> "%.1f MB".format(Locale.US, truncate(bytes / (1024.0 * 1024), 1))
    else -> "%.2f GB".format(Locale.US, truncate(bytes / (1024.0 * 1024 * 1024), 2))
}

private fun truncate(value: Double, decimalPlaces: Int): Double {
    val factor = Math.pow(10.0, decimalPlaces.toDouble())
    return floor(value * factor) / factor
}

fun formatLocalTimestamp(epochMillis: Long, timeZone: TimeZone = TimeZone.getDefault()): String {
    return SimpleDateFormat("yyyy-MM-dd HH:mm", Locale.CHINA).apply {
        this.timeZone = timeZone
    }.format(Date(epochMillis))
}
