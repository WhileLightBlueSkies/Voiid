package com.voiid.app.main.stories

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
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
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.pager.HorizontalPager
import androidx.compose.foundation.pager.rememberPagerState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.VolumeOff
import androidx.compose.material.icons.filled.VolumeUp
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalConfiguration
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.StoriesStore
import com.voiid.app.model.Story
import com.voiid.app.model.StoryContext
import com.voiid.app.model.StoryDownloadState
import com.voiid.app.ui.components.VoiidTextField
import com.voiid.app.ui.components.bouncyClickable
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlin.math.roundToInt

private const val IMAGE_DURATION_MS = 5_000L
/** Fraction of the page height a downward drag must pass to dismiss instead of springing back. */
private const val DISMISS_FRACTION = 0.18f
private val QUICK_REACTIONS = listOf("❤️", "😂", "😮", "😢", "👏", "🔥")

/**
 * Full-screen story viewer — two nested pagers (Signal's structure, our idioms; no code copied,
 * Signal is AGPLv3). The OUTER [HorizontalPager] pages between contexts (one page per author); the
 * INNER stepper walks that author's posts on tap + an auto-advancing 30 Hz timer. Segment progress
 * is driven by the timer float, not animation interpolation, so pause/resume is exact.
 */
@Composable
fun StoryViewerView(
    contexts: List<StoryContext>,
    startContextIndex: Int,
    stories: StoriesStore,
    onClose: () -> Unit,
) {
    if (contexts.isEmpty()) { onClose(); return }
    val pagerState = rememberPagerState(initialPage = startContextIndex.coerceIn(0, contexts.size - 1)) { contexts.size }
    val scope = rememberCoroutineScope()
    // Mute preference remembered for the session.
    var muted by remember { mutableStateOf(true) }

    // Full-screen frames are the largest bitmaps the app holds; nothing outside the viewer wants
    // them at that size, so hand the heap back on the way out.
    DisposableEffect(Unit) { onDispose { clearStoryFrameCache() } }

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            ContextPage(
                context = contexts[page],
                active = page == pagerState.currentPage,
                // Where the FOLLOWING author's page will actually open, so this page's prefetch
                // window can spill across the boundary. Without it every sideways swipe between
                // people was a guaranteed cold start on a black frame.
                nextContextStories = headOfNextContext(contexts, page),
                stories = stories,
                muted = muted,
                onToggleMute = { muted = !muted },
                onNextContext = {
                    if (page < contexts.size - 1) scope.launch { pagerState.animateScrollToPage(page + 1) } else onClose()
                },
                onPrevContext = {
                    if (page > 0) scope.launch { pagerState.animateScrollToPage(page - 1) }
                },
                onClose = onClose,
            )
        }
    }
}

/**
 * The stories the author after [page] would show first — from THEIR resume point, since a context
 * page opens at [StoryContext.startIndex], not at zero.
 */
private fun headOfNextContext(contexts: List<StoryContext>, page: Int): List<Story> {
    val next = contexts.getOrNull(page + 1) ?: return emptyList()
    return next.stories.drop(next.startIndex).take(StoriesStore.PREFETCH_DEPTH)
}

