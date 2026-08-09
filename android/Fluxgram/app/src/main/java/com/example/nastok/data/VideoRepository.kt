package com.example.nastok.data

import android.content.Context
import com.example.nastok.folderPathFromVideoPath
import com.example.nastok.normalizeFolderPath
import com.example.nastok.VideoSizeRange
import com.example.nastok.data.db.AppDatabase
import com.example.nastok.data.db.FolderAvatarEntity
import com.example.nastok.data.db.FolderCount
import com.example.nastok.data.db.InteractionEntity
import com.example.nastok.data.db.VideoEntity
import com.example.nastok.net.DavEntry
import com.example.nastok.net.WebDavClient
import com.example.nastok.net.NasIndexClient
import com.example.nastok.net.NasIndexFetchResult
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

/** Result of a rescan: total in the index now, plus what changed this run. */
data class RescanResult(val total: Int, val added: Int, val removed: Int)

/** Bridges the WebDAV scanner and the Room index. */
class VideoRepository(private val context: Context) {

    private val dao = AppDatabase.get(context).videoDao()
    private val interactionDao = AppDatabase.get(context).interactionDao()
    private val avatarDao = AppDatabase.get(context).folderAvatarDao()

    suspend fun indexedCount(): Int = withContext(Dispatchers.IO) { dao.count() }

    /** The avatar image path for the folder a video lives in, or null if none.
     *  The scan stored folder keys WITH a trailing slash (the WebDAV dir form), so we
     *  query both with and without it to be robust. */
    suspend fun avatarForVideo(videoPath: String): String? = withContext(Dispatchers.IO) {
        val folder = videoPath.substringBeforeLast('/', "")
        if (folder.isEmpty()) return@withContext null
        avatarDao.imageForFolder("$folder/")        // scan stores dir paths with trailing '/'
            ?: avatarDao.imageForFolder(folder)      // fallback, just in case
    }

    suspend fun allPaths(): List<String> = withContext(Dispatchers.IO) { dao.allPaths() }

    suspend fun video(path: String): VideoEntity? = withContext(Dispatchers.IO) { dao.byPath(path) }

    suspend fun removePath(path: String) = withContext(Dispatchers.IO) {
        dao.deletePaths(listOf(path))
    }

    suspend fun folderCounts(): List<FolderCount> = withContext(Dispatchers.IO) {
        dao.allPaths()
            .groupingBy { folderPathFromVideoPath(it) }
            .eachCount()
            .map { (folder, count) -> FolderCount(folder, count) }
    }

    /** File-name substring search (case-insensitive), newest first. Blank query → empty. */
    suspend fun search(query: String): List<String> = withContext(Dispatchers.IO) {
        val q = query.trim()
        if (q.isEmpty()) emptyList() else dao.searchPaths(q)
    }

    /** Paths in the given folders, chunked so a long selection stays under SQLite's
     *  variable limit. */
    suspend fun pathsInFolders(folders: List<String>): List<String> = withContext(Dispatchers.IO) {
        if (folders.isEmpty()) {
            emptyList()
        } else {
            val folderSet = folders.mapTo(HashSet()) { normalizeFolderPath(it) }
            dao.allPaths().filter { folderPathFromVideoPath(it) in folderSet }
        }
    }

    suspend fun totalSizeInFolders(folders: List<String>): Long = withContext(Dispatchers.IO) {
        if (folders.isEmpty()) {
            0L
        } else {
            val folderSet = folders.mapTo(HashSet()) { normalizeFolderPath(it) }
            dao.all()
                .filter { folderPathFromVideoPath(it.path) in folderSet }
                .sumOf { it.size }
        }
    }

    suspend fun pathsInSizeRange(range: VideoSizeRange): List<String> = withContext(Dispatchers.IO) {
        dao.pathsInSizeRange(range.minBytes, range.maxBytesExclusive)
    }

    suspend fun countNewSince(since: Long): Int = withContext(Dispatchers.IO) { dao.countNewSince(since) }

    suspend fun pathsNewSince(since: Long): List<String> = withContext(Dispatchers.IO) { dao.pathsNewSince(since) }

    // --- Likes / favorites / watched ---
    suspend fun interaction(path: String): InteractionEntity? =
        withContext(Dispatchers.IO) { interactionDao.byPath(path) }

    suspend fun setLiked(path: String, liked: Boolean) = withContext(Dispatchers.IO) {
        val cur = interactionDao.byPath(path) ?: InteractionEntity(path)
        interactionDao.upsert(cur.copy(liked = liked))
    }

