package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.pager.VerticalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.Send
import androidx.compose.material.icons.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Favorite
import androidx.compose.material.icons.filled.FavoriteBorder
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material.icons.outlined.ChatBubbleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.media3.common.MediaItem
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.ui.PlayerView
import com.voiid.app.model.ClipCount
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.CommentSendState
import com.voiid.app.model.VClip
import com.voiid.app.model.VClipComment
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Fullscreen reels player: a vertical pager over the loaded feed page with a REAL
 * ExoPlayer (the previous version drew a gradient and a play glyph — it never played
 * anything). Port of iOS `ClipFullscreenView.swift`.
 *
 * PLAYER LIFECYCLE is the load-bearing part of this file: only the current page and its
 * immediate neighbours hold an ExoPlayer. An unbounded pager of live players is the
 * standard way this screen runs the device out of memory.
 */
@Composable
fun ClipFullscreenView(
    clips: ClipsStore,
    startIndex: Int,
    myUserId: String,
    myName: String,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    val pagerState = rememberPagerState(initialPage = startIndex) { clips.clips.size }
    var showComments by remember { mutableStateOf(false) }
    var muted by remember { mutableStateOf(true) }

    val pool = remember { ClipPlayerPool(context) }
    DisposableEffect(Unit) { onDispose { pool.releaseAll() } }

    val currentClip = clips.clips.getOrNull(pagerState.currentPage)

    // Page lifecycle: retain a ±1 window, prepare it, play the current one.
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.currentPage }.collect { page ->
            val window = listOf(page - 1, page, page + 1)
                .filter { it in clips.clips.indices }
                .map { clips.clips[it].id }
            pool.retainOnly(window)
            window.forEach { id ->
                pool.prepare(id, muted) { clips.playbackUrl(id) }
            }
            val clip = clips.clips.getOrNull(page) ?: return@collect
            pool.play(clip.id)

            // A view counts after a >=2s watch, not on appearance — counting scroll-past
            // impressions inflates the number the entire grid is built around.
            delay(2000)
            if (pagerState.currentPage == page) clips.markViewed(clip.id)
        }
    }

    LaunchedEffect(muted) { pool.setMuted(muted) }

    Column(Modifier.fillMaxSize().background(Color.Black)) {
        Box(
            Modifier
                .fillMaxWidth()
                .weight(if (showComments) 0.42f else 1f)
        ) {
            VerticalPager(
                state = pagerState,
                modifier = Modifier.fillMaxSize(),
                userScrollEnabled = !showComments,
            ) { page ->
                val clip = clips.clips[page]
                ClipPlayerPage(
                    clip = clip,
                    player = pool.player(clip.id),
                    muted = muted,
                    compact = showComments,
                    onToggleMute = { muted = !muted },
                    onToggleLike = { haptics.tap(); clips.toggleLike(clip.id) },
                    onOpenComments = {
                        haptics.tap()
                        showComments = true
                        pool.pause(clip.id)
                        if (clips.commentsByClip[clip.id] == null) clips.loadComments(clip.id)
                    },
                    onBack = {
                        if (showComments) {
                            showComments = false
                            pool.play(clip.id)
                        } else onClose()
                    },
                )
            }
        }

        if (showComments && currentClip != null) {
            CommentsPanel(
                clips = clips,
                clip = currentClip,
                myUserId = myUserId,
                myName = myName,
                modifier = Modifier.fillMaxWidth().weight(0.58f),
                onClose = {
                    showComments = false
                    pool.play(currentClip.id)
                },
            )
        }
    }
}

