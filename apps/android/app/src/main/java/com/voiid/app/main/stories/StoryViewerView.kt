package com.voiid.app.main.stories

import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.navigationBarsPadding
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.text.font.FontWeight
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
import kotlinx.coroutines.launch

private const val IMAGE_DURATION_MS = 5_000L
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

    Box(Modifier.fillMaxSize().background(Color.Black)) {
        HorizontalPager(state = pagerState, modifier = Modifier.fillMaxSize()) { page ->
            ContextPage(
                context = contexts[page],
                active = page == pagerState.currentPage,
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

@Composable
private fun ContextPage(
    context: StoryContext,
    active: Boolean,
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

    val story = context.stories.getOrNull(index) ?: return

    // Download the current story (and prefetch ONLY the immediate next).
    LaunchedEffect(context.authorId, index, active) {
        if (!active) return@LaunchedEffect
        progress = 0f
        loadState = StoryDownloadState.DOWNLOADING
        localPath = stories.ensureDownloaded(story)
        loadState = if (localPath != null) StoryDownloadState.READY else StoryDownloadState.GONE
        context.stories.getOrNull(index + 1)?.let { next -> launch { stories.ensureDownloaded(next) } }
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
            .pointerInput(context.authorId, index) {
                detectTapGestures(
                    onPress = {
                        paused = true; chromeVisible = false
                        tryAwaitRelease()
                        paused = false; chromeVisible = true
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
            },
    ) {
        // Media
        val p = localPath
        when {
            loadState == StoryDownloadState.READY && p != null ->
                StoryMediaFrame(localPath = p, isVideo = story.isVideo, paused = paused, muted = muted)
            loadState == StoryDownloadState.GONE ->
                CenterMessage(if (story.downloadState == StoryDownloadState.GONE) "This story is no longer available" else "This story couldn't be loaded")
            else -> Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                CircularProgressIndicator(color = Color.White)
            }
        }

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
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                        Box(Modifier.weight(1f)) {
                            VoiidTextField(
                                placeholder = "Reply to ${context.authorName}…",
                                value = replyText, onValueChange = { replyText = it },
                            )
                        }
                        val canSend = replyText.isNotBlank()
                        Box(
                            Modifier.size(48.dp).clip(CircleShape)
                                .background(if (canSend) VoiidColor.primary else VoiidColor.primary.copy(alpha = 0.4f))
                                .softClickable(enabled = canSend) {
                                    stories.sendReply(story, replyText.trim(), null); onClose()
                                },
                            contentAlignment = Alignment.Center,
                        ) { Text("↑", style = VoiidFont.rounded(20, FontWeight.Bold), color = Color.White) }
                    }
                }
            }
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
