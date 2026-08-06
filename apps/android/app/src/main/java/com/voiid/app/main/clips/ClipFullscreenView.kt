package com.voiid.app.main.clips

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.sizeIn
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
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
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
import com.voiid.app.model.CreatorStore
import com.voiid.app.model.VClip
import com.voiid.app.model.VClipComment
import com.voiid.app.net.CreatorService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidAvatar
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * One page of the fullscreen pager, independent of WHICH list it came from.
 *
 * The pager used to index straight into [ClipsStore.clips], which is why every grid outside
 * the explore feed had dead tiles: a creator's page and the Following feed are separate
 * sources with their own cursors, and there was simply nothing for a tap to open. Both now
 * map into this shape and hand the pager a list.
 *
 * Note what is NOT here: an r2 key, a rendition set, a playback URL. Playback is resolved
 * from the clip id alone through [ClipsStore.playbackUrl], so the TTL cache and the player
 * pool work identically whichever list produced the row.
 */
data class ClipPagerRow(
    val id: String,
    val authorName: String,
    /** Null on explore rows: the clips feed joins `users`, not `creator_profiles`. */
    val authorHandle: String? = null,
    val thumbUrl: String? = null,
    val localThumbPath: String? = null,
    val caption: String? = null,
    val viewCount: Int = 0,
    val likeCount: Int = 0,
    val commentCount: Int = 0,
    val likedByMe: Boolean = false,
) {
    companion object {
        fun of(c: VClip) = ClipPagerRow(
            id = c.id,
            authorName = c.authorName,
            thumbUrl = c.thumbUrl,
            localThumbPath = c.localThumbPath,
            caption = c.caption,
            viewCount = c.viewCount,
            likeCount = c.likeCount,
            commentCount = c.commentCount,
            likedByMe = c.likedByMe,
        )

        /**
         * [authorName] / [authorHandle] are the fallbacks a creator's own grid must supply:
         * that endpoint does not repeat the author on every row (you are already on their
         * page), so only the Following feed carries them inline.
         */
        fun of(
            c: CreatorService.CreatorClipRow,
            authorName: String? = null,
            authorHandle: String? = null,
        ) = ClipPagerRow(
            id = c.id,
            authorName = c.author_display_name
                ?: authorName
                ?: c.author_handle?.let { "@$it" }
                ?: "Unknown",
            authorHandle = c.author_handle ?: authorHandle,
            thumbUrl = c.thumb_url,
            caption = c.caption,
            viewCount = c.view_count,
            likeCount = c.like_count,
            commentCount = c.comment_count,
        )
    }
}

/**
 * Which grid a fullscreen open came from, and where in it. Carrying the source rather than a
 * bare index is what lets a creator's page and the Following feed open the player at all —
 * an index is meaningless without the list it indexes.
 */
sealed interface ClipPagerSource {
    data class Explore(val index: Int) : ClipPagerSource
    data class Following(val index: Int) : ClipPagerSource
    data class Creator(val handle: String, val index: Int) : ClipPagerSource
}

/**
 * Resolves a [ClipPagerSource] into the list and the paging hook the player needs.
 *
 * Kept here rather than at the call site so the three sources cannot drift: each one owns a
 * different cursor, and the only thing the player needs from any of them is rows plus a
 * "you are at index n" callback.
 */
@Composable
fun ClipPagerHost(
    source: ClipPagerSource,
    clips: ClipsStore,
    creators: CreatorStore,
    onOpenCreator: (String) -> Unit,
    onClose: () -> Unit,
) {
    when (source) {
        is ClipPagerSource.Explore -> ClipFullscreenView(
            clips = clips,
            rows = clips.clips.map { ClipPagerRow.of(it) },
            startIndex = source.index,
            myUserId = clips.myUserId,
            myName = clips.myName,
            creators = creators,
            onLoadMore = { clips.loadMoreIfNeeded(it) },
            onOpenCreator = onOpenCreator,
            onClose = onClose,
        )

        is ClipPagerSource.Following -> ClipFullscreenView(
            clips = clips,
            rows = creators.following.map { ClipPagerRow.of(it) },
            startIndex = source.index,
            myUserId = clips.myUserId,
            myName = clips.myName,
            creators = creators,
            onLoadMore = { creators.loadMoreFollowingIfNeeded(it) },
            onOpenCreator = onOpenCreator,
            onClose = onClose,
        )

        is ClipPagerSource.Creator -> {
            // A creator's grid does not repeat the author on every row — you are already on
            // their page — so the profile supplies the name and handle the chrome needs.
            val profile = creators.cachedProfile(source.handle)
            ClipFullscreenView(
                clips = clips,
                rows = creators.clipsFor(source.handle).map {
                    ClipPagerRow.of(
                        it,
                        authorName = profile?.display_name ?: "@${source.handle}",
                        authorHandle = profile?.handle ?: source.handle,
                    )
                },
                startIndex = source.index,
                myUserId = clips.myUserId,
                myName = clips.myName,
                creators = creators,
                onLoadMore = { creators.loadMoreClipsIfNeeded(source.handle, it) },
                onOpenCreator = onOpenCreator,
                onClose = onClose,
            )
        }
    }
}