@Composable
private fun ClipPlayerPage(
    clip: VClip,
    player: ExoPlayer?,
    muted: Boolean,
    compact: Boolean,
    onToggleMute: () -> Unit,
    onToggleLike: () -> Unit,
    onOpenComments: () -> Unit,
    onBack: () -> Unit,
) {
    var ready by remember(player) { mutableStateOf(false) }

    DisposableEffect(player) {
        val p = player ?: return@DisposableEffect onDispose { }
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) ready = true
            }
        }
        p.addListener(listener)
        if (p.playbackState == Player.STATE_READY) ready = true
        onDispose { p.removeListener(listener) }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) { detectTapGestures(onTap = { onToggleMute() }) },
    ) {
        if (player != null && ready) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        this.player = player
                        resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_ZOOM
                    }
                },
                update = { it.player = player },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            // Branded loader over the blurred cover frame — never a black screen.
            ClipVideoLoader(
                thumbUrl = clip.thumbUrl,
                localThumbPath = clip.localThumbPath,
                modifier = Modifier.fillMaxSize(),
            )
        }

        // Chrome
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(16.dp), verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    if (compact) Icons.Default.KeyboardArrowDown else Icons.Default.ArrowBack,
                    "Back", tint = Color.White,
                    modifier = Modifier.size(26.dp).softClickable(scale = 0.9f) { onBack() },
                )
                Spacer(Modifier.weight(1f))
                if (!compact) {
                    Icon(
                        if (muted) Icons.Default.VolumeOff else Icons.Default.VolumeUp,
                        null, tint = Color.White.copy(alpha = 0.9f),
                        modifier = Modifier.size(20.dp),
                    )
                }
            }
            Spacer(Modifier.weight(1f))

            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(
                    Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                    ) {
                        VoiidAvatar(size = 44.dp)
                        Text(
                            clip.authorName,
                            style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = Color.White,
                        )
                    }
                    if (!compact && !clip.caption.isNullOrEmpty()) {
                        Text(
                            clip.caption,
                            style = VoiidFont.rounded(14),
                            color = Color.White,
                            maxLines = 3,
                        )
                    }
                }

                if (!compact) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(24.dp),
                    ) {
                        ActionButton(
                            if (clip.likedByMe) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                            ClipCount.compact(clip.likeCount),
                            if (clip.likedByMe) VoiidColor.error else Color.White,
                            onToggleLike,
                        )
                        ActionButton(
                            Icons.Outlined.ChatBubbleOutline,
                            ClipCount.compact(clip.commentCount),
                            Color.White,
                            onOpenComments,
                        )
                        ActionButton(
                            Icons.Default.RemoveRedEye,
                            ClipCount.compact(clip.viewCount),
                            Color.White,
                        ) {}
                    }
                }
            }
        }
    }
}

@Composable
private fun ActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: Color,
    onTap: () -> Unit,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(4.dp),
        modifier = Modifier.softClickable(scale = 0.9f) { onTap() },
    ) {
        Icon(icon, null, tint = tint, modifier = Modifier.size(26.dp))
        Text(label, style = VoiidFont.rounded(11, FontWeight.Medium), color = Color.White)
    }
}

@Composable
private fun CommentsPanel(
    clips: ClipsStore,
    clip: VClip,
    myUserId: String,
    myName: String,
    modifier: Modifier = Modifier,
    onClose: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    var draft by remember { mutableStateOf("") }
    val rows = clips.commentsByClip[clip.id] ?: emptyList()
    val loading = clip.id in clips.commentsLoading

    Column(
        modifier
            .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
            .background(VoiidColor.background)
            .imePadding(),
    ) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 24.dp, vertical = 12.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                if (rows.isEmpty()) "Comments" else "${rows.size} comments",
                style = VoiidFont.rounded(15, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Default.Close, "Close", tint = VoiidColor.textSecondary,
                modifier = Modifier.size(20.dp).softClickable(scale = 0.9f) { onClose() },
            )
        }

        Box(Modifier.fillMaxWidth().weight(1f), contentAlignment = Alignment.Center) {
            when {
                loading && rows.isEmpty() -> CircularProgressIndicator(color = VoiidColor.primary)
                rows.isEmpty() -> Column(horizontalAlignment = Alignment.CenterHorizontally) {
                    Text(
                        "No comments yet",
                        style = VoiidFont.rounded(17, FontWeight.SemiBold),
                        color = VoiidColor.textPrimary,
                    )
                    Text(
                        "Be the first to say something.",
                        style = VoiidFont.rounded(15),
                        color = VoiidColor.textSecondary,
                    )
                }
                else -> LazyColumn(
                    Modifier.fillMaxSize().padding(horizontal = 24.dp),
                    verticalArrangement = Arrangement.spacedBy(16.dp),
                ) {
                    items(rows, key = { it.id }) { c ->
                        CommentRow(c) {
                            clips.retryComment(clip.id, c.id, myUserId, myName)
                        }
                    }
                }
            }
        }

        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Box(
                Modifier
                    .weight(1f)
                    .height(44.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.fieldFill)
                    .padding(horizontal = 16.dp),
                contentAlignment = Alignment.CenterStart,
            ) {
                BasicTextField(
                    value = draft,
                    onValueChange = { draft = it },
                    singleLine = true,
                    textStyle = VoiidFont.rounded(15).copy(color = VoiidColor.textPrimary),
                    cursorBrush = androidx.compose.ui.graphics.SolidColor(VoiidColor.primary),
                    modifier = Modifier.fillMaxWidth(),
                    decorationBox = { inner ->
                        if (draft.isEmpty()) {
                            Text(
                                "Add a comment…",
                                style = VoiidFont.rounded(15),
                                color = VoiidColor.placeholder,
                            )
                        }
                        inner()
                    },
                )
            }
            Icon(
                Icons.AutoMirrored.Filled.Send, "Send", tint = VoiidColor.primary,
                modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) {
                    val text = draft.trim()
                    if (text.isNotEmpty()) {
                        haptics.tap()
                        draft = ""
                        clips.addComment(clip.id, text, myUserId, myName)
                    }
                },
            )
        }
    }
}