    suspend fun setFavorited(path: String, favorited: Boolean) = withContext(Dispatchers.IO) {
        val cur = interactionDao.byPath(path) ?: InteractionEntity(path)
        interactionDao.upsert(cur.copy(favorited = favorited))
    }

    suspend fun favoritePaths(): List<String> = withContext(Dispatchers.IO) { interactionDao.favoritePaths() }

    suspend fun watchedPaths(): Set<String> = withContext(Dispatchers.IO) {
        interactionDao.watchedPaths().toHashSet()
    }

    /** Stamp [path] watched now. UPDATE first (cheap, common case); insert a row only
     *  if the video was never interacted with before. */
    suspend fun markWatched(path: String, ts: Long = System.currentTimeMillis()) =
        withContext(Dispatchers.IO) {
            if (interactionDao.touchWatched(path, ts) == 0) {
                interactionDao.upsert(InteractionEntity(path, watchedAt = ts))
            }
        }

    /** Scan the NAS and reconcile the index incrementally: insert newly-found videos,
     *  delete ones that vanished, and leave untouched files (and their addedAt) alone —
     *  so "newest" ordering and likes survive a rescan. [onProgress] runs on a
     *  background thread. */
    suspend fun rescan(
        settings: NasSettings,
        onProgress: (videos: Int, folders: Int) -> Unit,
        shouldStop: () -> Boolean = { false },
    ): RescanResult = withContext(Dispatchers.IO) {
        val now = System.currentTimeMillis()
        val found = LinkedHashMap<String, DavEntry>()
        val avatars = ArrayList<FolderAvatarEntity>()
        val existingCount = dao.count()
        when (val remoteResult = NasIndexClient(context).fetch(settings, existingCount)) {
            NasIndexFetchResult.NotModified -> return@withContext RescanResult(existingCount, 0, 0)
            is NasIndexFetchResult.Loaded -> {
                val remoteIndex = remoteResult.index
                val root = settings.normalizedRootPath
                remoteIndex.videos.forEachIndexed { index, entry ->
                    found["$root/${entry.path}"] = DavEntry("$root/${entry.path}", false, entry.size)
                    if (index % 200 == 0) onProgress(index + 1, 0)
                }
                remoteIndex.avatars.forEach { avatar ->
                    avatars.add(FolderAvatarEntity("$root/${avatar.folder}", "$root/${avatar.path}"))
                }
                onProgress(found.size, 0)
            }
            null -> {
                WebDavClient(settings).scan(
                    startPath = settings.normalizedRootPath,
                    onVideo = { entry -> found[entry.path] = entry },
                    onProgress = onProgress,
                    onFolderImage = { folderPath, imagePath ->
                        avatars.add(FolderAvatarEntity(folderPath, imagePath))
                    },
                    shouldStop = shouldStop,
                )
            }
        }

        // If the scan was cancelled, don't reconcile against a partial listing —
        // that would wrongly delete everything not yet visited.
        if (shouldStop()) {
            return@withContext RescanResult(dao.count(), 0, 0)
        }

        val existingVideos = dao.allVideos().associateBy { it.path }
        val existing = existingVideos.keys
        val foundPaths = found.keys

        val toInsert = found.values.filter { it.path !in existing }.map { it.toEntity(now) }
        val toUpdate = found.values.mapNotNull { entry ->
            val current = existingVideos[entry.path] ?: return@mapNotNull null
            val updated = entry.toEntity(current.addedAt)
            if (updated == current) null else updated
        }
        val toDelete = existing.filter { it !in foundPaths }

        toInsert.chunked(500).forEach { dao.insertAll(it) }
        toUpdate.chunked(500).forEach { dao.updateAll(it) }
        toDelete.chunked(900).forEach { dao.deletePaths(it) }

        // Rebuild the folder→avatar map from scratch (small; one row per folder).
        avatarDao.clear()
        avatars.chunked(500).forEach { avatarDao.insertAll(it) }

        RescanResult(total = dao.count(), added = toInsert.size, removed = toDelete.size)
    }

    /** Probe the NAS with the given settings (used by the settings "test" button). */
    suspend fun testConnection(settings: NasSettings): WebDavClient.TestResult =
        withContext(Dispatchers.IO) { WebDavClient(settings).testConnection() }

    private fun DavEntry.toEntity(now: Long): VideoEntity {
        val name = path.substringAfterLast('/')
        val folder = folderPathFromVideoPath(path)
        return VideoEntity(path = path, name = name, folder = folder, size = size, addedAt = now)
    }
}
