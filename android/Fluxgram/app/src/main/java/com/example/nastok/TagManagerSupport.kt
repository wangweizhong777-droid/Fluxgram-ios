package com.example.nastok

/** Filters NAS-sorted tags without changing their established suggestion order. */
fun filterManageableTags(tags: List<String>, query: String): List<String> {
    val needle = query.trim().lowercase()
    return if (needle.isEmpty()) tags else tags.filter { tag -> tag.lowercase().contains(needle) }
}
