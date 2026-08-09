package com.example.nastok

data class FileNameExpansionState(
    val maxLines: Int,
    val actionLabel: String?,
)

fun fileNameExpansionState(isTruncated: Boolean, expanded: Boolean): FileNameExpansionState = when {
    !isTruncated -> FileNameExpansionState(maxLines = 3, actionLabel = null)
    expanded -> FileNameExpansionState(maxLines = Int.MAX_VALUE, actionLabel = "收起")
    else -> FileNameExpansionState(maxLines = 3, actionLabel = "展开")
}

fun fileNameMaxWidth(parentWidthPx: Int): Int = (parentWidthPx / 2).coerceAtLeast(1)
