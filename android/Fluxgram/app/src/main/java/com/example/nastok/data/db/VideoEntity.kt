package com.example.nastok.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/** One video file discovered on the NAS. [path] is the WebDAV path relative to the
 *  server root (e.g. /ddd4/mp4/foo/bar.mp4) and is the natural unique key. */
@Entity(tableName = "videos")
data class VideoEntity(
    @PrimaryKey val path: String,
    val name: String,
    val folder: String,
    val size: Long,
    val addedAt: Long,
)
