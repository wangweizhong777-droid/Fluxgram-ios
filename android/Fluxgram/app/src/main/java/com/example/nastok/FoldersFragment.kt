package com.example.nastok

import android.content.Intent
import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.core.widget.addTextChangedListener
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import androidx.recyclerview.widget.LinearLayoutManager
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.VideoRepository
import com.example.nastok.data.db.FolderCount
import com.example.nastok.databinding.ActivityFolderBinding
import com.example.nastok.databinding.ItemFolderBinding
import kotlinx.coroutines.launch

class FoldersFragment : Fragment() {

    private var _binding: ActivityFolderBinding? = null
    private val binding get() = _binding!!
    private val repo by lazy { VideoRepository(requireContext()) }
    private var allFolders: List<FolderCount> = emptyList()
    private var visibleFolders: List<FolderCount> = emptyList()
    private var folderAdapter: FolderAdapter? = null
    private var sortMode = FolderSortMode.VIDEO_COUNT

    override fun onCreateView(inflater: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        _binding = ActivityFolderBinding.inflate(inflater, c, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        folderAdapter = FolderAdapter()
        binding.folderList.layoutManager = LinearLayoutManager(requireContext())
        binding.folderList.adapter = folderAdapter
        binding.btnPlaySelected.visibility = View.GONE
        binding.folderSearchInput.addTextChangedListener {
            applySearch(it?.toString().orEmpty())
        }
        binding.folderSortGroup.setOnCheckedChangeListener { _, checkedId ->
            sortMode = when (checkedId) {
                R.id.sortByName -> FolderSortMode.NAME
                else -> FolderSortMode.VIDEO_COUNT
            }
            applySearch(binding.folderSearchInput.text?.toString().orEmpty())
        }
    }

    override fun onResume() {
        super.onResume()
        loadFolders()
    }

    private fun loadFolders() {
        viewLifecycleOwner.lifecycleScope.launch {
            allFolders = repo.folderCounts()
            applySearch(binding.folderSearchInput.text?.toString().orEmpty())
        }
    }

    private fun applySearch(query: String) {
        val filtered = filterFolderCountsByName(allFolders, query)
        visibleFolders = sortFolderCounts(filtered, sortMode)
        binding.folderSearchStatus.text = if (query.isBlank()) {
            "共 ${allFolders.size} 个文件夹"
        } else {
            "找到 ${visibleFolders.size} / ${allFolders.size} 个文件夹"
        }
        when {
            allFolders.isEmpty() -> {
                binding.folderEmpty.text = "还没有文件夹。先扫描 NAS 视频库。"
                binding.folderEmpty.visibility = View.VISIBLE
            }
            query.isNotBlank() && visibleFolders.isEmpty() -> {
                binding.folderEmpty.text = "没有找到匹配的文件夹"
                binding.folderEmpty.visibility = View.VISIBLE
            }
            else -> {
                binding.folderEmpty.visibility = View.GONE
            }
        }
        folderAdapter?.notifyDataSetChanged()
    }

    private inner class FolderAdapter : RecyclerView.Adapter<FolderAdapter.VH>() {
        inner class VH(val b: ItemFolderBinding) : RecyclerView.ViewHolder(b.root)

        override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
            val b = ItemFolderBinding.inflate(LayoutInflater.from(parent.context), parent, false)
            return VH(b)
        }

        override fun getItemCount() = visibleFolders.size

        override fun onBindViewHolder(holder: VH, position: Int) {
            val item = visibleFolders[position]
            holder.b.folderCount.text = "${item.cnt}"
            holder.b.folderName.text = folderDisplayName(item.folder)
            holder.b.check.visibility = View.GONE
            holder.b.root.setOnClickListener {
                startActivity(Intent(requireContext(), FolderProfileActivity::class.java).apply {
                    putExtra(FolderProfileActivity.EXTRA_FOLDER_NAME, item.folder)
                })
            }
        }
    }

    override fun onDestroyView() {
        super.onDestroyView()
        _binding = null
    }
}
