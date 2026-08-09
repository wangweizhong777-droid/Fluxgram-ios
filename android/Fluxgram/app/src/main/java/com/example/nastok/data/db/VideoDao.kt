package com.example.nastok.data.db

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update

/** A folder name plus how many videos it holds, for the folder-picker screen. */
data class FolderCount(val folder: String, val cnt: Int)

@Dao
interface VideoDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(videos: List<VideoEntity>)

    @Update
    suspend fun updateAll(videos: List<VideoEntity>)

    @Query("SELECT COUNT(*) FROM videos")
    suspend fun count(): Int

    /** All paths, used to build the shuffled feed without loading full rows. */
    @Query("SELECT path FROM videos")
    suspend fun allPaths(): List<String>

    @Query("SELECT * FROM videos")
    suspend fun allVideos(): List<VideoEntity>

    @Query("SELECT * FROM videos WHERE path = :path LIMIT 1")
    suspend fun byPath(path: String): VideoEntity?

    @Query("SELECT * FROM videos ORDER BY addedAt DESC")
    suspend fun all(): List<VideoEntity>

    /** Video counts grouped by folder name, busiest first — drives the folder picker. */
    @Query(
        "SELECT folder AS folder, COUNT(*) AS cnt FROM videos " +
        "GROUP BY folder ORDER BY cnt DESC"
    )
    suspend fun folderCounts(): List<FolderCount>

    /** Paths belonging to any of [folders]. Caller chunks to stay under SQLite's
     *  variable limit. */
    @Query("SELECT path FROM videos WHERE folder IN (:folders)")
    suspend fun pathsInFolders(folders: List<String>): List<String>

    /** Delete a batch of paths (incremental rescan removes vanished files).
     *  Caller chunks to stay under SQLite's ~999 variable limit. */
    @Query("DELETE FROM videos WHERE path IN (:paths)")
    suspend fun deletePaths(paths: List<String>)

    /** Paths whose file name matches [q] (case-insensitive substring), newest first.
     *  Capped so a broad query on a 7-8k library doesn't return everything. */
    @Query(
        "SELECT path FROM videos WHERE name LIKE '%' || :q || '%' " +
        "ORDER BY addedAt DESC LIMIT :limit"
    )
    suspend fun searchPaths(q: String, limit: Int = 300): List<String>

    /** Total byte size of videos in the given folders. */
    @Query("SELECT COALESCE(SUM(size), 0) FROM videos WHERE folder IN (:folders)")
    suspend fun totalSizeInFolders(folders: List<String>): Long

    @Query(
        "SELECT path FROM videos " +
            "WHERE size >= :minBytes AND (:maxBytesExclusive IS NULL OR size < :maxBytesExclusive)"
    )
    suspend fun pathsInSizeRange(minBytes: Long, maxBytesExclusive: Long?): List<String>

    /** Count of videos added after [since] (epoch millis). */
    @Query("SELECT COUNT(*) FROM videos WHERE addedAt > :since")
    suspend fun countNewSince(since: Long): Int

    /** Paths of videos added after [since], newest first. */
    @Query("SELECT path FROM videos WHERE addedAt > :since ORDER BY addedAt DESC")
    suspend fun pathsNewSince(since: Long): List<String>

    @Query("DELETE FROM videos")
    suspend fun clear()
}
