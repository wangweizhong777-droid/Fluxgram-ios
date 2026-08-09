package com.example.nastok.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query

@Dao
interface InteractionDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(item: InteractionEntity)

    @Query("SELECT * FROM interactions WHERE path = :path LIMIT 1")
    suspend fun byPath(path: String): InteractionEntity?

    @Query("SELECT path FROM interactions WHERE favorited = 1")
    suspend fun favoritePaths(): List<String>

    @Query("SELECT COUNT(*) FROM interactions WHERE favorited = 1")
    suspend fun favoriteCount(): Int

    /** Paths that have been watched at least once (watchedAt > 0). Used to push
     *  already-seen videos to the back of the shuffled feed. */
    @Query("SELECT path FROM interactions WHERE watchedAt > 0")
    suspend fun watchedPaths(): List<String>

    /** Stamp [path] as watched at [ts]. Upserts so a never-seen video gets a row. */
    @Query("UPDATE interactions SET watchedAt = :ts WHERE path = :path")
    suspend fun touchWatched(path: String, ts: Long): Int
}
