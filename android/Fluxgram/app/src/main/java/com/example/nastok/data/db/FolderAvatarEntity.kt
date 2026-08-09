package com.example.nastok.data.db

import androidx.room.Entity
import androidx.room.PrimaryKey

/** A folder's avatar image, discovered during scan. [folderPath] is the full
 *  server-relative directory path (e.g. /ddd4/mp4/片); [imagePath] is the chosen image
 *  file inside it. Rebuilt on every rescan. */
@Entity(tableName = "folder_avatars")
data class FolderAvatarEntity(
    @PrimaryKey val folderPath: String,
    val imagePath: String,
)
