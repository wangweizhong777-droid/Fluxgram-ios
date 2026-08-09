package com.example.nastok

import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.example.nastok.data.NasSettings
import com.example.nastok.data.MediaTagStore
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.data.classifyIndexedVideosByTags
import com.example.nastok.data.mediaTagLookupPath
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** What the feed should draw from. EXPLICIT plays a caller-supplied path list as-is
 *  (used by search results). */
enum class FeedMode { ALL, FAVORITES, FOLDER, SIZE_RANGE, TAGGED, UNTAGGED, INBOX, EXPLICIT }

fun tagFeedMode(tagged: Boolean): FeedMode = if (tagged) FeedMode.TAGGED else FeedMode.UNTAGGED

fun removePathFromFeed(paths: List<String>, path: String): List<String> = paths.filterNot { it == path }

fun playbackPositionAfterRemoval(
    currentPosition: Int,
    removedPosition: Int,
    remainingCount: Int,
): Int? = if (currentPosition == removedPosition && remainingCount > 0) {
    currentPosition.coerceAtMost(remainingCount - 1)
} else {
    null
}

fun excludeRecycleBinPaths(paths: List<String>): List<String> = paths.filterNot { path ->
    path.trimEnd('/').split('/').any { segment -> segment == ".fluxtok-trash" }
}

/** Holds the feed of video paths and the current NAS settings. The ordering depends
 *  on [FeedMode]: ALL/FOLDER put unseen videos first (then watched); FAVORITES and
 *  EXPLICIT keep a stable order so opening from a list position is predictable. */
class FeedViewModel(app: Application) : AndroidViewModel(app) {

    private val repo = VideoRepository(app)
    private val store = SettingsStore(app)
    private val tags = MediaTagStore.shared

    private val _paths = MutableStateFlow<List<String>>(emptyList())
    val paths: StateFlow<List<String>> = _paths

    private val _ready = MutableStateFlow(false)
    val ready: StateFlow<Boolean> = _ready

    /** True for ALL/FOLDER (endless reshuffle on scroll); false for FAVORITES/EXPLICIT. */
    var looping = true
        private set

    lateinit var settings: NasSettings
        private set
    private var loadedMode: FeedMode = FeedMode.ALL
    private var loadedFolders: List<String> = emptyList()
    private var loadedExplicitPaths: List<String> = emptyList()
    private var loadedSizeRange: VideoSizeRange? = null

    fun load(
        mode: FeedMode = FeedMode.ALL,
        folders: List<String> = emptyList(),
        explicitPaths: List<String> = emptyList(),
        sizeRange: VideoSizeRange? = null,
    ) {
        viewModelScope.launch {
            loadedMode = mode
            loadedFolders = folders
            loadedExplicitPaths = explicitPaths
            loadedSizeRange = sizeRange
            settings = store.settings.first()
            looping = mode == FeedMode.ALL || mode == FeedMode.FOLDER || mode == FeedMode.SIZE_RANGE
            _paths.value = loadFilteredPaths(mode, folders, explicitPaths, sizeRange)
            _ready.value = true
        }
    }

    fun temporarilyExcludeFolder(folderPath: String) {
        TemporaryPathExclusions.addFolder(folderPath)
        viewModelScope.launch {
            _paths.value = loadFilteredPaths(
                loadedMode,
                loadedFolders,
                loadedExplicitPaths,
                loadedSizeRange,
            )
        }
    }

    fun removePath(path: String) {
        _paths.value = removePathFromFeed(_paths.value, path)
    }

    private suspend fun loadFilteredPaths(
        mode: FeedMode,
        folders: List<String>,
        explicitPaths: List<String>,
        sizeRange: VideoSizeRange?,
    ): List<String> {
        val filtered = excludeRecycleBinPaths(TemporaryPathExclusions.filter(
            when (mode) {
                FeedMode.FAVORITES -> repo.favoritePaths()           // stable order
                FeedMode.EXPLICIT -> explicitPaths                    // as-is
                FeedMode.FOLDER -> repo.pathsInFolders(folders)
                FeedMode.SIZE_RANGE -> sizeRange?.let { repo.pathsInSizeRange(it) }.orEmpty()
                FeedMode.ALL -> repo.allPaths()
                FeedMode.TAGGED, FeedMode.UNTAGGED -> pathsForTagState(mode == FeedMode.TAGGED)
                FeedMode.INBOX -> pathsForInbox()
            }
        ))
        return when (mode) {
            FeedMode.FOLDER, FeedMode.SIZE_RANGE, FeedMode.ALL -> shuffleUnseenFirst(filtered)
            FeedMode.TAGGED, FeedMode.UNTAGGED -> filtered.shuffled()
            FeedMode.INBOX -> filtered.shuffled()
            FeedMode.FAVORITES, FeedMode.EXPLICIT -> filtered
        }
    }

    /** Keeps large tag-state feeds inside the ViewModel instead of exceeding Intent's Binder limit. */
    private suspend fun pathsForTagState(tagged: Boolean): List<String> {
        val taggedPaths = tags.allTaggedPaths(settings) ?: return emptyList()
        val classified = classifyIndexedVideosByTags(
            indexedPaths = repo.allPaths(),
            rootPath = settings.normalizedRootPath,
            taggedPaths = taggedPaths,
        )
        return if (tagged) classified.tagged else classified.untagged
    }

    private suspend fun pathsForInbox(): List<String> {
        val remotePaths = tags.inboxPaths(settings) ?: return emptyList()
        val indexedByRelative = repo.allPaths().mapNotNull { path ->
            mediaTagLookupPath(path, settings.normalizedRootPath)?.let { it to path }
        }.toMap()
        return remotePaths.mapNotNull { indexedByRelative[it] }.distinct()
    }

    /** Shuffle, but float never-watched videos ahead of already-watched ones, so a
     *  huge random library stops serving repeats before you've seen the new stuff. */
    private suspend fun shuffleUnseenFirst(all: List<String>): List<String> {
        if (all.isEmpty()) return all
        val watched = repo.watchedPaths()
        val (seen, unseen) = all.partition { it in watched }
        return unseen.shuffled() + seen.shuffled()
    }

    /** Append another reshuffled copy so the feed loops endlessly (ALL/FOLDER only). */
    fun appendReshuffled() {
        if (!looping) return
        val current = _paths.value
        if (current.isEmpty()) return
        _paths.value = current + current.shuffled()
    }
}
