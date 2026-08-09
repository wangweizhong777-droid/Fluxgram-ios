package com.example.nastok

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Bitmap
import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.text.SpannableString
import android.text.Spanned
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.text.TextPaint
import android.view.GestureDetector
import android.view.LayoutInflater
import android.view.MotionEvent
import android.view.TextureView
import android.view.View
import android.view.ViewGroup
import android.widget.SeekBar
import androidx.media3.common.MediaItem
import androidx.media3.common.PlaybackParameters
import androidx.media3.common.Player
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.SeekParameters
import androidx.media3.exoplayer.source.ProgressiveMediaSource
import androidx.recyclerview.widget.RecyclerView
import com.example.nastok.data.NasSettings
import com.example.nastok.data.ThumbnailStore
import com.example.nastok.databinding.PageVideoBinding
import com.example.nastok.net.DavUrl
import com.example.nastok.net.NasDataSourceFactory
import com.example.nastok.net.PlaybackRouteStore
import java.util.concurrent.Executors

fun formatVideoTags(tags: List<String>): String = tags.joinToString("  ") { "#$it" }

fun tagAtIndex(tags: List<String>, index: Int): String? = tags.getOrNull(index)

/** One ExoPlayer per attached page, plus TikTok-style touch interactions. */
class FeedAdapter(
    context: Context,
    private val settings: NasSettings,
    private val host: InteractionHost,
    private val thumbs: ThumbnailStore,
    initialMuted: Boolean = true,
) : RecyclerView.Adapter<FeedAdapter.VH>() {

    /** Lets the ViewHolder read/write like & favorite state without doing DB work itself. */
    interface InteractionHost {
        /** Load current (liked, favorited) for [path]; result delivered on main thread. */
        fun loadInteraction(path: String, cb: (liked: Boolean, favorited: Boolean) -> Unit)
        fun setLiked(path: String, liked: Boolean)
        fun setFavorited(path: String, favorited: Boolean)
        /** A video at [position] failed to play (bad/empty file); host may skip it. */
        fun onPlaybackError(position: Int, path: String)
        /** A transient playback error is being retried in place. */
        fun onPlaybackRetry()
        /** A video rendered its first frame 鈥?playback is working. */
        fun onPlaybackOk()
        /** Load the folder avatar for [path]; delivers a bitmap (or null) on main thread. */
        fun loadAvatar(path: String, cb: (android.graphics.Bitmap?) -> Unit)
        /** Load NAS-owned tags for [path]; null means the optional tag service is unavailable. */
        fun loadTags(path: String, cb: (List<String>?) -> Unit)
        fun onEditTags(path: String, currentTags: List<String>, onSaved: (List<String>) -> Unit)
        fun onMoveToTrash(path: String)
        fun onOpenTag(tag: String)
        /** User toggled mute via the speaker button 鈥?persist the new value. */
        fun onMuteChanged(muted: Boolean)
        /** Tapping the @folder label opens a folder-restricted feed for that folder path. */
        fun onOpenFolder(folderPath: String)
        /** Long-pressing the file name asks the host to show details for [path]. */
        fun onShowDetails(path: String)
        /** Toggle manual landscape mode for wide videos. */
        fun onToggleOrientation()
    }

    private var paths: List<String> = emptyList()
    private val appContext = context.applicationContext
    private val mediaSourceFactory = ProgressiveMediaSource.Factory(
        NasDataSourceFactory.create(appContext, settings)
    )

    /** Lower the playback buffer floor so a freshly-prepared page starts rendering
     *  sooner 鈥?the win that makes swiping feel snappy. Defaults buffer up to 15-50s
     *  before playing; we only need a small lead for short clips over LAN. */
    private val loadControl = DefaultLoadControl.Builder()
        .setBufferDurationsMs(
            /* minBufferMs = */ PLAYBACK_MIN_BUFFER_MS,
            /* maxBufferMs = */ PLAYBACK_MAX_BUFFER_MS,
            /* bufferForPlaybackMs = */ PLAYBACK_START_BUFFER_MS,
            /* bufferForPlaybackAfterRebufferMs = */ PLAYBACK_AFTER_REBUFFER_MS,
        )
        .build()

    /** Off-main-thread sink for compressing & writing grabbed thumbnail frames. */
    private val thumbExecutor = Executors.newSingleThreadExecutor()

    /** Shared across pages so muting persists as you scroll. Initial value comes from
     *  the saved preference; flips notify the host so the new value is persisted too. */
    var muted: Boolean = initialMuted
        private set

    fun submit(newPaths: List<String>) {
        val oldSize = paths.size
        paths = newPaths
        if (newPaths.size > oldSize) {
            notifyItemRangeInserted(oldSize, newPaths.size - oldSize)
        } else {
            notifyDataSetChanged()
        }
    }

    override fun getItemCount(): Int = paths.size

    override fun onCreateViewHolder(parent: ViewGroup, viewType: Int): VH {
        val binding = PageVideoBinding.inflate(LayoutInflater.from(parent.context), parent, false)
        return VH(binding)
    }

    override fun onBindViewHolder(holder: VH, position: Int) = holder.bind(paths[position])

    override fun onViewAttachedToWindow(holder: VH) = holder.preparePlayer()
    override fun onViewDetachedFromWindow(holder: VH) = holder.releasePlayer()

    fun playHolder(holder: VH?) { holder?.play() }
    fun pauseHolder(holder: VH?) { holder?.pause() }
    /** Warm up a holder's player without starting playback, so swiping to it is instant. */
    fun prepareHolder(holder: VH?) { holder?.preparePlayer() }
    /** Fully release a holder's player (e.g. when the activity goes to the background). */
    fun releaseHolder(holder: VH?) { holder?.releasePlayer() }

    /** Release the thumbnail executor when the feed is torn down. */
    override fun onDetachedFromRecyclerView(recyclerView: RecyclerView) {
        super.onDetachedFromRecyclerView(recyclerView)
        thumbExecutor.shutdown()
    }

    // ADAPTER_VH
    @SuppressLint("ClickableViewAccessibility")
    inner class VH(val binding: PageVideoBinding) : RecyclerView.ViewHolder(binding.root) {
        private var player: ExoPlayer? = null
        private var currentPath: String? = null
        private val handler = Handler(Looper.getMainLooper())
        private var userSeeking = false
        private var liked = false
        private var favorited = false
        private var currentTags: List<String> = emptyList()
        private var fileNameCanExpand = false
        private var fileNameExpanded = false
        // True once this video has rendered a frame 鈥?i.e. it's a playable file. Used to
        // tell a genuinely-bad file (never rendered 鈫?skip) apart from a transient error
        // while seeking/buffering an already-playing video (鈫?retry in place, don't skip).
        private var hasRendered = false
        private var retriedAfterError = false
        // Whether the rail/bottom controls are currently shown. A tap while they're
        // hidden only reveals them (doesn't also toggle play/pause), so the two gestures
        // stop fighting each other.
        private var progressChromeVisible = true
        private var controlsChromeVisible = true

        // Horizontal-drag scrubbing on the lower half of the screen. We track the raw
        // touch ourselves (not via GestureDetector) so we can do a relative scrub:
        // sweeping the full screen width spans the whole video.
        private var scrubbing = false
        // Direction is decided ONCE per gesture so a horizontal scrub and a vertical
        // page-swipe can't keep stealing the touch from each other mid-drag.
        private var dragDecided = false
        private var scrubStartX = 0f
        private var scrubStartY = 0f
        private var scrubStartPosMs = 0L
        private var scrubTargetMs = 0L
        private val fastSeekState = FastSeekState()
        private var activeFastSeek: FastSeekState.Request? = null
        private var seekRetryUntilMs = 0L

        // Drives the seek bar + time labels from playback position.
        private val progressTick = object : Runnable {
            override fun run() {
                val p = player ?: return
                if (!userSeeking && p.duration > 0) {
                    binding.seekBar.max = p.duration.toInt()
                    binding.seekBar.progress = p.currentPosition.toInt()
                    binding.timeCurrent.text = fmtTime(p.currentPosition)
                    binding.timeTotal.text = fmtTime(p.duration)
                }
                handler.postDelayed(this, 500)
            }
        }

        // Fades the rail + bottom info out after a few seconds of no interaction.
        private val hideProgressChrome = Runnable { setProgressChromeVisible(false) }
        private val hideControlsChrome = Runnable { setControlsChromeVisible(false) }

        private val gestureDetector = GestureDetector(binding.root.context,
            object : GestureDetector.SimpleOnGestureListener() {
                // Must return true so the detector keeps receiving the rest of the
                // gesture (UP, double-tap). Returning false here drops everything
                // after DOWN, which is why single/double tap never fired.
                override fun onDown(e: MotionEvent): Boolean = true
                override fun onSingleTapConfirmed(e: MotionEvent): Boolean {
                    // Progress visibility decides whether a tap reveals chrome or toggles playback.
                    if (!progressChromeVisible) {
                        revealChrome()
                    } else {
                        togglePlayPause()
                        revealChrome()  // keep controls up & reset the auto-hide timer
                    }
                    return true
                }
                override fun onDoubleTap(e: MotionEvent): Boolean {
                    showLike()
                    revealChrome()
                    return true
                }
                override fun onLongPress(e: MotionEvent) {
                    // Hold to fast-forward (鎶栭煶-style 2x), restored on finger up.
                    startFastForward()
                }
            })

        init {
            binding.root.addOnLayoutChangeListener { _, left, _, right, _, oldLeft, _, oldRight, _ ->
                if (right - left != oldRight - oldLeft) updateFileNameMaxWidth()
            }
            // Touch handling: horizontal drags on the LOWER HALF scrub the video
            // (relative: full screen width = whole clip). Vertical drags are left to the
            // ViewPager2 for page-swiping. Direction is locked in once per gesture, and
            // when we claim a horizontal scrub we tell the parent pager to stop
            // intercepting so the two gestures can't fight. Taps/double-tap/long-press
            // still go to the GestureDetector while undecided.
            binding.touchLayer.setOnTouchListener { v, ev ->
                when (ev.actionMasked) {
                    MotionEvent.ACTION_DOWN -> {
                        scrubbing = false
                        dragDecided = false
                        scrubStartX = ev.x
                        scrubStartY = ev.y
                        gestureDetector.onTouchEvent(ev)
                    }
                    MotionEvent.ACTION_MOVE -> {
                        if (!dragDecided) decideDragDirection(ev, v)
                        if (scrubbing) {
                            updateScrub(ev.x - scrubStartX, v.width)
                            setProgressChromeVisible(true)
                        } else {
                            // Vertical / undecided: let the pager and tap detector see it.
                            gestureDetector.onTouchEvent(ev)
                        }
                    }
                    MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                        if (scrubbing) {
                            endScrub(ev.actionMasked == MotionEvent.ACTION_UP)
                        } else {
                            gestureDetector.onTouchEvent(ev)
                        }
                        // Release the pager lock taken during a scrub.
                        v.parent?.requestDisallowInterceptTouchEvent(false)
                        stopFastForward()
                    }
                    else -> gestureDetector.onTouchEvent(ev)
                }
                true
            }
            binding.muteBtn.setOnClickListener { toggleMute() }
            binding.rotateBtn.setOnClickListener {
                host.onToggleOrientation()
                revealChrome()
            }
            binding.likeBtn.setOnClickListener {
                toggleLike()
                revealChrome()
            }
            binding.tagEditBtn.setOnClickListener {
                currentPath?.let { path ->
                    host.onEditTags(path, currentTags) { saved ->
                        if (currentPath == path) applyTags(saved)
                    }
                }
                revealChrome()
            }
            binding.trashBtn.setOnClickListener {
                currentPath?.let(host::onMoveToTrash)
                revealChrome()
            }
            binding.favBtn.setOnClickListener {
                toggleFavorite()
                revealChrome()
            }
            binding.videoNameExpand.setOnClickListener {
                if (!fileNameCanExpand) return@setOnClickListener
                fileNameExpanded = !fileNameExpanded
                applyFileNameExpansion()
                revealChrome()
            }
            // Tap @folder name or avatar 鈫?open the folder's "author profile" page.
            binding.videoFolder.setOnClickListener {
                val path = currentPath ?: return@setOnClickListener
                host.onOpenFolder(folderPathFromVideoPath(path))
            }
            binding.avatar.setOnClickListener {
                val path = currentPath ?: return@setOnClickListener
                host.onOpenFolder(folderPathFromVideoPath(path))
            }
            // Long-press file name 鈫?show details (path / size / folder).
            binding.videoName.setOnLongClickListener {
                currentPath?.let { host.onShowDetails(it) }
                true
            }
            binding.seekBar.setOnSeekBarChangeListener(object : SeekBar.OnSeekBarChangeListener {
                override fun onProgressChanged(sb: SeekBar, value: Int, fromUser: Boolean) {
                    if (fromUser) binding.timeCurrent.text = fmtTime(value.toLong())
                }
                override fun onStartTrackingTouch(sb: SeekBar) { userSeeking = true }
                override fun onStopTrackingTouch(sb: SeekBar) {
                    userSeeking = false
                    seekTo(sb.progress.toLong())
                }
            })
        }

        fun bind(path: String) {
            currentPath = path
            binding.videoFolder.text =
                "@" + folderDisplayName(folderPathFromVideoPath(path), settings.normalizedRootPath)
            currentTags = emptyList()
            binding.videoTags.text = ""
            binding.videoTags.alpha = 1f
            binding.videoTags.visibility = View.GONE
            binding.videoName.text = path.substringAfterLast('/')
            updateFileNameMaxWidth()
            fileNameCanExpand = false
            fileNameExpanded = false
            applyFileNameExpansion()
            binding.videoName.post {
                if (currentPath != path) return@post
                val layout = binding.videoName.layout
                val lastLine = (layout?.lineCount ?: 0) - 1
                val ellipsisCount = if (lastLine >= 0) layout?.getEllipsisCount(lastLine) ?: 0 else 0
                fileNameCanExpand = ellipsisCount > 0
                applyFileNameExpansion()
            }
            binding.seekBar.progress = 0
            binding.timeCurrent.text = "00:00"
            binding.timeTotal.text = "00:00"
            showLoadingReason(PlaybackLoadingReason.NONE)
            // A recycled holder may have faded its chrome out; restore it.
            setProgressChromeVisible(true)
            setControlsChromeVisible(true)
            scrubbing = false
            dragDecided = false
            binding.scrubOverlay.visibility = View.GONE
            applyMuteIcon()
            invalidateFastSeek()
            // Default UI until async load returns
            liked = false; favorited = false
            applyLikeIcon(); applyFavIcon()
            host.loadInteraction(path) { l, f ->
                if (currentPath == path) {
                    liked = l; favorited = f
                    applyLikeIcon(); applyFavIcon()
                }
            }
            // Folder avatar: default icon until (and unless) a folder cover image loads.
            binding.avatar.setImageResource(R.drawable.ic_folder)
            binding.avatar.setPadding(0, 0, 0, 0)
            host.loadAvatar(path) { bmp ->
                if (currentPath == path && bmp != null) {
                    binding.avatar.setImageBitmap(bmp)
                }
            }
            host.loadTags(path) { tags ->
                if (currentPath != path) return@loadTags
                applyTags(tags.orEmpty())
            }
        }

        private fun applyTags(tags: List<String>) {
            currentTags = tags.toList()
            if (currentTags.isEmpty()) {
                binding.videoTags.text = "添加标签"
                binding.videoTags.movementMethod = null
                binding.videoTags.setOnClickListener {
                    currentPath?.let { path ->
                        host.onEditTags(path, currentTags) { saved ->
                            if (currentPath == path) applyTags(saved)
                        }
                    }
                }
            } else {
                binding.videoTags.text = clickableVideoTags(currentTags)
                binding.videoTags.movementMethod = LinkMovementMethod.getInstance()
                binding.videoTags.highlightColor = Color.TRANSPARENT
                binding.videoTags.setOnClickListener(null)
            }
            binding.videoTags.visibility = View.VISIBLE
            binding.videoTags.alpha = if (controlsChromeVisible) 1f else 0f
        }

        private fun applyFileNameExpansion() {
            val state = fileNameExpansionState(fileNameCanExpand, fileNameExpanded)
            binding.videoName.maxLines = state.maxLines
            binding.videoNameExpand.text = state.actionLabel.orEmpty()
            binding.videoNameExpand.visibility = if (
                state.actionLabel != null && controlsChromeVisible
            ) {
                View.VISIBLE
            } else {
                View.GONE
            }
        }

        private fun updateFileNameMaxWidth() {
            val availableWidth = binding.root.width
            if (availableWidth > 0) binding.videoName.maxWidth = fileNameMaxWidth(availableWidth)
        }

        private fun updatePlaybackRouteBadge() {
            val route = PlaybackRouteStore.routeFor(settings)
            binding.routeBadge.text = route?.label.orEmpty()
            binding.routeBadge.visibility = if (route == null) View.GONE else View.VISIBLE
        }

        private fun clickableVideoTags(tags: List<String>): SpannableString {
            val text = formatVideoTags(tags)
            val spannable = SpannableString(text)
            var cursor = 0
            tags.forEachIndexed { index, tag ->
                val start = cursor
                val end = start + tag.length + 1
                spannable.setSpan(object : ClickableSpan() {
                    override fun onClick(widget: View) {
                        tagAtIndex(tags, index)?.let(host::onOpenTag)
                    }

                    override fun updateDrawState(ds: TextPaint) {
                        ds.isUnderlineText = false
                    }
                }, start, end, Spanned.SPAN_EXCLUSIVE_EXCLUSIVE)
                cursor = end + 2
            }
            return spannable
        }

        fun preparePlayer() {
            val path = currentPath ?: return
            if (player != null) return
            hasRendered = false
            retriedAfterError = false
            val p = ExoPlayer.Builder(binding.root.context)
                .setMediaSourceFactory(mediaSourceFactory)
                .setLoadControl(loadControl)
                .build()
            p.repeatMode = Player.REPEAT_MODE_ONE
            p.volume = if (muted) 0f else 1f
            p.setSeekParameters(seekParametersFor(p.duration))
            p.addListener(object : Player.Listener {
                override fun onPlaybackStateChanged(state: Int) {
                    updatePlaybackRouteBadge()
                    val fastSeekReadyResult = if (state == Player.STATE_READY) {
                        settleActiveFastSeek(p)
                    } else {
                        FastSeekReadyResult.NONE
                    }
                    if (state == Player.STATE_READY && !shouldHandleReadySuccess(fastSeekReadyResult)) {
                        return
                    }
                    val showBuffering = shouldShowBufferingSpinner(
                        isBuffering = state == Player.STATE_BUFFERING,
                        hasRendered = hasRendered,
                        hasActiveSeek = activeFastSeek != null,
                    )
                    binding.buffering.visibility = if (showBuffering) View.VISIBLE else View.GONE
                    if (showBuffering) {
                        showLoadingReason(PlaybackLoadingReason.BUFFERING)
                    } else if (state == Player.STATE_READY) {
                        showLoadingReason(PlaybackLoadingReason.NONE)
                    } else if (state == Player.STATE_BUFFERING) {
                        showLoadingReason(PlaybackLoadingReason.NONE)
                    }
                    if (state == Player.STATE_READY && hasRendered) {
                        retriedAfterError = false
                        if (p.playWhenReady) host.onPlaybackOk()
                    }
                }
                override fun onRenderedFirstFrame() {
                    // First frame is on screen 鈥?the file plays. Record that so a later
                    // transient error (e.g. while seeking) isn't mistaken for a bad file.
                    hasRendered = true
                    retriedAfterError = false
                    host.onPlaybackOk()
                    // Grab it for the thumbnail cache if we don't already have one.
                    maybeGrabThumbnail()
                }
                override fun onPlayerError(error: androidx.media3.common.PlaybackException) {
                    binding.buffering.visibility = View.GONE
                    val pos = bindingAdapterPosition
                    val pth = currentPath
                    if (!retriedAfterError) {
                        showLoadingReason(PlaybackLoadingReason.RETRYING)
                        // First error for this video (whether it rendered or not): retry
                        // in place. Network streams often hit transient errors on initial
                        // connect (SSL handshake timeout, brief NAS hiccup) that resolve
                        // on a second attempt. If this follows a seek on a video that
                        // already rendered, retry quietly because the NAS is reachable;
                        // the player just needs a fresh range request at the new offset.
                        retriedAfterError = true
                        val withinSeekRetryGrace =
                            hasRendered && SystemClock.elapsedRealtime() <= seekRetryUntilMs
                        val recoveryRequest = activeFastSeek
                            ?.takeIf { withinSeekRetryGrace }
                            ?.let { fastSeekState.recover(it.id) }
                        val retryPlan = playerErrorRetryPlan(recoveryRequest)
                        if (retryPlan is PlayerErrorRetryPlan.Ordinary) host.onPlaybackRetry()
                        val resumeAt = when (retryPlan) {
                            is PlayerErrorRetryPlan.FastSeek -> retryPlan.targetMs
                            PlayerErrorRetryPlan.Ordinary -> when {
                                hasRendered -> player?.currentPosition ?: 0L
                                else -> 0L
                            }
                        }
                        player?.let {
                            it.setSeekParameters(
                                when (retryPlan) {
                                    is PlayerErrorRetryPlan.FastSeek -> SeekParameters.EXACT
                                    PlayerErrorRetryPlan.Ordinary -> seekParametersFor(it.duration)
                                }
                            )
                            it.prepare()
                            it.seekTo(resumeAt)
                            it.playWhenReady = true
                        }
                        return
                    }
                    // Retried once and still failing 鈫?genuinely bad file or NAS offline.
                    invalidateFastSeek()
                    if (pos != RecyclerView.NO_POSITION && pth != null) {
                        showLoadingReason(PlaybackLoadingReason.FAILED_SKIPPED)
                        host.onPlaybackError(pos, pth)
                    }
                }
            })
            binding.playerView.player = p
            p.setMediaItem(MediaItem.fromUri(DavUrl.streamUrl(settings, path)))
            p.prepare()
            p.playWhenReady = false
            player = p
            updatePlaybackRouteBadge()
        }

        /** Grab the current TextureView frame and persist it as this video's thumbnail,
         *  unless one already exists. Bitmap copy is on the main thread (fast); the
         *  JPEG encode + disk write are offloaded. */
        private fun maybeGrabThumbnail() {
            val path = currentPath ?: return
            if (thumbs.has(path)) return
            val tv = binding.playerView.videoSurfaceView as? TextureView ?: return
            val bmp: Bitmap = tv.getBitmap() ?: return
            thumbExecutor.execute {
                thumbs.save(path, bmp)
                bmp.recycle()
            }
        }

        fun play() {
            preparePlayer()
            player?.playWhenReady = true
            binding.pauseIcon.visibility = View.GONE
            handler.removeCallbacks(progressTick)
            handler.post(progressTick)
            revealChrome()
        }

        fun pause() {
            player?.playWhenReady = false
            handler.removeCallbacks(progressTick)
            // Keep controls visible while paused so the user isn't left with a bare frame.
            handler.removeCallbacks(hideProgressChrome)
            handler.removeCallbacks(hideControlsChrome)
            setProgressChromeVisible(true)
            setControlsChromeVisible(true)
        }

        private fun togglePlayPause() {
            val p = player ?: return
            if (p.playWhenReady) {
                p.playWhenReady = false
                binding.pauseIcon.visibility = View.VISIBLE
            } else {
                p.playWhenReady = true
                binding.pauseIcon.visibility = View.GONE
            }
        }

        private var fastForwarding = false

        // --- Horizontal-drag scrubbing (lower half of the screen) ---

        /** Decide, once per gesture, whether this drag is a horizontal scrub or a
         *  vertical page-swipe. Only commits once the finger has moved past the slop, so
         *  a tiny wobble doesn't lock in the wrong direction. A scrub also requires the
         *  gesture to have begun in the lower half of the page. */
        private fun decideDragDirection(e: MotionEvent, view: View) {
            val dx = e.x - scrubStartX
            val dy = e.y - scrubStartY
            val adx = kotlin.math.abs(dx)
            val ady = kotlin.math.abs(dy)
            // Wait until movement is meaningful before committing to a direction.
            if (adx < SCRUB_TOUCH_SLOP && ady < SCRUB_TOUCH_SLOP) return

            dragDecided = true
            // Any committed drag means the finger is moving, not held 鈥?end 2x if it was on.
            stopFastForward()
            val p = player
            val horizontal = adx > ady   // dominant axis wins
            val inLowerHalf = scrubStartY >= view.height * 0.5f
            if (horizontal && inLowerHalf && p != null && p.duration > 0) {
                // Claim the gesture: stop the pager from stealing it to page-swipe.
                view.parent?.requestDisallowInterceptTouchEvent(true)
                beginScrub()
            }
            // Otherwise it's a vertical swipe 鈥?leave dragDecided=true so we stop
            // re-checking and let the pager handle the page change.
        }

        private fun beginScrub() {
            val p = player ?: return
            // If a long-press already kicked off 2x, cancel it 鈥?scrubbing takes over.
            stopFastForward()
            scrubbing = true
            userSeeking = true   // pause the auto progress-tick from fighting us
            scrubStartPosMs = p.currentPosition
            scrubTargetMs = scrubStartPosMs
            handler.removeCallbacks(hideProgressChrome)
            handler.removeCallbacks(hideControlsChrome)
            revealChrome()
            binding.scrubOverlay.visibility = View.VISIBLE
        }

        /** Map horizontal travel to a time delta: a full screen-width sweep == whole clip. */
        private fun updateScrub(dx: Float, viewWidth: Int) {
            val p = player ?: return
            val dur = p.duration
            if (dur <= 0 || viewWidth <= 0) return
            val deltaMs = (dx / viewWidth) * dur
            scrubTargetMs = (scrubStartPosMs + deltaMs).toLong().coerceIn(0L, dur)
            binding.seekBar.max = dur.toInt()
            binding.seekBar.progress = scrubTargetMs.toInt()
            binding.scrubOverlay.text = "${fmtTime(scrubTargetMs)} / ${fmtTime(dur)}"
            binding.timeCurrent.text = fmtTime(scrubTargetMs)
        }

        private fun endScrub(commit: Boolean) {
            scrubbing = false
            userSeeking = false
            binding.scrubOverlay.visibility = View.GONE
            if (commit) seekTo(scrubTargetMs)
            revealChrome()   // keep controls up briefly, then auto-hide
        }

        private fun seekTo(positionMs: Long) {
            val p = player ?: return
            val request = fastSeekState.start(positionMs, p.duration)
            activeFastSeek = request
            p.setSeekParameters(seekParametersFor(request.durationMs))
            seekRetryUntilMs = SystemClock.elapsedRealtime() + SEEK_RETRY_GRACE_MS
            retriedAfterError = false
            p.seekTo(request.targetMs)
            if (p.playWhenReady) binding.pauseIcon.visibility = View.GONE
        }

        private fun settleActiveFastSeek(p: ExoPlayer): FastSeekReadyResult {
            val request = activeFastSeek ?: return FastSeekReadyResult.NONE
            return when (fastSeekState.settle(request.id, p.currentPosition)) {
                null -> {
                    invalidateFastSeek()
                    FastSeekReadyResult.NONE
                }
                is FastSeekState.Settlement.Playable -> {
                    invalidateFastSeek()
                    FastSeekReadyResult.SETTLED
                }
                is FastSeekState.Settlement.Fallback -> {
                    // READY means the decoder has already accepted the seek. Do not
                    // call prepare() a second time just because the nearest sync
                    // frame is outside our UI tolerance; that turns one drag into
                    // two network loads. Error callbacks still use the recovery path.
                    invalidateFastSeek()
                    FastSeekReadyResult.SETTLED
                }
            }
        }

        private fun recoverActiveFastSeek(request: FastSeekState.Request): Boolean {
            val p = player ?: run {
                invalidateFastSeek()
                return false
            }
            val recovery = fastSeekState.recover(request.id)
            if (recovery == null) {
                invalidateFastSeek()
                return false
            }
            showLoadingReason(PlaybackLoadingReason.SEEK_RECOVERY)
            retriedAfterError = false
            seekRetryUntilMs = SystemClock.elapsedRealtime() + SEEK_RETRY_GRACE_MS
            p.setSeekParameters(SeekParameters.EXACT)
            p.prepare()
            p.seekTo(recovery.targetMs)
            p.playWhenReady = true
            return true
        }

        private fun invalidateFastSeek() {
            fastSeekState.invalidate()
            activeFastSeek = null
            seekRetryUntilMs = 0L
        }

        private fun startFastForward() {
            val p = player ?: return
            // Don't fast-forward if a drag/scrub is in progress 鈥?the long-press timer was
            // armed on ACTION_DOWN before we knew the finger would start dragging.
            if (fastForwarding || scrubbing || dragDecided || !p.playWhenReady) return
            fastForwarding = true
            p.playbackParameters = PlaybackParameters(2f)
            binding.speedBadge.visibility = View.VISIBLE
        }

        private fun stopFastForward() {
            if (!fastForwarding) return
            fastForwarding = false
            player?.playbackParameters = PlaybackParameters(1f)
            binding.speedBadge.visibility = View.GONE
        }

        /** Show the rail + bottom info, then hide it directly after inactivity. */
        private fun revealChrome() {
            setProgressChromeVisible(true)
            setControlsChromeVisible(true)
            handler.removeCallbacks(hideProgressChrome)
            handler.removeCallbacks(hideControlsChrome)
            handler.postDelayed(hideProgressChrome, PROGRESS_CHROME_TIMEOUT_MS)
            handler.postDelayed(hideControlsChrome, CONTROLS_CHROME_TIMEOUT_MS)
        }

        private fun setProgressChromeVisible(visible: Boolean) {
            progressChromeVisible = visible
            binding.seekBar.setInstantVisibility(visible)
            binding.timeCurrent.setInstantVisibility(visible)
            binding.timeSeparator.setInstantVisibility(visible)
            binding.timeTotal.setInstantVisibility(visible)
        }

        private fun setControlsChromeVisible(visible: Boolean) {
            controlsChromeVisible = visible
            binding.rightRail.setInstantVisibility(visible)
            binding.trashBtn.setInstantVisibility(visible)
            binding.muteBtn.setInstantVisibility(visible)
            binding.rotateBtn.setInstantVisibility(visible)
            binding.videoFolder.setInstantVisibility(visible)
            if (binding.videoTags.visibility == View.VISIBLE) {
                binding.videoTags.setInstantVisibility(visible)
            }
            binding.videoName.setInstantVisibility(visible)
            if (visible) applyFileNameExpansion() else binding.videoNameExpand.visibility = View.GONE
        }

        private fun toggleMute() {
            muted = !muted
            player?.volume = if (muted) 0f else 1f
            applyMuteIcon()
            host.onMuteChanged(muted)
            revealChrome()
        }

        private fun applyMuteIcon() {
            binding.muteBtn.setImageResource(
                if (muted) R.drawable.ic_volume_off else R.drawable.ic_volume_on
            )
        }

        private fun showLoadingReason(reason: PlaybackLoadingReason) {
            val label = reason.label()
            if (label == null) {
                binding.loadingReason.visibility = View.GONE
            } else {
                binding.loadingReason.text = label
                binding.loadingReason.visibility = View.VISIBLE
            }
        }

        /** Double-tap: always set liked + play the big heart burst. */
        private fun showLike() {
            if (!liked) {
                liked = true
                currentPath?.let { host.setLiked(it, true) }
                applyLikeIcon()
            }
            val heart = binding.likeHeart
            heart.alpha = 0f
            heart.scaleX = 0.5f
            heart.scaleY = 0.5f
            heart.visibility = View.VISIBLE
            heart.animate()
                .alpha(1f).scaleX(1.2f).scaleY(1.2f).setDuration(180)
                .withEndAction {
                    heart.animate().alpha(0f).scaleX(1.5f).scaleY(1.5f)
                        .setStartDelay(250).setDuration(220)
                        .withEndAction { heart.visibility = View.GONE }
                        .start()
                }.start()
        }

        /** Tap the rail heart: toggle on/off. */
        private fun toggleLike() {
            liked = !liked
            currentPath?.let { host.setLiked(it, liked) }
            applyLikeIcon()
        }

        private fun toggleFavorite() {
            favorited = !favorited
            currentPath?.let { host.setFavorited(it, favorited) }
            applyFavIcon()
        }

        private fun applyLikeIcon() {
            binding.likeBtn.setImageResource(
                if (liked) R.drawable.ic_heart_filled else R.drawable.ic_heart_outline
            )
            binding.likeBtn.setColorFilter(if (liked) 0xffa855f7.toInt() else android.graphics.Color.WHITE)
            binding.likeBtn.alpha = if (liked) 1f else 0.9f
            binding.likeBtn.scaleX = 1f
            binding.likeBtn.scaleY = 1f
            binding.likeCount.text = if (liked) "1" else "0"
        }

        private fun applyFavIcon() {
            binding.favBtn.setImageResource(
                if (favorited) R.drawable.ic_star_on else R.drawable.ic_star
            )
            binding.favLabel.text = if (favorited) "已收藏" else "收藏"
        }

        private fun fmtTime(ms: Long): String {
            if (ms <= 0) return "00:00"
            val totalSec = ms / 1000
            val m = totalSec / 60
            val s = totalSec % 60
            return "%02d:%02d".format(m, s)
        }

        fun releasePlayer() {
            handler.removeCallbacks(progressTick)
            handler.removeCallbacks(hideProgressChrome)
            handler.removeCallbacks(hideControlsChrome)
            invalidateFastSeek()
            stopFastForward()
            player?.release()
            player = null
            binding.playerView.player = null
        }
    }

    companion object {
        /** How long the controls stay visible after the last touch before hiding. */
        private const val PROGRESS_CHROME_TIMEOUT_MS = 3_000L
        private const val CONTROLS_CHROME_TIMEOUT_MS = 30_000L
        /** Horizontal travel (px) before a drag is treated as a scrub, not a tap. */
        private const val SCRUB_TOUCH_SLOP = 24f
        /** During this window, seek-related player errors retry without NAS warnings. */
        private const val SEEK_RETRY_GRACE_MS = 12_000L
    }
}

private fun View.setInstantVisibility(visible: Boolean) {
    animate().cancel()
    alpha = 1f
    visibility = if (visible) View.VISIBLE else View.INVISIBLE
}
