package com.voiid.app.main.stories

import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBars
import androidx.compose.foundation.layout.windowInsetsTopHeight
import androidx.compose.foundation.lazy.LazyRow
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.StoriesStore
import com.voiid.app.model.StoryContext
import com.voiid.app.model.StoryUploadState
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.components.voiidPullRefresh
import com.voiid.app.ui.components.rememberVoiidPullRefresh
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

/**
 * Stories tab root. Local-first: renders whatever [StoriesStore] holds and refreshes in the
 * background. One home for the feature (the tab), one unread model (the tab's dot) — deliberately
 * NO ring rail above the chat grid.
 *
 * Ordering: "Your story" always first, then unviewed contexts (accent ring), then viewed ones
 * (divider ring) — [StoriesStore] already returns them in that order.
 */
@Composable
fun StoriesHomeView(
    stories: StoriesStore,
    onOpenContext: (Int) -> Unit,
    onCompose: () -> Unit,
) {
    val session: com.voiid.app.model.AppSession = androidx.lifecycle.viewmodel.compose.viewModel()
    var showArchive by androidx.compose.runtime.remember { androidx.compose.runtime.mutableStateOf(false) }
    if (showArchive) StoryArchiveScreen(onClose = { showArchive = false })
    val largeText = LocalDensity.current.fontScale >= 1.5f
    val newContexts = stories.othersContexts.filter { it.hasUnviewed }
    val seenContexts = stories.othersContexts.filter { !it.hasUnviewed }
    val seenColumns = if (largeText) 2 else 4
    val pull = rememberVoiidPullRefresh(refreshing = stories.refreshing) { stories.refresh() }
    LaunchedEffect(Unit) { stories.refresh() }

    Box(Modifier.fillMaxSize().background(VoiidColor.background).voiidPullRefresh(pull, VoiidColor.primary)) {
        LazyColumn(
            Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            contentPadding = PaddingValues(bottom = 104.dp),
        ) {
            item {
                Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
                Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "Moments", style = VoiidFont.rounded(28, FontWeight.Bold), color = VoiidColor.textPrimary,
                    modifier = Modifier.weight(1f).padding(vertical = 12.dp),
                )
                androidx.compose.material3.TextButton(onClick = { showArchive = true }) { Text("Archive", color = VoiidColor.accentInk) }
                }
            }

            // "Your story"
            item {
                val mine = stories.myContext
                StoryRow(
                    name = "Your moment",
                    photoUrl = session.profile.photoURL ?: mine?.photoUrl,
                    subtitle = when {
                        mine == null -> "Add to your moment"
                        mine.newest?.uploadState == StoryUploadState.UPLOADING -> "Posting…"
                        mine.newest?.uploadState == StoryUploadState.FAILED -> "Failed — tap to retry"
                        else -> "${mine.stories.size} ${if (mine.stories.size == 1) "story" else "stories"}"
                    },
                    ringColor = if (mine?.hasUnviewed == true) VoiidColor.primary else VoiidColor.divider,
                    showPlus = true,
                    onClick = {
                        if (mine == null) onCompose()
                        else if (mine.newest?.uploadState == StoryUploadState.FAILED) mine.newest?.let { stories.retry(it) }
                        else onOpenContext(stories.contexts.indexOf(mine).coerceAtLeast(0))
                    },
                )
            }

            if (newContexts.isNotEmpty()) {
                item(key = "new-heading") { MomentHeading("New", newContexts.size) }
                item(key = "new-rail") {
                    LazyRow(horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        items(newContexts, key = { it.authorId }) { ctx ->
                            MomentPreview(ctx, Modifier.width(if (largeText) 164.dp else 118.dp),
                                height = if (largeText) 230.dp else 190.dp, compact = false) {
                                val index = stories.contexts.indexOfFirst { it.authorId == ctx.authorId }
                                if (index >= 0) onOpenContext(index)
                            }
                        }
                    }
                }
            }
            if (seenContexts.isNotEmpty()) {
                item(key = "seen-heading") { MomentHeading("Seen", seenContexts.size) }
                items(seenContexts.chunked(seenColumns), key = { "seen-" + it.first().authorId }) { row ->
                    Row(Modifier.fillMaxWidth().padding(bottom = 6.dp), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                        row.forEach { ctx ->
                            androidx.compose.runtime.key(ctx.authorId) {
                                MomentPreview(ctx, Modifier.weight(1f), height = 152.dp, compact = true) {
                                    val index = stories.contexts.indexOfFirst { it.authorId == ctx.authorId }
                                    if (index >= 0) onOpenContext(index)
                                }
                            }
                        }
                        repeat(seenColumns - row.size) { Spacer(Modifier.weight(1f)) }
                    }
                }
            }

            if (stories.othersContexts.isEmpty() && stories.myContext == null) {
                item { EmptyState() }
            }
        }

        // Compose FAB
        Box(
            Modifier.align(Alignment.BottomEnd).padding(24.dp).size(60.dp).clip(CircleShape)
                .background(VoiidColor.primary).softClickable(scale = 0.9f, onClick = onCompose),
            contentAlignment = Alignment.Center,
        ) { Icon(Icons.Default.Add, "New moment", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(28.dp)) }

        if (stories.posting) {
            Box(Modifier.align(Alignment.TopEnd).padding(20.dp)) {
                CircularProgressIndicator(color = VoiidColor.primary, strokeWidth = 2.dp, modifier = Modifier.size(20.dp))
            }
        }
    }
}

