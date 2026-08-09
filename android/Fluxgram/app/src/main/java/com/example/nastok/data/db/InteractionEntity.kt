package com.example.nastok.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/** Per-video local interaction state (like / favorite / watched). Keyed by the video
 *  path, kept separate from [VideoEntity] so a rescan never wipes the user's likes.
 *  [watchedAt] is the epoch-millis of the last time the video was played (0 = never),
 *  used to push already-seen videos to the back of the shuffled feed. */
@Entity(tableName = "interactions")
data class InteractionEntity(
    @PrimaryKey val path: String,
    val liked: Boolean = false,
    val favorited: Boolean = false,
    val watchedAt: Long = 0L,
)
