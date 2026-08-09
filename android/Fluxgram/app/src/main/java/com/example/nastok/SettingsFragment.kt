package com.example.nastok

import android.os.Bundle
import android.view.LayoutInflater
import android.view.View
import android.view.ViewGroup
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import com.example.nastok.data.AvatarStore
import com.example.nastok.data.NasSettings
import com.example.nastok.data.PlaybackCache
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.databinding.ActivitySettingsBinding
import com.example.nastok.net.WebDavClient
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class SettingsFragment : Fragment() {

    private var _binding: ActivitySettingsBinding? = null
    private val binding get() = _binding!!
    private val store by lazy { SettingsStore(requireContext()) }
    private val repo by lazy { VideoRepository(requireContext()) }
    private val thumbs by lazy { ThumbnailStore(requireContext()) }
    private val avatars by lazy { AvatarStore(requireContext()) }

    override fun onCreateView(inflater: LayoutInflater, c: ViewGroup?, s: Bundle?): View {
        _binding = ActivitySettingsBinding.inflate(inflater, c, false)
        return binding.root
    }

    override fun onViewCreated(view: View, savedInstanceState: Bundle?) {
        viewLifecycleOwner.lifecycleScope.launch {
            val s = store.settings.first()
            binding.inputUrl.setText(s.baseUrl)
            binding.inputRootPath.setText(s.rootPath)
            binding.inputUsername.setText(s.username)
            binding.inputPassword.setText(s.password)
            binding.inputTagApiUrl.setText(s.tagApiBaseUrl)
            binding.inputTagApiToken.setText(s.tagApiToken)
            binding.inputRemoteGatewayUrl.setText(s.remoteGatewayBaseUrl)
            binding.inputRemoteGatewayToken.setText(s.remoteGatewayToken)
        }
        binding.btnSave.setOnClickListener { saveSettings() }
        binding.btnTest.setOnClickListener { testConnection() }

        // About section
        try {
            val pi = requireContext().packageManager.getPackageInfo(requireContext().packageName, 0)
            binding.versionText.text = "v${pi.versionName}"
        } catch (_: Exception) {}
        refreshCacheInfo()
        binding.btnClearCache.setOnClickListener { clearCache() }
    }

    private fun refreshCacheInfo() {
        val appContext = requireContext().applicationContext
        viewLifecycleOwner.lifecycleScope.launch {
            val total = withContext(Dispatchers.IO) {
                thumbs.cacheSize() + avatars.cacheSize() +
                    PlaybackCache.cacheSize(appContext)
            }
            binding.cacheInfo.text = "缓存：${formatByteSize(total)}"
        }
    }

    private fun clearCache() {
        val appContext = requireContext().applicationContext
        viewLifecycleOwner.lifecycleScope.launch {
            withContext(Dispatchers.IO) {
                thumbs.clearAll()
                avatars.clearAll()
                PlaybackCache.clear(appContext)
            }
            refreshCacheInfo()
            binding.btnClearCache.text = "缓存已清除"
        }
    }

    private fun currentInput(): NasSettings = NasSettings(
        baseUrl = binding.inputUrl.text?.toString().orEmpty(),
        rootPath = binding.inputRootPath.text?.toString().orEmpty().ifBlank { "/" },
        username = binding.inputUsername.text?.toString().orEmpty(),
        password = binding.inputPassword.text?.toString().orEmpty(),
        tagApiBaseUrl = binding.inputTagApiUrl.text?.toString().orEmpty(),
        tagApiToken = binding.inputTagApiToken.text?.toString().orEmpty(),
        remoteGatewayBaseUrl = binding.inputRemoteGatewayUrl.text?.toString().orEmpty(),
        remoteGatewayToken = binding.inputRemoteGatewayToken.text?.toString().orEmpty(),
    )

    private fun saveSettings() {
        val s = currentInput()
        if (!s.isConfigured) {
            binding.testResult.text = "请至少填写 WebDAV 地址和根目录"
            return
        }
        viewLifecycleOwner.lifecycleScope.launch {
            store.save(s)
            binding.testResult.text = "已保存"
        }
    }

    private fun testConnection() {
        val s = currentInput()
        if (!s.isConfigured) {
            binding.testResult.text = "请至少填写 WebDAV 地址和根目录"
            return
        }
        binding.btnTest.isEnabled = false
        binding.testResult.text = "正在连接 ${s.normalizedBaseUrl}${s.normalizedRootPath} ..."
        viewLifecycleOwner.lifecycleScope.launch {
            val result = repo.testConnection(s)
            binding.testResult.text = when (result) {
                is WebDavClient.TestResult.Ok ->
                    "连接成功，根目录下有 ${result.itemCount} 个项目"
                WebDavClient.TestResult.Unreachable ->
                    "连不上服务器，检查地址、端口和局域网"
                WebDavClient.TestResult.AuthFailed ->
                    "用户名或密码错误"
                WebDavClient.TestResult.PathMissing ->
                    "服务器连上了，但根目录不存在，检查路径"
                is WebDavClient.TestResult.HttpError ->
                    "服务器返回错误 HTTP ${result.code}"
            }
            binding.btnTest.isEnabled = true
        }
    }

    override fun onDestroyView() { super.onDestroyView(); _binding = null }
}