/**
 * Fullscreen reels player: a vertical pager over an injected list of clips with a REAL
 * ExoPlayer (the previous version drew a gradient and a play glyph — it never played
 * anything). Port of iOS `ClipFullscreenView.swift`.
 *
 * PLAYER LIFECYCLE is the load-bearing part of this file: only the current page and its
 * immediate neighbours hold an ExoPlayer. An unbounded pager of live players is the
 * standard way this screen runs the device out of memory.
 *
 * [rows] is deliberately a plain list rather than a store: the explore grid, a creator's
 * page and the Following feed each own their own paging, so the pager takes the list plus
 * an [onLoadMore] hook and stays agnostic about where the next page comes from.
 */
@Composable
fun ClipFullscreenView(
    clips: ClipsStore,
    rows: List<ClipPagerRow>,
    startIndex: Int,
    myUserId: String,
    myName: String,
    creators: CreatorStore? = null,
    onLoadMore: (Int) -> Unit = {},
    onOpenCreator: ((String) -> Unit)? = null,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val scope = rememberCoroutineScope()
    val haptics = LocalVoiidHaptics.current

    // The caller usually rebuilds this list on every recomposition (it is a `map` over a
    // snapshot list), so the page effect must read the LATEST one rather than the snapshot
    // it captured when it started — otherwise a page appended mid-watch is invisible to it.
    val latestRows = rememberUpdatedState(rows)

    val pagerState = rememberPagerState(
        initialPage = startIndex.coerceIn(0, (rows.size - 1).coerceAtLeast(0)),
    ) { latestRows.value.size }
    var showComments by remember { mutableStateOf(false) }
    var muted by remember { mutableStateOf(true) }

    val pool = remember { ClipPlayerPool(context) }
    DisposableEffect(Unit) { onDispose { pool.releaseAll() } }

    val currentRow = rows.getOrNull(pagerState.currentPage)

    // Page lifecycle: retain an asymmetric window, warm the current page first, then the
    // neighbours in parallel.
    LaunchedEffect(pagerState) {
        snapshotFlow { pagerState.currentPage }
            // collectLatest, NOT collect. The old version ran `delay(2000)` for the view
            // count inside the collector, which BLOCKS the next page emission — a fast
            // scroller's swipes queued up behind a two-second sleep, and each page's prepare
            // ran two seconds late. collectLatest cancels the previous page's work the moment
            // a new page arrives, which is exactly the desired semantics.
            .collectLatest { page ->
                val list = latestRows.value
                // ASYMMETRIC: two forward, one back. Scrolling in a reels feed is
                // overwhelmingly downward, so the next-next clip is likelier to be needed
                // than the previous — but going back must not be a cold start either.
                val window = listOf(page - 1, page, page + 1, page + 2)
                    .filter { it in list.indices }
                    .map { list[it].id }
                pool.retainOnly(window)

                val row = list.getOrNull(page) ?: return@collectLatest

                // Give the store somewhere to put this clip's counts. A creator's grid row is
                // not in `clips`, so without a seed a like here would find no row to move.
                clips.seedInteraction(
                    row.id, row.likedByMe, row.likeCount, row.commentCount, row.viewCount,
                )

                // Paging belongs to whoever owns the list; the pager only reports position.
                onLoadMore(page)

                // THE CURRENT PAGE FIRST AND ALONE — it is the only one on screen, so it must
                // not queue behind a neighbour's round-trip.
                pool.prepare(row.id, muted) { clips.playbackUrl(row.id) }
                pool.play(row.id)

                // Neighbours in PARALLEL. Previously this was a serial forEach, so preparing
                // page n+1 waited on page n-1's network round-trip — the clip about to appear
                // was last in line behind one already scrolled past.
                window.filter { it != row.id }.forEach { id ->
                    launch { pool.prepare(id, muted) { clips.playbackUrl(id) } }
                }

                // A view counts after a >=2s watch, not on appearance — counting scroll-past
                // impressions inflates the number the entire grid is built around. Under
                // collectLatest this whole block is cancelled when the page changes, so the
                // page check is now belt-and-braces rather than the primary guard.
                delay(2000)
                if (pagerState.currentPage == page) clips.markViewed(row.id)
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
                val row = rows.getOrNull(page) ?: return@VerticalPager
                // Counts the store has moved since this list was built win over the row —
                // otherwise a like made in the player would visibly snap back on the next
                // recomposition of the grid that produced it.
                val live = clips.interactions[row.id]
                val shown = if (live == null) row else row.copy(
                    likedByMe = live.likedByMe,
                    likeCount = live.likeCount,
                    commentCount = live.commentCount,
                    viewCount = live.viewCount,
                )
                // Null profile means "we have never loaded this creator, so we do not know" —
                // and a Follow chip on someone you already follow is worse than no chip.
                val handle = row.authorHandle
                val author = handle?.let { creators?.cachedProfile(it) }
                val openAuthor: (() -> Unit)? =
                    if (handle != null && onOpenCreator != null) {
                        { onClose(); onOpenCreator(handle) }
                    } else null

                ClipPlayerPage(
                    row = shown,
                    player = pool.player(row.id),
                    muted = muted,
                    compact = showComments,
                    showFollowChip = author != null && !author.following && !author.is_self,
                    onToggleMute = { muted = !muted },
                    onToggleLike = { haptics.tap(); clips.toggleLike(row.id) },
                    onFollow = {
                        if (handle != null) {
                            haptics.success()
                            creators?.toggleFollow(handle)
                        }
                    },
                    onOpenAuthor = openAuthor,
                    onOpenComments = {
                        haptics.tap()
                        showComments = true
                        pool.pause(row.id)
                        if (clips.commentsByClip[row.id] == null) clips.loadComments(row.id)
                    },
                    onBack = {
                        if (showComments) {
                            showComments = false
                            pool.play(row.id)
                        } else onClose()
                    },
                )
            }
        }

        if (showComments && currentRow != null) {
            CommentsPanel(
                clips = clips,
                clipId = currentRow.id,
                myUserId = myUserId,
                myName = myName,
                modifier = Modifier.fillMaxWidth().weight(0.58f),
                onClose = {
                    showComments = false
                    pool.play(currentRow.id)
                },
            )
        }
    }
}

