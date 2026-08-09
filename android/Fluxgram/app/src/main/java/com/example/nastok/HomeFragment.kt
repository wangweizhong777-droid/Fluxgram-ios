package com.example.nastok

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.app.AlertDialog
import android.text.InputType
import android.widget.EditText
import android.widget.LinearLayout
import android.widget.Toast
import androidx.core.widget.addTextChangedListener
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.NasSettings
import com.example.nastok.data.MediaTagStore
import com.example.nastok.data.MediaTrashStore
import com.example.nastok.data.RescanResult
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.data.newVideoBaselineAfterSuccessfulScan
import com.example.nastok.data.shouldMarkScanAsSeenBaseline
import com.example.nastok.data.shouldRepairMissingNewVideoBaseline
import com.example.nastok.data.mediaTagLookupPath
import com.example.nastok.data.parseManualTags
import com.example.nastok.data.trashThumbnailSourcePath
import com.example.nastok.databinding.FragmentHomeBinding
import com.example.nastok.databinding.DialogTagManagerBinding
import com.example.nastok.databinding.ItemManageTagBinding
import com.example.nastok.net.NasTagSummary
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.time.Instant
import java.time.temporal.ChronoUnit

class HomeFragment : Fragment() {

    private var _binding: FragmentHomeBinding? = null
    private val binding get() = _binding!!
    private val store by lazy { SettingsStore(requireContext()) }
    private val repo by lazy { VideoRepository(requireContext()) }
    private val tags = MediaTagStore.shared
    private val mediaTrash by lazy { MediaTrashStore() }
    private val thumbs by lazy { ThumbnailStore(requireContext()) }
    @Volatile private var scanning = false
    @Volatile private var cancelRequested = false
    private var lastScanResult: RescanResult? = null
    private var lastScanFinishedAt: Long = 0L

