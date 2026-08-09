package com.example.nastok

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.NasSettings
import com.example.nastok.data.MediaProfileStore
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.data.mediaTagLookupPath
import com.example.nastok.databinding.ActivityFavoritesBinding
import com.example.nastok.databinding.ItemFavoriteBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class FavoritesFragment : Fragment() {

    private var _binding: ActivityFavoritesBinding? = null
    private val binding get() = _binding!!
    private val repo by lazy { VideoRepository(requireContext()) }
    private val thumbs by lazy { ThumbnailStore(requireContext()) }
    private val store by lazy { SettingsStore(requireContext()) }
    private val profiles by lazy { MediaProfileStore() }
    private lateinit var settings: NasSettings

    override fun onCreateView(inflater: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        _binding = ActivityFavoritesBinding.inflate(inflater, c, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        binding.favGrid.layoutManager = GridLayoutManager(requireContext(), 2)
    }

    override fun onResume() {
        super.onResume()
        loadFavorites()
    }

    private fun loadFavorites() {
        viewLifecycleOwner.lifecycleScope.launch {
            settings = store.settings.first()
            val localPaths = repo.favoritePaths()
            val remotePaths = profiles.favoritePaths(settings)
            val paths = if (remotePaths == null) {
                localPaths
            } else {
                (repo.allPaths().filter { path ->
                    mediaTagLookupPath(path, settings.normalizedRootPath) in remotePaths
                } + localPaths).distinct()
            }
            binding.favTitle.text = "我的收藏 (${paths.size})"
            if (paths.isEmpty()) {
                binding.favEmpty.visibility = View.VISIBLE
                binding.favGrid.adapter = null
                return@launch
            }
            binding.favEmpty.visibility = View.GONE
            binding.favGrid.adapter = FavAdapter(paths)
            prewarmThumbnails(paths)
        }
    }

    private fun prewarmThumbnails(paths: List<String>) {
        viewLifecycleOwner.lifecycleScope.launch {
            delay(500)
            paths.take(PREWARM_COUNT).forEach { path ->
                launch { thumbs.getOrGenerate(settings, path) }
            }
        }
    }

    private inner class FavAdapter(private val paths: List<String>) :
        RecyclerView.Adapter<FavAdapter.VH>() {
        inner class VH(val b: ItemFavoriteBinding) : RecyclerView.ViewHolder(b.root) {
            var thumbJob: Job? = null
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val b = ItemFavoriteBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return VH(b)
        }
        override fun getItemCount() = paths.size
        override fun onBindViewHolder(holder: VH, position: Int) {
            val path = paths[position]
            holder.b.name.text = path.substringAfterLast('/')
            holder.b.thumb.tag = path
            holder.thumbJob?.cancel()
            val cached = thumbs.load(path)
            if (cached != null) {
                holder.b.thumb.setThumbnailBitmap(cached)
                holder.b.placeholder.visibility = View.GONE
            } else {
                holder.b.thumb.setImageDrawable(null)
                holder.b.placeholder.visibility = View.VISIBLE
                holder.thumbJob = viewLifecycleOwner.lifecycleScope.launch {
                    val bmp = thumbs.getOrGenerate(settings, path)
                    if (bmp != null && holder.b.thumb.tag == path) {
                        holder.b.thumb.setThumbnailBitmap(bmp)
                        holder.b.placeholder.visibility = View.GONE
                    }
                }
            }
            holder.b.root.setOnClickListener {
                startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                    putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                    putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(paths))
                    putExtra(FeedActivity.EXTRA_START_INDEX, holder.bindingAdapterPosition)
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

    override fun onDestroyView() { super.onDestroyView(); _binding = null }

    companion object {
        private const val PREWARM_COUNT = 20
    }
}
