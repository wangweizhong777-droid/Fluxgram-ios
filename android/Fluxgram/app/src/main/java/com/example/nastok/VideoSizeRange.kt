package com.example.nastok

private const val SIZE_MB = 1024L * 1024L
private const val SIZE_GB = 1024L * 1024L * 1024L

data class VideoSizeRange(
    val minBytes: Long,
    val maxBytesExclusive: Long?,
) {
    fun includes(sizeBytes: Long): Boolean =
        sizeBytes >= minBytes && (maxBytesExclusive == null || sizeBytes < maxBytesExclusive)
}

fun parseCustomVideoSizeRangeMb(minMbText: String, maxMbText: String): VideoSizeRange? {
    val minMb = if (minMbText.isBlank()) 0L else parseMegabytes(minMbText) ?: return null
    val maxMb = if (maxMbText.isBlank()) null else parseMegabytes(maxMbText) ?: return null
    if (maxMb != null && maxMb <= minMb) return null
    return VideoSizeRange(
        minBytes = minMb * SIZE_MB,
        maxBytesExclusive = maxMb?.let { it * SIZE_MB },
    )
}

private fun parseMegabytes(text: String): Long? {
    val trimmed = text.trim()
    val value = trimmed.toLongOrNull() ?: return null
    if (value < 0 || value > Long.MAX_VALUE / SIZE_MB) return null
    return value
}

enum class VideoSizeRangePreset(
    val label: String,
    val range: VideoSizeRange,
) {
    SMALL("0-50MB", VideoSizeRange(0, 50L * SIZE_MB)),
    MEDIUM("50-200MB", VideoSizeRange(50L * SIZE_MB, 200L * SIZE_MB)),
    LARGE("200MB-1GB", VideoSizeRange(200L * SIZE_MB, SIZE_GB)),
    HUGE("1GB以上", VideoSizeRange(SIZE_GB, null));
}
