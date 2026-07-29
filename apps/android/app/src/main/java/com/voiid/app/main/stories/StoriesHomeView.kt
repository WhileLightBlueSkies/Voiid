package com.voiid.app.main.stories

import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
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
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.main.ProfileAvatar
import com.voiid.app.model.StoriesStore
import com.voiid.app.model.StoryContext
import com.voiid.app.model.StoryUploadState
import com.voiid.app.ui.components.softClickable
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
    LaunchedEffect(Unit) { stories.refresh() }

    Box(Modifier.fillMaxSize().background(VoiidColor.background)) {
        LazyColumn(
            Modifier.fillMaxSize().padding(horizontal = 16.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
        ) {
            item {
                Spacer(Modifier.windowInsetsTopHeight(WindowInsets.statusBars))
                Text(
                    "Moments", style = VoiidFont.rounded(28, FontWeight.Bold), color = VoiidColor.textPrimary,
                    modifier = Modifier.padding(vertical = 12.dp),
                )
            }

            // "Your story"
            item {
                val mine = stories.myContext
                StoryRow(
                    name = "Your moment",
                    photoUrl = mine?.photoUrl,
                    subtitle = when {
                        mine == null -> "Add to your story"
                        mine.newest?.uploadState == StoryUploadState.UPLOADING -> "Posting…"
                        mine.newest?.uploadState == StoryUploadState.FAILED -> "Failed — tap to retry"
                        else -> "${mine.stories.size} ${if (mine.stories.size == 1) "story" else "stories"}"
                    },
                    ringColor = if (mine?.hasUnviewed == true) VoiidColor.primary else VoiidColor.divider,
                    showPlus = true,
                    onClick = {
                        if (mine == null) onCompose()
                        else onOpenContext(stories.contexts.indexOf(mine).coerceAtLeast(0))
                    },
                )
            }

            items(stories.othersContexts, key = { it.authorId }) { ctx ->
                StoryRow(
                    name = ctx.authorName,
                    photoUrl = ctx.photoUrl,
                    subtitle = ctx.newest?.let { relativeTime(it.createdAt) } ?: "",
                    ringColor = if (ctx.hasUnviewed) VoiidColor.primary else VoiidColor.divider,
                    showPlus = false,
                    onClick = { onOpenContext(stories.contexts.indexOf(ctx).coerceAtLeast(0)) },
                )
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
        ) { Icon(Icons.Default.Add, "New story", tint = VoiidColor.textOnPrimary, modifier = Modifier.size(28.dp)) }

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
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        Box(contentAlignment = Alignment.BottomEnd) {
            Box(
                Modifier.size(60.dp).clip(CircleShape).border(2.5.dp, ringColor, CircleShape).padding(3.dp),
                contentAlignment = Alignment.Center,
            ) {
                ProfileAvatar(photoUrl = photoUrl, name = name, size = 52.dp)
            }
            if (showPlus) {
                Box(
                    Modifier.size(22.dp).clip(CircleShape).background(VoiidColor.primary)
                        .border(2.dp, VoiidColor.background, CircleShape),
                    contentAlignment = Alignment.Center,
                ) { Icon(Icons.Default.Add, null, tint = VoiidColor.textOnPrimary, modifier = Modifier.size(14.dp)) }
            }
        }
        Column(Modifier.weight(1f)) {
            Text(name, style = VoiidFont.rounded(16, FontWeight.SemiBold), color = VoiidColor.textPrimary)
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
