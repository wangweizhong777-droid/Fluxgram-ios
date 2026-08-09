package com.example.nastok

import android.app.AlertDialog
import android.content.Intent
import android.content.ActivityNotFoundException
import android.content.pm.ActivityInfo
import android.net.Uri
import android.content.res.Configuration
import android.os.Bundle
import android.widget.EditText
import android.widget.Toast
import androidx.activity.viewModels
import androidx.appcompat.app.AppCompatActivity
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.RecyclerView
import androidx.viewpager2.widget.ViewPager2
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.MediaProfileStore
import com.example.nastok.data.MediaTagStore
import com.example.nastok.data.MediaTrashStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.databinding.ActivityFeedBinding
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** Vertical TikTok-style feed: one video per page, swipe up/down to move on. */
class FeedActivity : AppCompatActivity() {

    private lateinit var binding: ActivityFeedBinding
    private val vm: FeedViewModel by viewModels()
    private lateinit var adapter: FeedAdapter
    private var currentPosition = -1
    // Counts videos that failed back-to-back without one playing. A run of these is the
    // signature of the NAS having gone offline, so we stop the skip-storm and warn.
    private var consecutiveErrors = 0
    private val repo by lazy { VideoRepository(applicationContext) }
    private val thumbs by lazy { ThumbnailStore(applicationContext) }
    private val avatars by lazy { com.example.nastok.data.AvatarStore(applicationContext) }
    private val store by lazy { SettingsStore(applicationContext) }
    private val tags = MediaTagStore.shared
    private val profiles by lazy { MediaProfileStore() }
    private val mediaTrash by lazy { MediaTrashStore() }

    /** Intent extras let the favorites/folder screens drive what plays and from where. */
    private val mode: FeedMode by lazy {
        runCatching { FeedMode.valueOf(intent.getStringExtra(EXTRA_MODE) ?: "") }
            .getOrDefault(FeedMode.ALL)
    }
    private val startIndex by lazy { intent.getIntExtra(EXTRA_START_INDEX, 0) }
    private val folders by lazy {
        intent.getStringArrayListExtra(EXTRA_FOLDERS)?.toList() ?: emptyList()
    }
    private val explicitPaths by lazy {
        intent.getStringArrayListExtra(EXTRA_PATHS)?.toList() ?: emptyList()
    }
    private val sizeRangePreset by lazy {
        runCatching {
            intent.getStringExtra(EXTRA_SIZE_RANGE_PRESET)?.let(VideoSizeRangePreset::valueOf)
        }.getOrNull()
    }
    private val sizeRange by lazy {
        val minBytes = intent.getLongExtra(EXTRA_SIZE_MIN_BYTES, -1L)
        val maxBytes = intent.getLongExtra(EXTRA_SIZE_MAX_BYTES, -1L)
        when {
            minBytes >= 0L -> VideoSizeRange(
                minBytes = minBytes,
                maxBytesExclusive = maxBytes.takeIf { it >= 0L },
            )
            else -> sizeRangePreset?.range
        }
    }