@Composable
private fun CommentRow(c: VClipComment, onRetry: () -> Unit) {
    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        VoiidAvatar(size = 32.dp)
        Column(Modifier.weight(1f)) {
            Text(
                c.authorName,
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
            Text(c.text, style = VoiidFont.rounded(14), color = VoiidColor.textPrimary)
            // A failed comment is kept and made retryable — never silently dropped.
            if (c.sendState == CommentSendState.FAILED) {
                Text(
                    "Failed to send · Retry",
                    style = VoiidFont.rounded(12),
                    color = VoiidColor.error,
                    modifier = Modifier.softClickable(scale = 0.95f) { onRetry() },
                )
            }
        }
    }
}

/**
 * Holds at most a ±1 window of ExoPlayers. Everything outside is torn down: an unbounded
 * pager of live players is how this screen OOMs on a long scroll.
 */
private class ClipPlayerPool(private val context: android.content.Context) {
    private val players = mutableMapOf<String, ExoPlayer>()
    private val preparing = mutableSetOf<String>()

    /**
     * The ids [retainOnly] last authorised. Minting a playback URL suspends, and the pager
     * can move several pages during it — without this, a player created for a page that has
     * already scrolled out would never be released ([retainOnly] ran BEFORE it was
     * inserted), which silently defeats the ±1 bound this class exists to enforce.
     */
    private var allowed = emptySet<String>()

    fun player(id: String): ExoPlayer? = players[id]

    suspend fun prepare(id: String, muted: Boolean, url: suspend () -> String?) {
        if (players.containsKey(id) || id in preparing) return
        preparing += id
        try {
            val resolved = url() ?: return
            // Re-check AFTER the suspend: drop the result if the window moved on.
            if (id !in allowed || players.containsKey(id)) return
            val player = ExoPlayer.Builder(context).build().apply {
                setMediaItem(MediaItem.fromUri(resolved))
                repeatMode = Player.REPEAT_MODE_ONE   // clips loop
                volume = if (muted) 0f else 1f
                prepare()
            }
            players[id] = player
        } finally {
            preparing -= id
        }
    }

    fun play(id: String) {
        players.forEach { (key, p) -> if (key != id) p.pause() }
        players[id]?.play()
    }

    fun pause(id: String) { players[id]?.pause() }

    fun setMuted(muted: Boolean) {
        players.values.forEach { it.volume = if (muted) 0f else 1f }
    }

    fun retainOnly(ids: List<String>) {
        val keep = ids.toSet()
        allowed = keep
        players.keys.toList().forEach { id ->
            if (id !in keep) {
                players[id]?.release()
                players.remove(id)
            }
        }
    }

    fun releaseAll() = retainOnly(emptyList())
}
