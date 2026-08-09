package com.example.nastok

import android.os.Bundle
import android.content.Intent
import androidx.appcompat.app.AppCompatActivity
import androidx.core.splashscreen.SplashScreen.Companion.installSplashScreen
import androidx.fragment.app.Fragment
import androidx.lifecycle.lifecycleScope
import android.widget.Toast
import com.example.nastok.data.SettingsStore
import com.example.nastok.data.VideoRepository
import com.example.nastok.databinding.ActivityHomeBinding
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch

class HomeActivity : AppCompatActivity() {

    private lateinit var binding: ActivityHomeBinding
    private val fragments = LinkedHashMap<Int, Fragment>()

    override fun onCreate(savedInstanceState: Bundle?) {
        installSplashScreen()
        super.onCreate(savedInstanceState)
        binding = ActivityHomeBinding.inflate(layoutInflater)
        setContentView(binding.root)

        binding.bottomNav.setOnItemSelectedListener { item ->
            showFragment(item.itemId)
            true
        }
        // Default to home tab
        if (savedInstanceState == null) {
            selectTab(intent.getIntExtra(EXTRA_TAB, R.id.nav_home))
            handleExternalPlaybackIntent(intent)
        }
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        selectTab(intent.getIntExtra(EXTRA_TAB, R.id.nav_home))
        handleExternalPlaybackIntent(intent)
    }

    private fun selectTab(id: Int) {
        if (binding.bottomNav.selectedItemId == id) showFragment(id)
        else binding.bottomNav.selectedItemId = id
    }

    private fun showFragment(id: Int) {
        val tag = "frag_$id"
        val tx = supportFragmentManager.beginTransaction()
        // Hide all currently added fragments
        for (f in supportFragmentManager.fragments) tx.hide(f)
        // Show or create the target fragment
        val existing = supportFragmentManager.findFragmentByTag(tag)
        if (existing != null) {
            tx.show(existing)
        } else {
            val frag = createFragment(id)
            tx.add(R.id.fragmentContainer, frag, tag)
            fragments[id] = frag
        }
        tx.commitAllowingStateLoss()
    }

    private fun createFragment(id: Int): Fragment = when (id) {
        R.id.nav_home -> HomeFragment()
        R.id.nav_favorites -> FavoritesFragment()
        R.id.nav_folders -> FoldersFragment()
        R.id.nav_search -> SearchFragment()
        R.id.nav_settings -> SettingsFragment()
        else -> HomeFragment()
    }

    private fun handleExternalPlaybackIntent(intent: Intent) {
        val uri = intent.data ?: return
        if (intent.action != Intent.ACTION_VIEW || uri.scheme != NASTOK_SCHEME || uri.host != NASTOK_PLAY_HOST) return
        val relativePath = uri.getQueryParameter("path").orEmpty()
        lifecycleScope.launch {
            val settings = SettingsStore(applicationContext).settings.first()
            val playbackPath = resolveNastokPlaybackPath(settings.normalizedRootPath, relativePath) ?: return@launch
            if (VideoRepository(applicationContext).video(playbackPath) == null) {
                Toast.makeText(this@HomeActivity, "请先扫描 NAS 视频库，再打开这个文件", Toast.LENGTH_SHORT).show()
                return@launch
            }
            startActivity(Intent(this@HomeActivity, FeedActivity::class.java).apply {
                putExtra(FeedActivity.EXTRA_MODE, FeedMode.EXPLICIT.name)
                putStringArrayListExtra(FeedActivity.EXTRA_PATHS, arrayListOf(playbackPath))
            })
        }
    }

    companion object {
        const val EXTRA_TAB = "home_tab"
        const val NASTOK_SCHEME = "nastok"
        const val NASTOK_PLAY_HOST = "play"
    }
}