@Composable
private fun ClipPlayerPage(
    row: ClipPagerRow,
    player: ExoPlayer?,
    muted: Boolean,
    compact: Boolean,
    showFollowChip: Boolean,
    onToggleMute: () -> Unit,
    onToggleLike: () -> Unit,
    onFollow: () -> Unit,
    onOpenAuthor: (() -> Unit)?,
    onOpenComments: () -> Unit,
    onBack: () -> Unit,
) {
    var ready by remember(player) { mutableStateOf(false) }
    /** Non-null while the user holds one side of the screen (Instagram-style scrub speed). */
    var heldSpeed by remember(player) { mutableStateOf<Float?>(null) }

    /**
     * Drives the bottom scrim and the bottom chrome together. They are one object visually,
     * so animating only the content would leave a dark band hanging over the video for the
     * length of the transition.
     */
    val chromeAlpha by animateFloatAsState(
        targetValue = if (compact) 0f else 1f,
        animationSpec = tween(180),
        label = "clipChromeAlpha",
    )

    // Springs the heart on a like: 1 → 1.3 → 1. A count that merely ticks up is easy to
    // miss on a moving background, and the tap is the one moment this screen must confirm.
    val likePop = remember { Animatable(1f) }
    var likeSeen by remember(row.id) { mutableStateOf(row.likedByMe) }
    LaunchedEffect(row.id, row.likedByMe) {
        if (row.likedByMe && !likeSeen) {
            likePop.animateTo(1.3f, spring(dampingRatio = 0.4f, stiffness = Spring.StiffnessHigh))
            likePop.animateTo(1f, spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMedium))
        }
        likeSeen = row.likedByMe
    }

    DisposableEffect(player) {
        val p = player ?: return@DisposableEffect onDispose { }
        val listener = object : Player.Listener {
            override fun onPlaybackStateChanged(state: Int) {
                if (state == Player.STATE_READY) ready = true
            }
        }
        p.addListener(listener)
        if (p.playbackState == Player.STATE_READY) ready = true
        onDispose {
            p.removeListener(listener)
            // Never leave a recycled player stuck at 2x for the next clip.
            p.setPlaybackSpeed(1f)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            // Hold the LEFT third for 0.5x, the RIGHT third for 2x; release restores 1x.
            // onPress + tryAwaitRelease gives press/release, and onTap still fires for a
            // plain tap so the mute toggle keeps working.
            .pointerInput(compact) {
                detectTapGestures(
                    onPress = { offset ->
                        val third = size.width / 3f
                        val speed = when {
                            compact -> null
                            offset.x < third -> 0.5f
                            offset.x > size.width - third -> 2f
                            else -> null
                        }
                        if (speed != null) {
                            heldSpeed = speed
                            player?.setPlaybackSpeed(speed)
                        }
                        tryAwaitRelease()
                        if (speed != null) {
                            heldSpeed = null
                            player?.setPlaybackSpeed(1f)
                        }
                    },
                    onTap = { onToggleMute() },
                )
            },
    ) {
        if (player != null && ready) {
            AndroidView(
                factory = { ctx ->
                    PlayerView(ctx).apply {
                        useController = false
                        this.player = player
                        // FIT, not ZOOM. ZOOM crops to fill, so any clip whose aspect ratio
                        // does not match the screen loses its edges — the same "clip comes
                        // cropped" complaint reported on iOS, for a different reason.
                        resizeMode = androidx.media3.ui.AspectRatioFrameLayout.RESIZE_MODE_FIT
                    }
                },
                update = { it.player = player },
                modifier = Modifier.fillMaxSize(),
            )
        } else {
            // Branded loader over the blurred cover frame — never a black screen.
            ClipVideoLoader(
                thumbUrl = row.thumbUrl,
                localThumbPath = row.localThumbPath,
                modifier = Modifier.fillMaxSize(),
            )
        }

        // ── SCRIMS ────────────────────────────────────────────────────────────────
        //
        // White chrome used to be drawn straight onto arbitrary user video, so a caption
        // over a bright clip was simply unreadable. Two gradients, the same shape Signal
        // uses in StoryItemMediaView: a deep one under the caption and rail, and a shallow
        // one behind the back/mute row.
        //
        // They fade WITH the chrome rather than staying put — a scrim with nothing on it is
        // just a smudge over the video the user came to watch.
        Box(
            Modifier
                .fillMaxWidth()
                .fillMaxHeight(0.4f)
                .align(Alignment.BottomCenter)
                .alpha(chromeAlpha)
                .background(
                    Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.8f)))
                )
        )
        Box(
            Modifier
                .fillMaxWidth()
                .height(120.dp)
                .align(Alignment.TopCenter)
                .background(
                    Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.45f), Color.Transparent))
                )
        )

        // Visible feedback while a speed hold is active — without it the change in playback
        // rate is easy to mistake for the app glitching.
        heldSpeed?.let { speed ->
            Box(
                Modifier
                    .align(Alignment.TopCenter)
                    .statusBarsPadding()
                    .padding(top = 16.dp)
                    .clip(CircleShape)
                    .background(Color.Black.copy(alpha = 0.55f))
                    .padding(horizontal = 16.dp, vertical = 6.dp),
            ) {
                Text(
                    if (speed == 2f) "2x" else "0.5x",
                    style = VoiidFont.rounded(15, FontWeight.SemiBold),
                    color = Color.White,
                )
            }
        }

        // Chrome
        Column(Modifier.fillMaxSize().statusBarsPadding()) {
            Row(Modifier.fillMaxWidth().padding(horizontal = 8.dp), verticalAlignment = Alignment.CenterVertically) {
                Box(
                    Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                        .softClickable(scale = 0.9f) { onBack() },
                    contentAlignment = Alignment.Center,
                ) {
                    Icon(
                        if (compact) Icons.Default.KeyboardArrowDown else Icons.Default.ArrowBack,
                        "Back", tint = Color.White, modifier = Modifier.size(26.dp),
                    )
                }
                Spacer(Modifier.weight(1f))
                if (!compact) {
                    // Indicator only — muting is the whole-screen tap gesture, which must not
                    // be duplicated by a second target that shifts under the thumb.
                    Box(Modifier.size(48.dp), contentAlignment = Alignment.Center) {
                        Icon(
                            if (muted) Icons.Default.VolumeOff else Icons.Default.VolumeUp,
                            if (muted) "Muted" else "Sound on",
                            tint = Color.White.copy(alpha = 0.9f),
                            modifier = Modifier.size(20.dp),
                        )
                    }
                }
            }
            Spacer(Modifier.weight(1f))

            Row(
                Modifier.fillMaxWidth().padding(16.dp).alpha(chromeAlpha),
                verticalAlignment = Alignment.Bottom,
            ) {
                Column(
                    Modifier.weight(1f),
                    verticalArrangement = Arrangement.spacedBy(8.dp),
                ) {
                    Row(
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.spacedBy(8.dp),
                        modifier = if (onOpenAuthor != null) {
                            Modifier.softClickable(scale = 0.97f) { onOpenAuthor() }
                        } else Modifier,
                    ) {
                        VoiidAvatar(size = 44.dp)
                        Text(
                            row.authorName,
                            style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = Color.White,
                            maxLines = 1,
                        )
                        // Inline, beside the name, not on a rail: the decision to follow is
                        // made while reading who this is, and it disappears the moment it is
                        // taken rather than becoming a second "Following" state to parse.
                        if (showFollowChip) {
                            // 48dp of tap area around a ~28dp capsule: a chip sized to its
                            // own text would sit well under the minimum target, and a chip
                            // grown to 48 would tower over the name it sits beside.
                            Box(
                                Modifier
                                    .sizeIn(minHeight = 48.dp)
                                    .softClickable(scale = 0.94f) { onFollow() },
                                contentAlignment = Alignment.Center,
                            ) {
                                Box(
                                    Modifier
                                        .clip(CircleShape)
                                        .border(1.dp, Color.White.copy(alpha = 0.85f), CircleShape)
                                        .padding(horizontal = 12.dp, vertical = 5.dp),
                                ) {
                                    Text(
                                        "Follow",
                                        style = VoiidFont.rounded(13, FontWeight.SemiBold),
                                        color = Color.White,
                                    )
                                }
                            }
                        }
                    }
                    if (!compact && !row.caption.isNullOrEmpty()) {
                        Text(
                            row.caption,
                            style = VoiidFont.rounded(14),
                            color = Color.White,
                            maxLines = 3,
                        )
                    }
                }

                if (!compact) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.spacedBy(12.dp),
                    ) {
                        ActionButton(
                            if (row.likedByMe) Icons.Default.Favorite else Icons.Default.FavoriteBorder,
                            ClipCount.compact(row.likeCount),
                            if (row.likedByMe) VoiidColor.error else Color.White,
                            iconScale = likePop.value,
                            contentDescription = if (row.likedByMe) "Unlike" else "Like",
                            onTap = onToggleLike,
                        )
                        ActionButton(
                            Icons.Outlined.ChatBubbleOutline,
                            ClipCount.compact(row.commentCount),
                            Color.White,
                            contentDescription = "Comments",
                            onTap = onOpenComments,
                        )
                        // Views are a READOUT, not a control — no tap, no press feedback.
                        ActionButton(
                            Icons.Default.RemoveRedEye,
                            ClipCount.compact(row.viewCount),
                            Color.White,
                            contentDescription = "Views",
                            onTap = null,
                        )
                    }
                }
            }
        }
    }
}