@Composable
private fun StoryRow(
    name: String,
    photoUrl: String?,
    subtitle: String,
    ringColor: Color,
    showPlus: Boolean,
    onClick: () -> Unit,
) {
    Row(
        Modifier.fillMaxWidth().softClickable(scale = 0.98f, onClick = onClick).padding(vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp),
    ) {
        Box(contentAlignment = Alignment.BottomEnd) {
            Box(
                Modifier.size(52.dp).clip(CircleShape).border(2.dp, ringColor, CircleShape).padding(3.dp),
                contentAlignment = Alignment.Center,
            ) {
                ProfileAvatar(photoUrl = photoUrl, name = name, size = 44.dp)
            }
            if (showPlus) {
                Box(
                    Modifier.size(20.dp).clip(CircleShape).background(VoiidColor.primary)
                        .border(2.dp, VoiidColor.background, CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.Add, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(14.dp)) }
            }
        }
        Column(Modifier.weight(1f)) {
            Text(name, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary,
                maxLines = 2, overflow = TextOverflow.Ellipsis)
            if (subtitle.isNotBlank()) {
                Text(subtitle, style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
            }
        }
    }
}

@Composable
private fun EmptyState() {
    Column(
        Modifier.fillMaxWidth().padding(top = 80.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Text("No moments yet", style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text(
            "Share a photo or video that disappears in 24 hours.",
            style = VoiidFont.rounded(14), color = VoiidColor.textSecondary,
        )
    }
}

@Composable
private fun MomentHeading(title: String, count: Int) {
    Row(Modifier.fillMaxWidth().padding(top = 18.dp, bottom = 10.dp),
        horizontalArrangement = Arrangement.SpaceBetween, verticalAlignment = Alignment.CenterVertically) {
        Text(title, style = VoiidFont.rounded(19, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text(count.toString(), style = VoiidFont.rounded(13), color = VoiidColor.textSecondary)
    }
}

/** Voiid UI proportions, with real locally decrypted media and explicit viewer navigation. */
@Composable
private fun MomentPreview(context: StoryContext, modifier: Modifier, height: Dp, compact: Boolean, onClick: () -> Unit) {
    val cover = context.stories.getOrNull(context.startIndex)
    val thumbnail = rememberStoryThumbnail(cover?.localPath, cover?.isVideo == true, 360, 570)
    val shape = RoundedCornerShape(14.dp)
    val age = context.newest?.let { relativeTime(it.createdAt) }.orEmpty()
    val state = if (context.hasUnviewed) "unseen" else "seen"
    Box(modifier.height(height).clip(shape)
        .background(Brush.verticalGradient(listOf(VoiidColor.primary, Color(0xFF182124), Color.Black)))
        .border(if (context.hasUnviewed) 2.dp else 1.dp, if (context.hasUnviewed) VoiidColor.primary else VoiidColor.divider, shape)
        .semantics(mergeDescendants = true) { contentDescription = "${context.authorName}, ${context.stories.size} updates, $age, $state" }
        .softClickable(scale = 0.97f, onClick = onClick)) {
        if (thumbnail != null) Image(thumbnail, null, Modifier.fillMaxSize(), contentScale = ContentScale.Crop)
        Box(Modifier.fillMaxSize().background(Brush.verticalGradient(listOf(Color.Black.copy(alpha = 0.4f), Color.Transparent, Color.Black.copy(alpha = 0.92f)))))
        StorySegmentProgress(context.stories.size, if (context.hasUnviewed) context.startIndex else context.stories.size,
            0f, Modifier.align(Alignment.TopCenter).padding(top = 8.dp))
        Column(Modifier.align(Alignment.BottomStart).padding(horizontal = if (compact) 7.dp else 10.dp,
            vertical = if (compact) 8.dp else 10.dp)) {
            Text(context.authorName, style = VoiidFont.rounded(if (compact) 12 else 14, FontWeight.SemiBold),
                color = Color.White, maxLines = 2, overflow = TextOverflow.Ellipsis)
            Text(age, style = VoiidFont.rounded(if (compact) 10 else 11),
                color = Color.White.copy(alpha = 0.86f), maxLines = 1)
        }
    }
}
