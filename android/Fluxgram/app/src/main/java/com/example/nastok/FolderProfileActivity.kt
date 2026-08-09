package com.example.nastok

import android.content.Intent
import android.graphics.Bitmap
import android.graphics.RenderEffect
import android.graphics.Shader
import android.os.Build
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.appcompat.app.AppCompatActivity
import androidx.core.widget.addTextChangedListener
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.AvatarStore
import com.example.nastok.data.NasSettings
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.databinding.ActivityFolderProfileBinding
import com.example.nastok.databinding.ItemProfileVideoBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class FolderProfileActivity : AppCompatActivity() {

    private lateinit var binding: ActivityFolderProfileBinding
    private val repo by lazy { VideoRepository(applicationContext) }
    private val thumbs by lazy { ThumbnailStore(applicationContext) }
    private val avatars by lazy { AvatarStore(applicationContext) }
    private val store by lazy { SettingsStore(applicationContext) }
    private lateinit var settings: NasSettings
    private var folderName = ""
    private var allPaths: List<String> = emptyList()
    private var paths: List<String> = emptyList()
    private var totalSize = 0L
    private var fallbackPreview: Bitmap? = null
    private var gridAdapter: GridAdapter? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFolderProfileBinding.inflate(layoutInflater)
        setContentView(binding.root)

        folderName = normalizeFolderPath(intent.getStringExtra(EXTRA_FOLDER_NAME) ?: "")
        binding.folderName.text = folderDisplayName(folderName)
        binding.videoGrid.layoutManager = GridLayoutManager(this, 3)
        gridAdapter = GridAdapter()
        binding.videoGrid.adapter = gridAdapter

        binding.btnShuffle.setOnClickListener {
            if (paths.isEmpty()) return@setOnClickListener
            startActivity(Intent(this, FeedActivity::class.java).apply {
                putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(paths.shuffled()))
                putExtra(FeedActivity.EXTRA_START_INDEX, 0)
            })
        }

        binding.folderSearchInput.addTextChangedListener {
            applySearch(it?.toString().orEmpty())
        }

        lifecycleScope.launch {
            settings = store.settings.first()
            allPaths = repo.pathsInFolders(listOf(normalizeFolderPath(folderName)))
            totalSize = repo.totalSizeInFolders(listOf(normalizeFolderPath(folderName)))
            applySearch(binding.folderSearchInput.text?.toString().orEmpty())
            loadHeaderImages()
            prewarmThumbnails()
        }
    }

    private fun applySearch(query: String) {
        paths = filterFolderVideoPaths(allPaths, query)
        updateStats(query)
        gridAdapter?.notifyDataSetChanged()
        binding.btnShuffle.isEnabled = paths.isNotEmpty()
    }

    private fun updateStats(query: String) {
        binding.statsRow.text = "${allPaths.size} 个视频  ·  ${formatSize(totalSize)}"
        binding.folderSearchStatus.text = if (query.isBlank()) {
            "当前文件夹 ${allPaths.size} 个视频"
        } else {
            "找到 ${paths.size} / ${allPaths.size} 个视频"
        }
    }

    private fun loadHeaderImages() {
        lifecycleScope.launch {
            val samplePath = allPaths.firstOrNull() ?: return@launch
            val img = repo.avatarForVideo(samplePath)
            if (img != null) {
                val bmp = avatars.get(settings, img)
                if (bmp != null) {
                    fallbackPreview = bmp
                    binding.avatar.setImageBitmap(bmp)
                    setBlurredBackground(bmp)
                    binding.videoGrid.adapter?.notifyItemRangeChanged(0, paths.size)
                }
            } else {
                // No avatar image: use the first video's thumbnail as background.
                val thumb = thumbs.getOrGenerate(settings, samplePath)
                if (thumb != null) {
                    fallbackPreview = thumb
                    binding.avatar.setImageBitmap(toCircleAvatar(thumb))
                    setBlurredBackground(thumb)
                    binding.videoGrid.adapter?.notifyItemRangeChanged(0, paths.size)
                }
            }
        }
    }

    /** Let visible rows queue first, then warm the first screenful plus a short scroll ahead. */
    private fun prewarmThumbnails() {
        lifecycleScope.launch {
            delay(500)
            paths.take(PREWARM_COUNT).forEach { path ->
                launch { thumbs.getOrGenerate(settings, path) }
            }
        }
    }

    private fun setBlurredBackground(src: Bitmap) {
        binding.headerBg.setImageBitmap(src)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            binding.headerBg.setRenderEffect(
                RenderEffect.createBlurEffect(40f, 40f, Shader.TileMode.CLAMP)
            )
        }
    }

    private fun formatSize(bytes: Long): String = when {
        bytes < 1024 -> "$bytes B"
        bytes < 1024 * 1024 -> "%.1f KB".format(bytes / 1024.0)
        bytes < 1024L * 1024 * 1024 -> "%.1f MB".format(bytes / (1024.0 * 1024))
        else -> "%.2f GB".format(bytes / (1024.0 * 1024 * 1024))
    }

    private inner class GridAdapter : RecyclerView.Adapter<GridAdapter.VH>() {
        inner class VH(val b: ItemProfileVideoBinding) : RecyclerView.ViewHolder(b.root) {
            var thumbJob: Job? = null
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val b = ItemProfileVideoBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return VH(b)
        }

        override fun getItemCount() = paths.size

        override fun onBindViewHolder(holder: VH, position: Int) {
            val path = paths[position]
            holder.b.thumb.tag = path
            holder.thumbJob?.cancel()
            val cached = thumbs.load(path)
            if (cached != null) {
                holder.b.thumb.setThumbnailBitmap(cached)
                holder.b.placeholder.visibility = View.GONE
            } else {
                fallbackPreview?.let { holder.b.thumb.setThumbnailBitmap(it) }
                    ?: holder.b.thumb.setImageDrawable(null)
                holder.b.placeholder.visibility =
                    if (fallbackPreview == null) View.VISIBLE else View.GONE
                holder.thumbJob = lifecycleScope.launch {
                    val bmp = thumbs.getOrGenerate(settings, path)
                    if (bmp != null && holder.b.thumb.tag == path) {
                        holder.b.thumb.setThumbnailBitmap(bmp)
                        holder.b.placeholder.visibility = View.GONE
                    }
                }
            }
            holder.b.root.setOnClickListener {
                val start = holder.bindingAdapterPosition
                if (start == RecyclerView.NO_POSITION) return@setOnClickListener
                startActivity(Intent(this@FolderProfileActivity, FeedActivity::class.java).apply {
                    putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                    putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(paths))
                    putExtra(FeedActivity.EXTRA_START_INDEX, start)
                })
            }
        }

        override fun onViewRecycled(holder: VH) {
            holder.thumbJob?.cancel()
            holder.thumbJob = null
            holder.b.thumb.setImageDrawable(null)
            super.onViewRecycled(holder)
        }
    }

    companion object {
        const val EXTRA_FOLDER_NAME = "folder_name"
        private const val PREWARM_COUNT = 30
    }
}