@Composable
private fun ContextPage(
    context: StoryContext,
    active: Boolean,
    nextContextStories: List<Story>,
    stories: StoriesStore,
    muted: Boolean,
    onToggleMute: () -> Unit,
    onNextContext: () -> Unit,
    onPrevContext: () -> Unit,
    onClose: () -> Unit,
) {
    var index by remember(context.authorId) { mutableIntStateOf(context.startIndex) }
    var progress by remember { mutableFloatStateOf(0f) }
    var paused by remember { mutableStateOf(false) }
    var localPath by remember(context.authorId, index) { mutableStateOf<String?>(null) }
    var loadState by remember(context.authorId, index) { mutableStateOf(StoryDownloadState.NONE) }
    var showViewers by remember { mutableStateOf(false) }
    var chromeVisible by remember { mutableStateOf(true) }
    var replyText by remember(index) { mutableStateOf("") }
    var showReplySheet by remember(index) { mutableStateOf(false) }
    var sentToast by remember(index) { mutableStateOf(false) }
    var dragY by remember { mutableFloatStateOf(0f) }
    var dragging by remember { mutableStateOf(false) }

    val story = context.stories.getOrNull(index) ?: return

    // Download the current story. This one stays on the PAGE's scope on purpose — its result
    // writes this page's state, so a page the pager recycles should take it down with it.
    LaunchedEffect(context.authorId, index, active) {
        if (!active) return@LaunchedEffect
        progress = 0f
        loadState = StoryDownloadState.DOWNLOADING
        localPath = stories.ensureDownloaded(story)
        loadState = if (localPath != null) StoryDownloadState.READY else StoryDownloadState.GONE
    }

    val configuration = LocalConfiguration.current
    val density = LocalDensity.current
    val screenW = with(density) { configuration.screenWidthDp.dp.roundToPx() }
    val screenH = with(density) { configuration.screenHeightDp.dp.roundToPx() }

    // Prefetch: three deep, spilling into the next author once this context is nearly done.
    // Handed to the STORE so it survives the index change that fires the next one — this
    // LaunchedEffect is cancelled on every step, and that cancellation is exactly what used to
    // kill each warm before it landed.
    LaunchedEffect(context.authorId, index, active, nextContextStories) {
        if (!active) return@LaunchedEffect
        val ahead = context.stories.drop(index + 1).take(StoriesStore.PREFETCH_DEPTH)
        val window = ahead + nextContextStories.take(StoriesStore.PREFETCH_DEPTH - ahead.size)
        stories.prefetch(window) { offset, s, path ->
            warmStoryFrame(path, s.isVideo, screenW, screenH, fullSize = offset == 0)
        }
    }

    // Record "viewed" once the story has actually been on screen (image ≥1s / video reaching 1s).
    // `active` MUST be a key: HorizontalPager pre-composes neighbours, so without it an adjacent
    // (not-yet-shown) page would either fire a receipt for a story never seen, or — once swiped to —
    // never restart and never record the view at all.
    LaunchedEffect(context.authorId, index, active) {
        if (!active) return@LaunchedEffect
        kotlinx.coroutines.delay(1000)
        stories.onViewed(story)
    }

    // The timer: advance `progress` at ~30 Hz while active, ready, and not paused. Do NOT start
    // until the media is downloaded (a spinner shows instead), so the bar never races an empty frame.
    LaunchedEffect(context.authorId, index, active, paused, loadState) {
        if (!active || paused || loadState != StoryDownloadState.READY) return@LaunchedEffect
        val duration = if (story.isVideo) (story.durationMs ?: IMAGE_DURATION_MS).coerceAtMost(30_000L) else IMAGE_DURATION_MS
        val step = 33L
        while (progress < 1f) {
            kotlinx.coroutines.delay(step)
            progress = (progress + step.toFloat() / duration).coerceAtMost(1f)
        }
        // Auto-advance: next story, else next context.
        if (index < context.stories.size - 1) { index += 1 } else onNextContext()
    }

    Box(
        Modifier.fillMaxSize().background(Color.Black)
            .offset { IntOffset(0, dragY.roundToInt()) }
            .pointerInput(context.authorId, index) {
                detectTapGestures(
                    onPress = {
                        // Hold-to-pause must outlive the long-press threshold before it does
                        // anything: pausing on touch-down made every ordinary advance-tap blink
                        // the chrome off and stall the timer for the duration of the touch.
                        coroutineScope {
                            val hold = launch {
                                kotlinx.coroutines.delay(viewConfiguration.longPressTimeoutMillis)
                                paused = true; chromeVisible = false
                            }
                            tryAwaitRelease()
                            hold.cancel()
                        }
                        // A release also arrives when the drag detector takes the pointer over;
                        // resuming there would let the story advance out from under the swipe.
                        if (!dragging) { paused = false; chromeVisible = true }
                    },
                    onTap = { offset ->
                        if (offset.x < size.width / 3f) {
                            // Left third: previous post, or previous context.
                            if (index > 0) { index -= 1 } else onPrevContext()
                        } else {
                            // Right two-thirds: next post, or next context.
                            if (index < context.stories.size - 1) { index += 1 } else onNextContext()
                        }
                    },
                )
            }
            // Swipe down to dismiss, following the finger. Its own pointerInput so the vertical
            // slop is measured independently: a sideways swipe never crosses it, leaving the
            // enclosing HorizontalPager free to take the context change.
            .pointerInput(Unit) {
                detectVerticalDragGestures(
                    onDragStart = { dragging = true; paused = true },
                    onDragEnd = {
                        dragging = false
                        // `size` is read here, not when the block was launched — it is still zero
                        // before the first measure pass.
                        if (dragY > size.height * DISMISS_FRACTION) onClose()
                        else { dragY = 0f; paused = false; chromeVisible = true }
                    },
                    onDragCancel = { dragging = false; dragY = 0f; paused = false; chromeVisible = true },
                ) { _, dragAmount -> dragY = (dragY + dragAmount).coerceAtLeast(0f) }
            },
    ) {
        // Media
        val p = localPath
        when {
            loadState == StoryDownloadState.READY && p != null ->
                StoryMediaFrame(localPath = p, isVideo = story.isVideo, paused = paused, muted = muted)
            loadState == StoryDownloadState.GONE ->
                CenterMessage(if (story.downloadState == StoryDownloadState.GONE) "This moment is no longer available" else "This moment couldn't be loaded")
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White)
            }
        }

        // ── SCRIMS ───────────────────────────────────────────────────────────────────────
        //
        // The progress capsules, author name, timestamp, caption and reply rail are all white
        // drawn straight onto arbitrary user media — over a snow shot or a white wall none of it
        // is readable. Two gradients give the chrome a contrast floor that does not depend on the
        // frame behind it, the same construction Clips uses and the same one Signal and WhatsApp
        // Status use. They fade WITH the chrome: a scrim with nothing on it is just a smudge over
        // the moment the viewer came to look at.
        val chromeAlpha = if (chromeVisible) 1f else 0f
        Box(
            Modifier.fillMaxWidth().height(140.dp).align(Alignment.TopCenter).alpha(chromeAlpha)
                .background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.5f), Color.Transparent))),
        )
        Box(
            Modifier.fillMaxWidth().fillMaxHeight(0.35f).align(Alignment.BottomCenter).alpha(chromeAlpha)
                .background(Brush.verticalGradient(listOf(Color.Transparent, Color.Black.copy(alpha = 0.75f)))),
        )

        // Chrome (progress + header + footer), faded on long-press.
        Column(Modifier.fillMaxSize().alpha(if (chromeVisible) 1f else 0f)) {
            Spacer(Modifier.statusBarsPadding())
            StorySegmentProgress(
                count = context.stories.size, currentIndex = index, progress = progress,
                modifier = Modifier.padding(top = 8.dp),
            )
            // Header
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 10.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(10.dp),
            ) {
                ProfileAvatar(photoUrl = context.photoUrl, name = context.authorName, size = 34.dp)
                Text(context.authorName, style = VoiidFont.rounded(15, FontWeight.SemiBold), color = Color.White)
                Text(relativeTime(story.createdAt), style = VoiidFont.rounded(12), color = Color.White.copy(alpha = 0.7f))
                Spacer(Modifier.weight(1f))
                if (story.isVideo) {
                    Icon(
                        if (muted) Icons.Default.VolumeOff else Icons.Default.VolumeUp, "Mute",
                        tint = Color.White, modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) { onToggleMute() },
                    )
                }
                if (story.isMine) {
                    Spacer(Modifier.size(6.dp))
                    Icon(
                        Icons.Default.Delete, "Delete", tint = Color.White,
                        modifier = Modifier.size(22.dp).softClickable(scale = 0.9f) {
                            stories.delete(story.id); onClose()
                        },
                    )
                } else {
                    Icon(Icons.Default.MoreVert, null, tint = Color.White.copy(alpha = 0.0f), modifier = Modifier.size(1.dp))
                }
            }

            // Caption
            if (story.caption.isNotBlank()) {
                Text(
                    story.caption, style = VoiidFont.rounded(15), color = Color.White,
                    modifier = Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }

            Spacer(Modifier.weight(1f))

            // Footer
            Column(Modifier.fillMaxWidth().navigationBarsPadding().imePadding().padding(16.dp)) {
                if (story.isMine) {
                    val count = stories.viewersByStory[story.id]?.size ?: stories.deliveredCounts[story.id]?.first ?: 0
                    Row(
                        Modifier.fillMaxWidth().clip(RoundedCornerShape(999.dp))
                            .background(Color.White.copy(alpha = 0.15f))
                            .softClickable { stories.loadViewers(story.id); showViewers = true }
                            .padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.Center,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Default.RemoveRedEye, null, tint = Color.White, modifier = Modifier.size(18.dp))
                        Spacer(Modifier.size(8.dp))
                        Text(
                            if (stories.receiptsEnabled) "$count ${if (count == 1) "view" else "views"}" else "Views hidden",
                            style = VoiidFont.rounded(14, FontWeight.SemiBold), color = Color.White,
                        )
                    }
                } else if (story.allowsReplies) {
                    Row(horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        for (emoji in QUICK_REACTIONS) {
                            Text(
                                emoji, style = VoiidFont.rounded(26),
                                modifier = Modifier.bouncyClickable {
                                    stories.sendReply(story, "", emoji); onClose()
                                },
                            )
                        }
                    }
                    Spacer(Modifier.size(10.dp))
                    // The written reply opens in a FIXED 260pt sheet (iOS `.height(260)`),
                    // keeping the story visible behind it — an inline field over the viewer
                    // fought the progress rail for space and covered the caption.
                    Box(
                        Modifier
                            .clip(CircleShape)
                            .background(Color.White.copy(alpha = 0.18f))
                            .softClickable { showReplySheet = true }
                            .padding(horizontal = 16.dp, vertical = 10.dp),
                    ) {
                        Text(
                            "Reply to ${context.authorName}…",
                            style = VoiidFont.rounded(14), color = Color.White,
                        )
                    }
                }
            }
        }
    }

    // Fixed 260pt reply sheet — IME-safe, dismisses after a successful send, and confirms
    // with a toast. iOS `StoryViewerView` reply presentation.
    if (showReplySheet) {
        com.voiid.app.ui.components.VoiidSheet(
            visible = true,
            onDismiss = { showReplySheet = false },
            detents = listOf(com.voiid.app.ui.components.VoiidDetent.Fixed(260.dp)),
        ) {
            Column(Modifier.fillMaxWidth().padding(horizontal = 20.dp).navigationBarsPadding()) {
                Text(
                    "Reply to ${context.authorName}",
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.height(12.dp))
                VoiidTextField(
                    placeholder = "Say something…",
                    value = replyText,
                    onValueChange = { replyText = it },
                )
                Spacer(Modifier.height(12.dp))
                val canSend = replyText.isNotBlank()
                Box(
                    Modifier.fillMaxWidth()
                        .clip(androidx.compose.foundation.shape.RoundedCornerShape(999.dp))
                        .background(VoiidColor.primary.copy(alpha = if (canSend) 1f else 0.4f))
                        .softClickable(enabled = canSend) {
                            stories.sendReply(story, replyText.trim(), null)
                            showReplySheet = false
                            sentToast = true
                            onClose()
                        }
                        .padding(vertical = 14.dp),
                    contentAlignment = Alignment.Center,
                ) {
                    Text("Send", style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textOnPrimary)
                }
                Spacer(Modifier.navigationBarsPadding())
            }
        }
    }

    // Sent confirmation — auto-dismisses; the sheet is already gone by the time it shows.
    androidx.compose.foundation.layout.Box(Modifier.fillMaxSize()) {
    androidx.compose.animation.AnimatedVisibility(
        visible = sentToast,
        enter = androidx.compose.animation.fadeIn(),
        exit = androidx.compose.animation.fadeOut(),
        modifier = Modifier.align(Alignment.TopCenter),
    ) {
        Text(
            "Reply sent",
            style = VoiidFont.rounded(13, FontWeight.SemiBold),
            color = Color.White,
            modifier = Modifier
                .padding(top = 48.dp)
                .clip(androidx.compose.foundation.shape.RoundedCornerShape(999.dp))
                .background(Color.Black.copy(alpha = 0.75f))
                .padding(horizontal = 16.dp, vertical = 8.dp),
        )
    }
    LaunchedEffect(sentToast) {
        if (sentToast) { kotlinx.coroutines.delay(1800); sentToast = false }
    }
    }

    if (showViewers) {
        StoryViewersSheet(
            viewers = stories.viewersByStory[story.id] ?: emptyList(),
            receiptsEnabled = stories.receiptsEnabled,
            deliveredCount = stories.deliveredCounts[story.id]?.first ?: 0,
            onDismiss = { showViewers = false },
        )
    }
}

@Composable
private fun CenterMessage(text: String) {
    Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
        Text(text, style = VoiidFont.rounded(15), color = Color.White.copy(alpha = 0.8f))
    }
}