    /** Bridges the adapter's like/favorite UI to the Room-backed repository. */
    private val interactionHost = object : FeedAdapter.InteractionHost {
        override fun loadInteraction(path: String, cb: (Boolean, Boolean) -> Unit) {
            lifecycleScope.launch {
                val i = repo.interaction(path)
                cb(i?.liked == true, i?.favorited == true)
                val remote = profiles.profileFor(vm.settings, path) ?: return@launch
                repo.setLiked(path, remote.liked)
                repo.setFavorited(path, remote.favorited)
                cb(remote.liked, remote.favorited)
            }
        }
        override fun setLiked(path: String, liked: Boolean) {
            lifecycleScope.launch(Dispatchers.IO) {
                repo.setLiked(path, liked)
                profiles.updateInteraction(vm.settings, path, liked = liked)
            }
        }
        override fun setFavorited(path: String, favorited: Boolean) {
            lifecycleScope.launch(Dispatchers.IO) {
                repo.setFavorited(path, favorited)
                profiles.updateInteraction(vm.settings, path, favorited = favorited)
            }
        }
        override fun onPlaybackError(position: Int, path: String) {
            if (position != currentPosition) return
            consecutiveErrors++
            if (consecutiveErrors >= MAX_CONSECUTIVE_ERRORS) {
                // Too many failures in a row: almost certainly the NAS is unreachable.
                // Stop skipping and tell the user instead of flipping through the whole feed.
                binding.emptyHint.text = "连不上 NAS，视频无法播放\n检查 NAS 是否在线、手机是否在同一局域网"
                binding.emptyHint.visibility = android.view.View.VISIBLE
                showConnectionError()
                return
            }
            // Otherwise treat it as a single bad file and skip to the next.
            val next = position + 1
            if (next < adapter.itemCount) {
                binding.pager.setCurrentItem(next, true)
            }
        }
        override fun onPlaybackRetry() {
            showReconnectStatus()
        }
        override fun onPlaybackOk() {
            // A video is playing fine, so the NAS is reachable: clear any error state.
            consecutiveErrors = 0
            if (binding.emptyHint.visibility == android.view.View.VISIBLE) {
                binding.emptyHint.visibility = android.view.View.GONE
            }
            binding.errorPanel.visibility = android.view.View.GONE
        }
        override fun loadAvatar(path: String, cb: (android.graphics.Bitmap?) -> Unit) {
            lifecycleScope.launch {
                val img = repo.avatarForVideo(path)
                val bmp = if (img != null) {
                    avatars.get(vm.settings, img)
                } else {
                    val folder = folderPathFromVideoPath(path)
                    val samplePath = repo.pathsInFolders(listOf(folder)).firstOrNull()
                    samplePath?.let { thumbs.getOrGenerate(vm.settings, it)?.let(::toCircleAvatar) }
                }
                cb(bmp)
            }
        }
        override fun loadTags(path: String, cb: (List<String>?) -> Unit) {
            lifecycleScope.launch {
                cb(tags.tagsFor(vm.settings, path))
            }
        }
        override fun onEditTags(path: String, currentTags: List<String>, onSaved: (List<String>) -> Unit) {
            val input = EditText(this@FeedActivity).apply {
                setText(currentTags.joinToString(", "))
                setSingleLine(false)
            }
            val suggestions = android.widget.LinearLayout(this@FeedActivity).apply {
                orientation = android.widget.LinearLayout.VERTICAL
            }
            val suggestionScroll = android.widget.ScrollView(this@FeedActivity).apply {
                isFillViewport = false
                addView(suggestions)
            }
            val container = android.widget.LinearLayout(this@FeedActivity).apply {
                orientation = android.widget.LinearLayout.VERTICAL
                val padding = (16 * resources.displayMetrics.density).toInt()
                setPadding(padding, 0, padding, 0)
                addView(input)
                addView(suggestionScroll, android.widget.LinearLayout.LayoutParams(
                    android.widget.LinearLayout.LayoutParams.MATCH_PARENT,
                    (320 * resources.displayMetrics.density).toInt(),
                ))
            }
            val dialog = AlertDialog.Builder(this@FeedActivity)
                .setTitle("编辑标签")
                .setView(container)
                .setNegativeButton("取消", null)
                .setPositiveButton("保存") { _, _ ->
                    val next = com.example.nastok.data.parseManualTags(input.text.toString())
                    lifecycleScope.launch {
                        val saved = tags.update(vm.settings, path, next)
                        if (saved == null) {
                            Toast.makeText(this@FeedActivity, "标签保存失败", Toast.LENGTH_SHORT).show()
                        } else {
                            onSaved(saved)
                            Toast.makeText(this@FeedActivity, "标签已保存", Toast.LENGTH_SHORT).show()
                        }
                    }
                }
                .show()
            lifecycleScope.launch {
                val items = tags.suggestionsFor(vm.settings, path).orEmpty()
                    .filterNot { suggestion -> currentTags.any { it.equals(suggestion, ignoreCase = true) } }
                if (items.isEmpty() || isFinishing || !dialog.isShowing) return@launch
                val title = android.widget.TextView(this@FeedActivity).apply {
                    text = "常用标签"
                    setPadding(0, (12 * resources.displayMetrics.density).toInt(), 0, 0)
                }
                suggestions.addView(title)
                val grid = android.widget.GridLayout(this@FeedActivity).apply {
                    columnCount = 3
                    useDefaultMargins = false
                }
                suggestions.addView(grid)
                items.forEach { suggestion ->
                    val option = android.widget.TextView(this@FeedActivity).apply {
                        text = "+ $suggestion"
                        textSize = 16f
                        maxLines = 1
                        ellipsize = android.text.TextUtils.TruncateAt.END
                        gravity = android.view.Gravity.CENTER_VERTICAL
                        val vertical = (4 * resources.displayMetrics.density).toInt()
                        setPadding(0, vertical, (8 * resources.displayMetrics.density).toInt(), vertical)
                        setOnClickListener {
                            input.setText(com.example.nastok.data.parseManualTags(input.text.toString())
                                .plus(suggestion).joinToString(", "))
                            input.setSelection(input.text.length)
                        }
                    }
                    grid.addView(option, android.widget.GridLayout.LayoutParams(
                        android.widget.GridLayout.spec(android.widget.GridLayout.UNDEFINED, 1f),
                        android.widget.GridLayout.spec(android.widget.GridLayout.UNDEFINED, 1f),
                    ).apply {
                        width = 0
                        height = (36 * resources.displayMetrics.density).toInt()
                    })
                }
            }
        }
        override fun onMoveToTrash(path: String) {
            confirmMoveToTrash(path)
        }
        override fun onOpenTag(tag: String) {
            openTagProfile(tag)
        }
        override fun onMuteChanged(muted: Boolean) {
            lifecycleScope.launch(Dispatchers.IO) { store.setMuted(muted) }
        }
        override fun onOpenFolder(folderPath: String) {
            startActivity(Intent(this@FeedActivity, FolderProfileActivity::class.java).apply {
                putExtra(FolderProfileActivity.EXTRA_FOLDER_NAME, folderPath)
            })
        }
        override fun onShowDetails(path: String) {
            showDetailsDialog(path)
        }
        override fun onToggleOrientation() {
            val landscape = resources.configuration.orientation == Configuration.ORIENTATION_LANDSCAPE
            requestedOrientation = if (landscape) {
                ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
            } else {
                ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFeedBinding.inflate(layoutInflater)
        setContentView(binding.root)

        enableImmersiveMode()

        binding.pager.orientation = ViewPager2.ORIENTATION_VERTICAL
        binding.pager.offscreenPageLimit = 1
        binding.btnRetry.setOnClickListener {
            consecutiveErrors = 0
            showReconnectStatus()
            binding.pager.post { playAt(currentPosition) }
        }
        binding.btnOpenSettings.setOnClickListener {
            startActivity(Intent(this, HomeActivity::class.java).apply {
                putExtra(HomeActivity.EXTRA_TAB, R.id.nav_settings)
                addFlags(Intent.FLAG_ACTIVITY_CLEAR_TOP or Intent.FLAG_ACTIVITY_SINGLE_TOP)
            })
            finish()
        }

        lifecycleScope.launch {
            vm.ready.collectLatest { ready ->
                if (ready) {
                    val savedMuted = store.muted.first()
                    setupAdapter(savedMuted)
                    lifecycleScope.launch(Dispatchers.IO) {
                        tags.preloadAll(vm.settings)
                    }
                }
            }
        }
        vm.load(mode, folders, explicitPaths, sizeRange)
    }

    private fun showReconnectStatus() {
        binding.errorTitle.text = "正在重新连接 NAS..."
        binding.errorMessage.text = "网络短暂中断，播放器正在重试"
        binding.errorActions.visibility = android.view.View.GONE
        binding.errorPanel.visibility = android.view.View.VISIBLE
    }

    private fun confirmMoveToTrash(path: String) {
        AlertDialog.Builder(this, com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
            .setTitle("移入回收站")
            .setMessage("该视频会从播放库中移除，并在 NAS 回收站保留 7 天。")
            .setNegativeButton("取消", null)
            .setPositiveButton("移入回收站") { _, _ ->
                lifecycleScope.launch {
                    val moved = mediaTrash.move(vm.settings, path)
                    if (moved == null) {
                        Toast.makeText(this@FeedActivity, "移入回收站失败", Toast.LENGTH_SHORT).show()
                        return@launch
                    }
                    val removedPosition = vm.paths.value.indexOf(path)
                    val resumePosition = playbackPositionAfterRemoval(
                        currentPosition = currentPosition,
                        removedPosition = removedPosition,
                        remainingCount = vm.paths.value.size - 1,
                    )
                    repo.removePath(path)
                    vm.removePath(path)
                    resumePosition?.let { position ->
                        currentPosition = position
                        binding.pager.post {
                            if (position < adapter.itemCount) {
                                binding.pager.setCurrentItem(position, false)
                                playAt(position)
                                markWatched(position)
                            }
                        }
                    }
                    Toast.makeText(this@FeedActivity, "已移入回收站，7 天内可恢复", Toast.LENGTH_SHORT).show()
                }
            }
            .show()
    }

    private fun openTagProfile(tag: String) {
        startActivity(Intent(this, TagProfileActivity::class.java).apply {
            putExtra(TagProfileActivity.EXTRA_TAG, tag)
        })
    }

    private fun showConnectionError() {
        binding.emptyHint.visibility = android.view.View.GONE
        binding.errorTitle.text = "无法连接 NAS"
        binding.errorMessage.text = "请检查 NAS 是否在线，以及手机是否连接到同一局域网"
        binding.errorActions.visibility = android.view.View.VISIBLE
        binding.errorPanel.visibility = android.view.View.VISIBLE
    }

    /** Draw edge-to-edge and hide the status/navigation bars so video fills the screen,
     *  TikTok-style. Bars reappear on a swipe from the edge, then auto-hide again. */
    private fun enableImmersiveMode() {
        WindowCompat.setDecorFitsSystemWindows(window, false)
        WindowInsetsControllerCompat(window, binding.root).apply {
            hide(WindowInsetsCompat.Type.systemBars())
            systemBarsBehavior =
                WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        // Re-hide bars if they came back (e.g. after a transient swipe-in).
        if (hasFocus) enableImmersiveMode()
    }

    private fun setupAdapter(initialMuted: Boolean) {
        if (::adapter.isInitialized) return
        adapter = FeedAdapter(applicationContext, vm.settings, interactionHost, thumbs, initialMuted)
        binding.pager.adapter = adapter

        lifecycleScope.launch {
            vm.paths.collectLatest { paths ->
                if (paths.isEmpty()) {
                    forEachHolder { adapter.releaseHolder(it) }
                    binding.emptyHint.text = when (mode) {
                        FeedMode.FAVORITES -> "还没有收藏，双击或点星收藏喜欢的视频"
                        FeedMode.SIZE_RANGE -> "没有这个大小范围的视频"
                        FeedMode.TAGGED -> "没有已打标签的视频，或标签服务暂时不可用"
                        FeedMode.UNTAGGED -> "没有未打标签的视频，或标签服务暂时不可用"
                        FeedMode.INBOX -> "没有待整理的视频"
                        FeedMode.EXPLICIT -> "没有匹配的视频"
                        else -> "还没有视频，请先在主界面扫描"
                    }
                    binding.emptyHint.visibility = android.view.View.VISIBLE
                    return@collectLatest
                }
                binding.emptyHint.visibility = android.view.View.GONE
                adapter.submit(paths)
                if (currentPosition < 0 || currentPosition >= paths.size) {
                    val start = startIndex.coerceIn(0, paths.size - 1)
                    currentPosition = start
                    binding.pager.setCurrentItem(start, false)
                    binding.pager.post { playAt(start) }
                    markWatched(start)
                }
            }
        }

        binding.pager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                if (position == currentPosition) return
                currentPosition = position
                playAt(position)
                markWatched(position)
                // Loop endlessly (ALL/FOLDER): when nearing the end, append more.
                if (position >= adapter.itemCount - 3) {
                    vm.appendReshuffled()
                }
            }
        })
    }

    /** Play the holder at [position], pause others, and warm up the next page so the
     *  swipe to it is near-instant. */
    private fun playAt(position: Int) {
        val rv = binding.pager.getChildAt(0) as? RecyclerView ?: return
        for (i in 0 until rv.childCount) {
            val holder = rv.getChildViewHolder(rv.getChildAt(i)) as? FeedAdapter.VH
            val holderPos = holder?.bindingAdapterPosition
            when (holderPos) {
                position -> adapter.playHolder(holder)
                position + 1 -> { adapter.pauseHolder(holder); adapter.prepareHolder(holder) }
                else -> adapter.pauseHolder(holder)
            }
        }
    }

    private fun markWatched(position: Int) {
        val path = vm.paths.value.getOrNull(position) ?: return
        lifecycleScope.launch(Dispatchers.IO) { repo.markWatched(path) }
    }

    /** Run [action] for every ViewHolder currently attached to the pager. */
    private fun forEachHolder(action: (FeedAdapter.VH) -> Unit) {
        if (!::adapter.isInitialized) return
        val rv = binding.pager.getChildAt(0) as? RecyclerView ?: return
        for (i in 0 until rv.childCount) {
            (rv.getChildViewHolder(rv.getChildAt(i)) as? FeedAdapter.VH)?.let(action)
        }
    }

    override fun onPause() {
        super.onPause()
        // Stop playback the moment we leave the foreground.
        forEachHolder { adapter.pauseHolder(it) }
    }

    override fun onStop() {
        super.onStop()
        // Fully release players so audio can never leak while we're in the background
        // (pausing alone has proven flaky). They're recreated on resume by playAt().
        forEachHolder { adapter.releaseHolder(it) }
    }

    override fun onResume() {
        super.onResume()
        if (currentPosition >= 0) binding.pager.post { playAt(currentPosition) }
    }

    /** Shows the NAS media fact record, falling back to local WebDAV metadata offline. */
    private fun showDetailsDialog(path: String) {
        lifecycleScope.launch {
            val video = repo.video(path)
            val folder = folderDisplayName(folderPathFromVideoPath(path), vm.settings.normalizedRootPath)
            val name = path.substringAfterLast('/')
            val sizeStr = video?.let { formatByteSize(it.size) } ?: "未知"
            val detail = tags.detailsFor(vm.settings, path)
            val sourceUrl = detail?.sourceUrl
                ?.takeIf { it.isNotBlank() }
                ?: profiles.profileFor(vm.settings, path)?.sourceUrl.orEmpty()
            val msg = buildString {
                append("文件名: ${detail?.fileName?.ifBlank { name } ?: name}\n")
                append("文件夹: $folder\n")
                append("大小: ${detail?.fileSize?.takeIf { it > 0 }?.let(::formatByteSize) ?: sizeStr}\n")
                append("路径: ${detail?.relativePath?.ifBlank { path } ?: path}")
                detail?.tags?.takeIf { it.isNotEmpty() }?.let { append("\n标签: ${it.joinToString("  ") { tag -> "#$tag" }}") }
                detail?.note?.takeIf { it.isNotBlank() }?.let { append("\n备注: $it") }
                detail?.downloadedAt?.takeIf { it.isNotBlank() }?.let { append("\n下载时间: $it") }
                detail?.sourceTitle?.takeIf { it.isNotBlank() }?.let { append("\n来源: $it") }
                detail?.sourceText?.takeIf { it.isNotBlank() }?.let { append("\n原消息: $it") }
                detail?.takeIf { it.ruleApplied && it.ruleId.isNotBlank() }?.let { append("\n采集规则: ${it.ruleId}") }
            }
            val dialog = AlertDialog.Builder(this@FeedActivity, com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
                .setTitle("视频详情")
                .setMessage(msg)
                .setNeutralButton(if (detail?.inbox == true) "完成整理" else "临时排除此文件夹") { _, _ ->
                    if (detail?.inbox == true) {
                        lifecycleScope.launch {
                            if (tags.updateInbox(vm.settings, path, false) == null) {
                                Toast.makeText(this@FeedActivity, "待整理状态更新失败", Toast.LENGTH_SHORT).show()
                            } else {
                                vm.removePath(path)
                                Toast.makeText(this@FeedActivity, "已移出待整理", Toast.LENGTH_SHORT).show()
                            }
                        }
                    } else {
                        temporarilyExcludeFolder(folderPathFromVideoPath(path))
                    }
                }
                .setPositiveButton("关闭", null)
            if (sourceUrl.isNotBlank()) {
                dialog.setNegativeButton("打开来源") { _, _ -> openTelegramSource(sourceUrl) }
            }
            dialog.show()
        }
    }

    private fun openTelegramSource(sourceUrl: String) {
        val uri = Uri.parse(sourceUrl)
        val intent = Intent(Intent.ACTION_VIEW, uri).setPackage("tw.nekomimi.nekogram")
        try {
            startActivity(intent)
        } catch (_: ActivityNotFoundException) {
            startActivity(Intent(Intent.ACTION_VIEW, uri))
        }
    }

    private fun temporarilyExcludeFolder(folderPath: String) {
        if (folderPath.isBlank()) return
        forEachHolder { adapter.releaseHolder(it) }
        currentPosition = -1
        vm.temporarilyExcludeFolder(folderPath)
        Toast.makeText(
            this,
            "已临时排除 ${folderDisplayName(folderPath, vm.settings.normalizedRootPath)}",
            Toast.LENGTH_SHORT
        ).show()
    }

    companion object {
        const val EXTRA_MODE = "feed_mode"
        const val EXTRA_FOLDERS = "feed_folders"
        const val EXTRA_PATHS = "feed_paths"
        const val EXTRA_START_INDEX = "feed_start_index"
        const val EXTRA_SIZE_RANGE_PRESET = "feed_size_range_preset"
        const val EXTRA_SIZE_MIN_BYTES = "feed_size_min_bytes"
        const val EXTRA_SIZE_MAX_BYTES = "feed_size_max_bytes"
        /** Consecutive playback failures that mean "NAS offline", not "one bad file". */
        private const val MAX_CONSECUTIVE_ERRORS = 4
    }
}