    override fun onCreateView(inflater: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        _binding = FragmentHomeBinding.inflate(inflater, c, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        binding.btnScan.setOnClickListener {
            if (scanning) requestCancel() else startScan()
        }
        binding.btnEnter.setOnClickListener {
            startActivity(Intent(requireContext(), FeedActivity::class.java))
        }
        binding.btnInbox.setOnClickListener {
            startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                putExtra(FeedActivity.EXTRA_MODE, FeedMode.INBOX.name)
            })
        }
        binding.btnNewVideos.setOnClickListener { openNewVideos() }
        binding.btnSizeRange.setOnClickListener { showSizeRangePicker() }
        binding.btnTags.setOnClickListener { showTagFilterPicker() }
        binding.btnManageTags.setOnClickListener { showTagManager() }
        binding.btnTrash.setOnClickListener { showMediaTrash() }
        binding.btnTaggedVideos.setOnClickListener { openRandomByTagState(tagged = true) }
        binding.btnUntaggedVideos.setOnClickListener { openRandomByTagState(tagged = false) }
    }

    override fun onResume() {
        super.onResume()
        if (!scanning) refreshIndexInfo()
    }

    private fun refreshIndexInfo() {
        viewLifecycleOwner.lifecycleScope.launch {
            val count = repo.indexedCount()
            val lastSeenNew = store.lastSeenNew.first()
            if (shouldRepairMissingNewVideoBaseline(count, lastSeenNew)) {
                store.markNewAsSeen()
            }
            binding.indexCount.text = count.toString()
            if (count > 0) {
                binding.statusPill.text = "已就绪"
                binding.indexInfo.text = buildString {
                    append("索引已建立，可以直接进入全屏视频流；重新扫描会同步 NAS 上的新增与移除。")
                    lastScanResult?.let { result ->
                        append("\n上次扫描：${formatLocalTimestamp(lastScanFinishedAt)}")
                        append("\n新增 ${result.added}，移除 ${result.removed}，总数 ${result.total}")
                    }
                }
                binding.btnEnter.visibility = View.VISIBLE
                binding.btnInbox.visibility = View.VISIBLE
                binding.btnSizeRange.visibility = View.VISIBLE
                binding.btnTags.visibility = View.VISIBLE
                binding.btnManageTags.visibility = View.VISIBLE
                binding.btnTrash.visibility = View.VISIBLE
                binding.btnTaggedVideos.visibility = View.VISIBLE
                binding.btnUntaggedVideos.visibility = View.VISIBLE
                binding.btnScan.text = "重新扫描"
                checkNewVideos()
            } else {
                binding.statusPill.text = "待扫描"
                binding.indexInfo.text = "还没有索引。先扫描 NAS 视频库，之后就能按文件夹、收藏和搜索快速浏览。"
                binding.btnEnter.visibility = View.GONE
                binding.btnInbox.visibility = View.GONE
                binding.btnNewVideos.visibility = View.GONE
                binding.btnSizeRange.visibility = View.GONE
                binding.btnTags.visibility = View.GONE
                binding.btnManageTags.visibility = View.GONE
                binding.btnTrash.visibility = View.GONE
                binding.btnTaggedVideos.visibility = View.GONE
                binding.btnUntaggedVideos.visibility = View.GONE
                binding.btnScan.text = "扫描视频库"
            }
        }
    }

    private suspend fun checkNewVideos() {
        val since = store.lastSeenNew.first()
        val newCount = repo.countNewSince(since)
        if (newCount > 0) {
            binding.btnNewVideos.text = "查看 $newCount 个新视频"
            binding.statusPill.text = "有更新"
            binding.btnNewVideos.visibility = View.VISIBLE
        } else {
            binding.btnNewVideos.visibility = View.GONE
        }
    }

    private fun openNewVideos() {
        viewLifecycleOwner.lifecycleScope.launch {
            val since = store.lastSeenNew.first()
            val paths = repo.pathsNewSince(since)
            store.markNewAsSeen()
            binding.btnNewVideos.visibility = View.GONE
            if (paths.isNotEmpty()) {
                startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                    putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                    putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(paths))
                })
            }
        }
    }

    private fun showMediaTrash() {
        viewLifecycleOwner.lifecycleScope.launch {
            val settings = store.settings.first()
            if (!settings.isTagApiConfigured) {
                Toast.makeText(requireContext(), "请先连接 NAS 标签服务", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val items = mediaTrash.items(settings)
            if (items == null) {
                Toast.makeText(requireContext(), "无法读取回收站", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val content = LinearLayout(requireContext()).apply {
                orientation = LinearLayout.VERTICAL
                val padding = (16 * resources.displayMetrics.density).toInt()
                setPadding(padding, 0, padding, 0)
            }
            if (items.isEmpty()) {
                content.addView(android.widget.TextView(requireContext()).apply {
                    text = "回收站为空"
                    val padding = (16 * resources.displayMetrics.density).toInt()
                    setPadding(0, padding, 0, padding)
                })
            } else {
                var dialog: AlertDialog? = null
                items.forEach { item ->
                    val row = LinearLayout(requireContext()).apply {
                        orientation = LinearLayout.HORIZONTAL
                        gravity = android.view.Gravity.CENTER_VERTICAL
                        setPadding(0, (10 * resources.displayMetrics.density).toInt(), 0, (10 * resources.displayMetrics.density).toInt())
                    }
                    val thumbnail = android.widget.ImageView(requireContext()).apply {
                        tag = item.id
                        scaleType = android.widget.ImageView.ScaleType.CENTER_CROP
                        setBackgroundColor(resources.getColor(R.color.bg_primary, requireContext().theme))
                        contentDescription = null
                    }
                    val originalPath = "${settings.normalizedRootPath}/${item.path.trimStart('/')}"
                    val trashPath = trashThumbnailSourcePath(settings, item)
                    val cached = thumbs.load(originalPath) ?: trashPath?.let(thumbs::load)
                    if (cached != null) {
                        thumbnail.setThumbnailBitmap(cached)
                    } else if (trashPath != null) {
                        viewLifecycleOwner.lifecycleScope.launch {
                            val bitmap = thumbs.getOrGenerate(settings, trashPath)
                            if (bitmap != null && thumbnail.tag == item.id) {
                                thumbnail.setThumbnailBitmap(bitmap)
                            }
                        }
                    }
                    val thumbSize = (72 * resources.displayMetrics.density).toInt()
                    row.addView(thumbnail, LinearLayout.LayoutParams(thumbSize, thumbSize).apply {
                        marginEnd = (12 * resources.displayMetrics.density).toInt()
                    })
                    val text = android.widget.TextView(requireContext()).apply {
                        val days = runCatching {
                            ChronoUnit.DAYS.between(Instant.now(), Instant.parse(item.expiresAt)).coerceAtLeast(0) + 1
                        }.getOrDefault(0)
                        this.text = "${item.path.substringAfterLast('/')}\n剩余 $days 天"
                        maxLines = 2
                    }
                    row.addView(text, LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f))
                    val restore = android.widget.Button(requireContext()).apply {
                        this.text = "恢复"
                        setOnClickListener {
                            viewLifecycleOwner.lifecycleScope.launch {
                                if (mediaTrash.restore(settings, item.id) == null) {
                                    Toast.makeText(requireContext(), "恢复失败，原位置可能已有同名文件", Toast.LENGTH_SHORT).show()
                                } else {
                                    Toast.makeText(requireContext(), "已恢复，重新扫描后会回到播放库", Toast.LENGTH_SHORT).show()
                                    dialog?.dismiss()
                                }
                            }
                        }
                    }
                    row.addView(restore)
                    content.addView(row)
                }
                dialog = AlertDialog.Builder(requireContext(), com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
                    .setTitle("回收站")
                    .setView(android.widget.ScrollView(requireContext()).apply { addView(content) })
                    .setNegativeButton("关闭", null)
                    .create()
                dialog.show()
                return@launch
            }
            AlertDialog.Builder(requireContext(), com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
                .setTitle("回收站")
                .setView(content)
                .setNegativeButton("关闭", null)
                .show()
        }
    }

    private fun requestCancel() {
        if (!scanning) return
        cancelRequested = true
        binding.btnScan.isEnabled = false
        binding.statusPill.text = "取消中"
        binding.progressText.text = "正在取消..."
    }

    private fun startScan() {
        if (scanning) return
        scanning = true
        cancelRequested = false
        binding.statusPill.text = "扫描中"
        binding.progressPanel.visibility = View.VISIBLE
        binding.progress.visibility = View.VISIBLE
        binding.progressText.visibility = View.VISIBLE
        binding.progressText.text = "正在连接 NAS..."
        binding.btnScan.text = "取消扫描"
        binding.btnEnter.visibility = View.GONE
        binding.btnNewVideos.visibility = View.GONE
        binding.btnSizeRange.visibility = View.GONE
        binding.btnTags.visibility = View.GONE

        viewLifecycleOwner.lifecycleScope.launch {
            val settings: NasSettings = store.settings.first()
            val previousCount = repo.indexedCount()
            val lastSeenNew = store.lastSeenNew.first()
            val scanStartedAt = System.currentTimeMillis()
            try {
                val result = repo.rescan(
                    settings = settings,
                    onProgress = { videos, folders ->
                        viewLifecycleOwner.lifecycleScope.launch(Dispatchers.Main) {
                            binding.progressText.text = "已扫描 $folders 个文件夹，找到 $videos 个视频"
                        }
                    },
                    shouldStop = { cancelRequested },
                )
                val scanFinishedAt = System.currentTimeMillis()
                binding.progressText.text = if (cancelRequested) {
                    "已取消，索引保持不变，共 ${result.total} 个视频"
                } else {
                    store.markNewAsSeen(
                        newVideoBaselineAfterSuccessfulScan(
                            previousCount = previousCount,
                            previousLastSeenNew = lastSeenNew,
                            scanStartedAt = scanStartedAt,
                            scanFinishedAt = scanFinishedAt,
                            result = result,
                        )
                    )
                    lastScanResult = result
                    lastScanFinishedAt = scanFinishedAt
                    "扫描完成，共 ${result.total} 个视频，新增 ${result.added}，移除 ${result.removed}"
                }
            } catch (e: Exception) {
                binding.progressText.text = "扫描失败：${e.message}"
            } finally {
                scanning = false
                cancelRequested = false
                binding.progressPanel.visibility = View.GONE
                binding.progress.visibility = View.GONE
                binding.btnScan.isEnabled = true
                refreshIndexInfo()
            }
        }
    }

    private fun showSizeRangePicker() {
        val presets = VideoSizeRangePreset.entries.toTypedArray()
        val customLabel = "自定义范围..."
        val labels = presets.map { it.label } + customLabel
        AlertDialog.Builder(requireContext(), com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
            .setTitle("按文件大小刷")
            .setItems(labels.toTypedArray()) { _, which ->
                if (which < presets.size) {
                    openSizeRange(presets[which].range)
                } else {
                    showCustomSizeRangeDialog()
                }
            }
            .show()
    }

    private fun showCustomSizeRangeDialog() {
        val context = requireContext()
        val minInput = EditText(context).apply {
            hint = "最小 MB，可留空"
            inputType = InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
        }
        val maxInput = EditText(context).apply {
            hint = "最大 MB，可留空表示以上"
            inputType = InputType.TYPE_CLASS_NUMBER
            setSingleLine(true)
        }
        val content = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            val padding = (20 * resources.displayMetrics.density).toInt()
            setPadding(padding, padding / 2, padding, 0)
            addView(minInput)
            addView(maxInput)
        }
        val dialog = AlertDialog.Builder(context, com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
            .setTitle("自定义大小范围")
            .setView(content)
            .setNegativeButton("取消", null)
            .setPositiveButton("开始刷", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val range = parseCustomVideoSizeRangeMb(
                    minInput.text?.toString().orEmpty(),
                    maxInput.text?.toString().orEmpty(),
                )
                if (range == null) {
                    Toast.makeText(context, "请输入正确的大小范围", Toast.LENGTH_SHORT).show()
                } else {
                    dialog.dismiss()
                    openSizeRange(range)
                }
            }
        }
        dialog.show()
    }

    private fun openSizeRange(range: VideoSizeRange) {
        startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
            putExtra(FeedActivity.EXTRA_MODE, FeedMode.SIZE_RANGE.name)
            putExtra(FeedActivity.EXTRA_SIZE_MIN_BYTES, range.minBytes)
            putExtra(FeedActivity.EXTRA_SIZE_MAX_BYTES, range.maxBytesExclusive ?: -1L)
        })
    }

    private fun showTagFilterPicker() {
        viewLifecycleOwner.lifecycleScope.launch {
            val settings = store.settings.first()
            if (!settings.isTagApiConfigured) {
                Toast.makeText(requireContext(), "请先在设置中连接 NAS 标签服务", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val input = EditText(requireContext()).apply {
                hint = "输入标签，用逗号分隔"
                setSingleLine(false)
                inputType = InputType.TYPE_CLASS_TEXT
            }
            val suggestions = LinearLayout(requireContext()).apply { orientation = LinearLayout.VERTICAL }
            val suggestionScroll = android.widget.ScrollView(requireContext()).apply {
                isFillViewport = false
                addView(suggestions)
            }
            val content = LinearLayout(requireContext()).apply {
                orientation = LinearLayout.VERTICAL
                val padding = (20 * resources.displayMetrics.density).toInt()
                setPadding(padding, 0, padding, 0)
                addView(input)
                addView(suggestionScroll, LinearLayout.LayoutParams(
                    LinearLayout.LayoutParams.MATCH_PARENT,
                    (320 * resources.displayMetrics.density).toInt(),
                ))
            }
            val dialog = AlertDialog.Builder(requireContext(), com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog)
                .setTitle("按标签筛选")
                .setView(content)
                .setNegativeButton("取消", null)
                .setPositiveButton("开始播放") { _, _ -> openTaggedFeed(settings, parseManualTags(input.text.toString())) }
                .show()
            suggestions.addView(android.widget.TextView(requireContext()).apply {
                text = "历史标签"
                setPadding(0, (12 * resources.displayMetrics.density).toInt(), 0, 0)
            })
            val suggested = tags.suggestionsFor(settings, "") ?: emptyList()
            if (!isAdded || !dialog.isShowing) return@launch
            if (suggested.isEmpty()) {
                suggestions.addView(android.widget.TextView(requireContext()).apply {
                    text = "暂无历史标签"
                    alpha = 0.7f
                    setPadding(0, (8 * resources.displayMetrics.density).toInt(), 0, 0)
                })
                return@launch
            }
            val grid = android.widget.GridLayout(requireContext()).apply {
                columnCount = 3
                useDefaultMargins = false
            }
            suggestions.addView(grid)
            suggested.forEach { tag ->
                val option = android.widget.TextView(requireContext()).apply {
                    text = "+ $tag"
                    textSize = 16f
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    gravity = android.view.Gravity.CENTER_VERTICAL
                    val vertical = (4 * resources.displayMetrics.density).toInt()
                    setPadding(0, vertical, (8 * resources.displayMetrics.density).toInt(), vertical)
                    setOnClickListener {
                        input.setText(parseManualTags(input.text.toString()).plus(tag).joinToString(", "))
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

    private fun openTaggedFeed(settings: NasSettings, selectedTags: List<String>) {
        if (selectedTags.isEmpty()) {
            Toast.makeText(requireContext(), "请至少输入一个标签", Toast.LENGTH_SHORT).show()
            return
        }
        viewLifecycleOwner.lifecycleScope.launch {
            val remotePaths = tags.pathsWithTags(settings, selectedTags)
            if (remotePaths == null) {
                Toast.makeText(requireContext(), "标签服务暂时不可用", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val paths = repo.allPaths().filter { path ->
                mediaTagLookupPath(path, settings.normalizedRootPath) in remotePaths
            }
            if (paths.isEmpty()) {
                Toast.makeText(requireContext(), "没有匹配这些标签的视频", Toast.LENGTH_SHORT).show()
                return@launch
            }
            startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(paths.shuffled()))
            })
        }
    }

    private fun showTagManager() {
        viewLifecycleOwner.lifecycleScope.launch {
            val settings = store.settings.first()
            if (!settings.isTagApiConfigured) {
                Toast.makeText(requireContext(), "请先在设置中连接 NAS 标签服务", Toast.LENGTH_SHORT).show()
                return@launch
            }
            val tagSummaries = tags.tagSummaries(settings).orEmpty()
            if (tagSummaries.isEmpty()) {
                Toast.makeText(requireContext(), "暂无可管理的标签", Toast.LENGTH_SHORT).show()
                return@launch
            }
            showTagManagerDialog(settings, tagSummaries)
            return@launch
            /* Legacy grid manager retained temporarily for encoding-safe migration.
            val grid = android.widget.GridLayout(requireContext()).apply {
                columnCount = 3
                useDefaultMargins = false
            }
            val scroll = android.widget.ScrollView(requireContext()).apply {
                addView(grid)
            }
            val dialog = AlertDialog.Builder(
                requireContext(),
                com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog,
            )
                .setTitle("管理标签")
                .setView(scroll)
                .setNegativeButton("关闭", null)
                .show()
            tagNames.forEach { tag ->
                val option = android.widget.TextView(requireContext()).apply {
                    text = "#$tag"
                    textSize = 16f
                    maxLines = 1
                    ellipsize = android.text.TextUtils.TruncateAt.END
                    gravity = android.view.Gravity.CENTER_VERTICAL
                    val vertical = (8 * resources.displayMetrics.density).toInt()
                    setPadding(0, vertical, (8 * resources.displayMetrics.density).toInt(), vertical)
                    setOnClickListener {
                        AlertDialog.Builder(requireContext())
                            .setTitle("删除标签")
                            .setMessage("删除 #$tag？")
                            .setNegativeButton("取消", null)
                            .setPositiveButton("删除") { _, _ ->
                                viewLifecycleOwner.lifecycleScope.launch {
                                    val deleted = tags.deleteTag(settings, tag)
                                    if (deleted == true) {
                                        dialog.dismiss()
                                        Toast.makeText(requireContext(), "标签已删除", Toast.LENGTH_SHORT).show()
                                        showTagManager()
                                    } else {
                                        Toast.makeText(requireContext(), "标签删除失败", Toast.LENGTH_SHORT).show()
                                    }
                                }
                            }
                            .show()
                    }
                }
                grid.addView(option, android.widget.GridLayout.LayoutParams(
                    android.widget.GridLayout.spec(android.widget.GridLayout.UNDEFINED, 1f),
                    android.widget.GridLayout.spec(android.widget.GridLayout.UNDEFINED, 1f),
                ).apply {
                    width = 0
                    height = (48 * resources.displayMetrics.density).toInt()
                })
            }
            */
        }
    }

    private fun showTagManagerDialog(settings: NasSettings, tagSummaries: List<NasTagSummary>) {
        val content = DialogTagManagerBinding.inflate(layoutInflater)
        var allTags = tagSummaries.toList()
        lateinit var adapter: TagManagerAdapter
        adapter = TagManagerAdapter(
            onRename = { tag ->
                showRenameTagDialog(settings, tag) {
                    viewLifecycleOwner.lifecycleScope.launch {
                        val refreshed = tags.tagSummaries(settings)
                        if (refreshed != null) {
                            allTags = refreshed
                            renderManagedTags(
                                content,
                                adapter,
                                allTags,
                                content.tagSearch.text?.toString().orEmpty(),
                            )
                        }
                    }
                }
            },
            onDelete = { tag ->
            AlertDialog.Builder(requireContext())
                .setTitle("删除标签")
                .setMessage("删除 #$tag？")
                .setNegativeButton("取消", null)
                .setPositiveButton("删除") { _, _ ->
                    viewLifecycleOwner.lifecycleScope.launch {
                        val deleted = tags.deleteTag(settings, tag)
                        if (deleted == true) {
                            allTags = allTags.filterNot { it.name == tag }
                            renderManagedTags(
                                content,
                                adapter,
                                allTags,
                                content.tagSearch.text?.toString().orEmpty(),
                            )
                            Toast.makeText(requireContext(), "标签已删除", Toast.LENGTH_SHORT).show()
                        } else {
                            Toast.makeText(requireContext(), "标签删除失败", Toast.LENGTH_SHORT).show()
                        }
                    }
                }
                .show()
            },
        )
        val dialog = AlertDialog.Builder(
            requireContext(),
            com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog,
        )
            .setTitle("管理标签")
            .setView(content.root)
            .setNegativeButton("完成", null)
            .show()

        val density = resources.displayMetrics.density
        dialog.window?.setLayout(
            minOf(
                resources.displayMetrics.widthPixels - (32 * density).toInt(),
                (560 * density).toInt(),
            ),
            ViewGroup.LayoutParams.WRAP_CONTENT,
        )
        content.tagList.layoutManager = LinearLayoutManager(requireContext())
        content.tagList.adapter = adapter
        renderManagedTags(content, adapter, allTags, "")
        content.tagSearch.addTextChangedListener { query ->
            renderManagedTags(content, adapter, allTags, query?.toString().orEmpty())
        }
    }

    private fun showRenameTagDialog(
        settings: NasSettings,
        sourceTag: String,
        onUpdated: () -> Unit,
    ) {
        val input = EditText(requireContext()).apply {
            setText(sourceTag)
            setSelection(text.length)
            hint = "新标签名称"
            inputType = InputType.TYPE_CLASS_TEXT
            setSingleLine(true)
        }
        val dialog = AlertDialog.Builder(
            requireContext(),
            com.google.android.material.R.style.ThemeOverlay_Material3_MaterialAlertDialog,
        )
            .setTitle("重命名或合并标签")
            .setView(input)
            .setNegativeButton("取消", null)
            .setPositiveButton("继续", null)
            .create()
        dialog.setOnShowListener {
            dialog.getButton(AlertDialog.BUTTON_POSITIVE).setOnClickListener {
                val targetTag = input.text?.toString()?.trim().orEmpty()
                if (targetTag.isBlank()) {
                    input.error = "请输入标签名称"
                    return@setOnClickListener
                }
                if (targetTag == sourceTag) {
                    dialog.dismiss()
                    return@setOnClickListener
                }
                AlertDialog.Builder(requireContext())
                    .setTitle("确认更新标签")
                    .setMessage("#$sourceTag 将更新为 #$targetTag。若目标已存在，两个标签会合并。")
                    .setNegativeButton("取消", null)
                    .setPositiveButton("确认") { _, _ ->
                        viewLifecycleOwner.lifecycleScope.launch {
                            val renamed = tags.renameTag(settings, sourceTag, targetTag)
                            if (renamed == true) {
                                Toast.makeText(requireContext(), "标签已更新", Toast.LENGTH_SHORT).show()
                                onUpdated()
                            } else {
                                Toast.makeText(requireContext(), "标签更新失败", Toast.LENGTH_SHORT).show()
                            }
                        }
                    }
                    .show()
                dialog.dismiss()
            }
        }
        dialog.show()
    }

    private fun renderManagedTags(
        content: DialogTagManagerBinding,
        adapter: TagManagerAdapter,
        allTags: List<NasTagSummary>,
        query: String,
    ) {
        val byName = allTags.associateBy { it.name }
        val visibleTags = filterManageableTags(allTags.map { it.name }, query).mapNotNull(byName::get)
        adapter.submit(visibleTags)
        content.tagSummary.text = "共 ${allTags.size} 个标签，当前显示 ${visibleTags.size} 个"
        content.tagEmpty.visibility = if (visibleTags.isEmpty()) View.VISIBLE else View.GONE
    }

    private class TagManagerAdapter(
        private val onRename: (String) -> Unit,
        private val onDelete: (String) -> Unit,
    ) : RecyclerView.Adapter<TagManagerAdapter.TagViewHolder>() {
        private var tags: List<NasTagSummary> = emptyList()

        fun submit(next: List<NasTagSummary>) {
            tags = next
            notifyDataSetChanged()
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): TagViewHolder {
            return TagViewHolder(
                ItemManageTagBinding.inflate(LayoutInflater.from(parent.context), parent, false),
            )
        }

        override fun onBindViewHolder(holder: TagViewHolder, position: Int) {
            val tag = tags[position]
            holder.binding.tagName.text = "#${tag.name}"
            holder.binding.tagUsage.text = "已用于 ${tag.usageCount} 个视频"
            holder.binding.root.setOnClickListener { onRename(tag.name) }
            holder.binding.editTag.setOnClickListener { onRename(tag.name) }
            holder.binding.deleteTag.setOnClickListener { onDelete(tag.name) }
        }

        override fun getItemCount(): Int = tags.size

        class TagViewHolder(val binding: ItemManageTagBinding) :
            RecyclerView.ViewHolder(binding.root)
    }

    private fun openRandomByTagState(tagged: Boolean) {
        viewLifecycleOwner.lifecycleScope.launch {
            val settings = store.settings.first()
            if (!settings.isTagApiConfigured) {
                Toast.makeText(requireContext(), "请先在设置中连接 NAS 标签服务", Toast.LENGTH_SHORT).show()
                return@launch
            }
            startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                putExtra(FeedActivity.EXTRA_MODE, tagFeedMode(tagged).name)
            })
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
