package com.example.nastok

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.widget.Toast
import androidx.appcompat.app.AppCompatActivity
import androidx.core.widget.addTextChangedListener
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.MediaTagStore
import com.example.nastok.data.NasSettings
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.data.mediaTagLookupPath
import com.example.nastok.databinding.ActivityFolderProfileBinding
import com.example.nastok.databinding.ItemProfileVideoBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

/** A TikTok-style tag page backed by NAS-owned tags and the local video index. */
class TagProfileActivity : AppCompatActivity() {

    private lateinit var binding: ActivityFolderProfileBinding
    private val repo by lazy { VideoRepository(applicationContext) }
    private val thumbs by lazy { ThumbnailStore(applicationContext) }
    private val store by lazy { SettingsStore(applicationContext) }
    private val tags = MediaTagStore.shared
    private lateinit var settings: NasSettings
    private var tag = ""
    private var allPaths: List<String> = emptyList()
    private var paths: List<String> = emptyList()
    private var gridAdapter: GridAdapter? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        binding = ActivityFolderProfileBinding.inflate(layoutInflater)
        setContentView(binding.root)

        tag = intent.getStringExtra(EXTRA_TAG).orEmpty().trim()
        if (tag.isEmpty()) {
            finish()
            return
        }

        binding.avatar.setImageResource(R.drawable.ic_tag)
        binding.avatar.setPadding(16, 16, 16, 16)
        binding.folderName.text = "#$tag"
        binding.folderSearchInput.hint = "在 #$tag 中搜索"
        binding.videoGrid.layoutManager = GridLayoutManager(this, 3)
        gridAdapter = GridAdapter()
        binding.videoGrid.adapter = gridAdapter

        binding.btnShuffle.setOnClickListener { openFeed(paths.shuffled(), 0) }
        binding.folderSearchInput.addTextChangedListener { applySearch(it?.toString().orEmpty()) }

        lifecycleScope.launch {
            settings = store.settings.first()
            if (!settings.isTagApiConfigured) {
                Toast.makeText(this@TagProfileActivity, "请先在设置中连接 NAS 标签服务", Toast.LENGTH_SHORT).show()
                finish()
                return@launch
            }
            val taggedPaths = tags.pathsWithTags(settings, listOf(tag))
            if (taggedPaths == null) {
                Toast.makeText(this@TagProfileActivity, "标签服务暂时不可用", Toast.LENGTH_SHORT).show()
                finish()
                return@launch
            }
            allPaths = repo.allPaths().filter { path ->
                mediaTagLookupPath(path, settings.normalizedRootPath) in taggedPaths
            }
            applySearch(binding.folderSearchInput.text?.toString().orEmpty())
        }
    }

    private fun applySearch(query: String) {
        val keyword = query.trim()
        paths = if (keyword.isEmpty()) allPaths else allPaths.filter {
            it.substringAfterLast('/').contains(keyword, ignoreCase = true)
        }
        binding.statsRow.text = "${allPaths.size} 个视频"
        binding.folderSearchStatus.text = if (keyword.isEmpty()) {
            "标签 #$tag"
        } else {
            "找到 ${paths.size} / ${allPaths.size} 个视频"
        }
        binding.btnShuffle.isEnabled = paths.isNotEmpty()
        gridAdapter?.notifyDataSetChanged()
    }

    private fun openFeed(videoPaths: List<String>, startIndex: Int) {
        if (videoPaths.isEmpty()) return
        startActivity(Intent(this, FeedActivity::class.java).apply {
            putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
            putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(videoPaths))
            putExtra(FeedActivity.EXTRA_START_INDEX, startIndex)
        })
    }

    private inner class GridAdapter : RecyclerView.Adapter<GridAdapter.VH>() {
        inner class VH(val binding: ItemProfileVideoBinding) : RecyclerView.ViewHolder(binding.root) {
            var thumbJob: Job? = null
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH = VH(
            ItemProfileVideoBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        )

        override fun getItemCount(): Int = paths.size

        override fun onBindViewHolder(holder: VH, position: Int) {
            val path = paths[position]
            holder.binding.thumb.tag = path
            holder.thumbJob?.cancel()
            thumbs.load(path)?.let { bitmap ->
                holder.binding.thumb.setThumbnailBitmap(bitmap)
                holder.binding.placeholder.visibility = View.GONE
            } ?: run {
                holder.binding.thumb.setImageDrawable(null)
                holder.binding.placeholder.visibility = View.VISIBLE
                holder.thumbJob = lifecycleScope.launch {
                    val bitmap = thumbs.getOrGenerate(settings, path)
                    if (bitmap != null && holder.binding.thumb.tag == path) {
                        holder.binding.thumb.setThumbnailBitmap(bitmap)
                        holder.binding.placeholder.visibility = View.GONE
                    }
                }
            }
            holder.binding.root.setOnClickListener {
                val start = holder.bindingAdapterPosition
                if (start != RecyclerView.NO_POSITION) openFeed(paths, start)
            }
        }

        override fun onViewRecycled(holder: VH) {
            holder.thumbJob?.cancel()
            holder.thumbJob = null
            holder.binding.thumb.setImageDrawable(null)
            super.onViewRecycled(holder)
        }
    }

    companion object {
        const val EXTRA_TAG = "tag"
    }
}
