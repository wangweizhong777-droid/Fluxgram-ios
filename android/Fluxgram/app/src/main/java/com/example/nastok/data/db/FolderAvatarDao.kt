package com.example.nastok.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface FolderAvatarDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(items: List<FolderAvatarEntity>)

    @Query("SELECT imagePath FROM folder_avatars WHERE folderPath = :folderPath LIMIT 1")
    suspend fun imageForFolder(folderPath: String): String?

    @Query("DELETE FROM folder_avatars")
    suspend fun clear()
}