/**
 * One right-rail action. The frame is 48dp even though the glyph is 26 — these sit at the
 * edge of a moving video where a miss costs the user their place, and the icon alone was
 * well under the minimum target.
 */
@Composable
private fun ActionButton(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: Color,
    contentDescription: String,
    iconScale: Float = 1f,
    onTap: (() -> Unit)?,
) {
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(2.dp),
    ) {
        Box(
            Modifier
                .size(48.dp)
                .then(
                    if (onTap != null) Modifier.softClickable(scale = 0.9f) { onTap() }
                    else Modifier
                ),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon, contentDescription, tint = tint,
                modifier = Modifier.size(26.dp).scale(iconScale),
            )
        }
        Text(label, style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White)
    }
}

@Composable
private fun CommentsPanel(
    clips: ClipsStore,
    clipId: String,
    myUserId: String,
    myName: String,
    modifier: Modifier = Modifier,
    onClose: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    var draft by remember { mutableStateOf("") }
    val rows = clips.commentsByClip[clipId] ?: emptyList()
    val loading = clipId in clips.commentsLoading

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
            Box(
                Modifier.size(48.dp).softClickable(scale = 0.9f) { onClose() },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Default.Close, "Close", tint = VoiidColor.textSecondary,
                    modifier = Modifier.size(20.dp),
                )
            }
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
                            clips.retryComment(clipId, c.id, myUserId, myName)
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
            Box(
                Modifier.size(48.dp).softClickable(scale = 0.9f) {
                    val text = draft.trim()
                    if (text.isNotEmpty()) {
                        haptics.tap()
                        draft = ""
                        clips.addComment(clipId, text, myUserId, myName)
                    }
                },
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.Send, "Send", tint = VoiidColor.primary,
                    modifier = Modifier.size(24.dp),
                )
            }
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
