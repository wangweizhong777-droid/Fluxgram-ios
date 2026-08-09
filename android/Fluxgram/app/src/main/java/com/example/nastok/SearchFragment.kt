package com.example.nastok

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import android.view.inputmethod.EditorInfo
import androidx.core.widget.addTextChangedListener
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.GridLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.NasSettings
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.databinding.ActivitySearchBinding
import com.example.nastok.databinding.ItemFavoriteBinding
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class SearchFragment : Fragment() {

    private var _binding: ActivitySearchBinding? = null
    private val binding get() = _binding!!
    private val repo by lazy { VideoRepository(requireContext()) }
    private val thumbs by lazy { ThumbnailStore(requireContext()) }
    private val store by lazy { SettingsStore(requireContext()) }
    private var settings: NasSettings? = null
    private var results: List<String> = emptyList()
    private var searchJob: Job? = null

    override fun onCreateView(inflater: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        _binding = ActivitySearchBinding.inflate(inflater, c, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        binding.searchGrid.layoutManager = GridLayoutManager(requireContext(), 2)
        binding.searchGrid.adapter = ResultAdapter()
        viewLifecycleOwner.lifecycleScope.launch { settings = store.settings.first() }

        binding.searchInput.addTextChangedListener(
            onTextChanged = { text, _, _, _ -> scheduleSearch(text?.toString().orEmpty()) }
        )
        binding.searchInput.setOnEditorActionListener { _, actionId, _ ->
            if (actionId == EditorInfo.IME_ACTION_SEARCH) {
                runSearch(binding.searchInput.text?.toString().orEmpty()); true
            } else false
        }
    }

    private fun scheduleSearch(q: String) {
        searchJob?.cancel()
        searchJob = viewLifecycleOwner.lifecycleScope.launch {
            delay(250)
            runSearch(q)
        }
    }

    private fun runSearch(q: String) {
        viewLifecycleOwner.lifecycleScope.launch {
            val query = q.trim()
            if (query.isEmpty()) {
                results = emptyList()
                binding.searchStatus.text = "输入关键词开始搜索"
                binding.searchEmpty.visibility = View.GONE
                binding.searchGrid.adapter?.notifyDataSetChanged()
                return@launch
            }
            results = repo.search(query)
            binding.searchStatus.text =
                if (results.isEmpty()) "没有找到「$query」"
                else "找到 ${results.size} 个结果"
            binding.searchEmpty.visibility = if (results.isEmpty()) View.VISIBLE else View.GONE
            binding.searchGrid.adapter?.notifyDataSetChanged()
        }
    }

    private inner class ResultAdapter : RecyclerView.Adapter<ResultAdapter.VH>() {
        inner class VH(val b: ItemFavoriteBinding) : RecyclerView.ViewHolder(b.root) {
            var thumbJob: Job? = null
        }

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val b = ItemFavoriteBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return VH(b)
        }
        override fun getItemCount() = results.size
        override fun onBindViewHolder(holder: VH, position: Int) {
            val path = results[position]
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
                    val s = settings ?: return@launch
                    val bmp = thumbs.getOrGenerate(s, path)
                    if (bmp != null && holder.b.thumb.tag == path) {
                        holder.b.thumb.setThumbnailBitmap(bmp)
                        holder.b.placeholder.visibility = View.GONE
                    }
                }
            }
            holder.b.root.setOnClickListener {
                startActivity(Intent(requireContext(), FeedActivity::class.java).apply {
                    putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                    putStringArrayListExtra(FeedActivity.EXTRA_PATHS, ArrayList(results))
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
}
