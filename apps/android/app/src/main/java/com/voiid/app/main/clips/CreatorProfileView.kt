package com.voiid.app.main.clips

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipCount
import com.voiid.app.model.CreatorStore
import com.voiid.app.net.CreatorService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * A creator's public page: header, follow button, and their grid of clips.
 * Mirrors iOS `CreatorProfileView.swift`.
 *
 * The grid is the SAME 3-column, 2dp-gutter, 9:16 layout as the Explore feed and My Clips,
 * reusing [ClipThumbnail]. That is deliberate and not up for redesign — it is the layout the
 * rest of Clips already uses, and a creator page that scrolled differently from the feed it
 * is reached from would read as a different app.
 *
 * ── NOT E2EE, AND A FOLLOW IS NOT A MESSAGING RIGHT ──────────────────────────────
 * Everything on this screen is public broadcast content. The Follow button grants the ability
 * to see clips that are already public to everyone and nothing else — it opens no
 * conversation, and there is deliberately no "Message" affordance here.
 */
@Composable
fun CreatorProfileView(
    handle: String,
    creators: CreatorStore,
    onBack: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val gridState = rememberLazyGridState()
    val profile = creators.cachedProfile(handle)
    val rows = creators.clipsFor(handle)

    LaunchedEffect(handle) {
        // Only fetch if not already cached — arriving from a feed tile usually means it is.
        if (creators.cachedProfile(handle) == null) creators.loadProfile(handle)
        if (creators.clipsFor(handle).isEmpty()) creators.refreshClips(handle)
    }

    // Page as the grid nears its end. Driven off the last visible index rather than a
    // per-item callback so a fast fling triggers one append, not thirty.
    LaunchedEffect(gridState, handle) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { creators.loadMoreClipsIfNeeded(handle, it) }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack, "Back", tint = VoiidColor.textPrimary,
                modifier = Modifier.size(24.dp).softClickable(scale = 0.9f) {
                    haptics.tap(); onBack()
                },
            )
            Spacer(Modifier.width(VoiidSpacing.md))
            Text(
                "@${profile?.handle ?: handle}",
                style = VoiidFont.rounded(17, FontWeight.SemiBold),
                color = VoiidColor.textPrimary,
            )
        }

        val slot = Modifier.fillMaxWidth().weight(1f)
        when {
            // The error state must win over the empty state: rendering "no clips yet" for a
            // failed request is a lie about someone else's page.
            profile == null && creators.profileError != null ->
                ClipsEmptyState(
                    kind = ClipsEmptyKind.Failed(creators.profileError!!),
                    onAction = { creators.loadProfile(handle) },
                    modifier = slot,
                )

            profile == null ->
                Box(slot, contentAlignment = Alignment.Center) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                }

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                state = gridState,
                modifier = slot,
                verticalArrangement = Arrangement.spacedBy(2.dp),
                horizontalArrangement = Arrangement.spacedBy(2.dp),
            ) {
                item(span = { GridItemSpan(3) }) {
                    ProfileHeader(profile, creators, haptics)
                }
                if (rows.isEmpty()) {
                    item(span = { GridItemSpan(3) }) {
                        Text(
                            if (profile.is_self) "You haven't posted a clip yet."
                            else "No clips yet.",
                            style = VoiidFont.rounded(15),
                            color = VoiidColor.textSecondary,
                            modifier = Modifier.fillMaxWidth().padding(top = 40.dp),
                        )
                    }
                }
                items(rows, key = { it.id }) { clip -> CreatorClipTile(clip) }
                item(span = { GridItemSpan(3) }) { Spacer(Modifier.height(100.dp)) }
            }
        }
    }
}

@Composable
private fun ProfileHeader(
    p: CreatorService.Profile,
    creators: CreatorStore,
    haptics: com.voiid.app.ui.components.VoiidHaptics,
) {
    Column(
        Modifier.fillMaxWidth().padding(VoiidSpacing.md),
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            // ClipThumbnail already handles async load, failure and shimmer; a creator
            // avatar is the same problem (a presigned URL that may expire or 404).
            if (p.avatar_url != null) {
                ClipThumbnail(
                    url = p.avatar_url,
                    modifier = Modifier.size(84.dp).clip(CircleShape),
                )
            } else {
                Box(
                    Modifier.size(84.dp).clip(CircleShape).background(VoiidColor.fieldFill),
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        p.handle.take(1).uppercase(),
                        style = VoiidFont.rounded(32, FontWeight.SemiBold),
                        color = VoiidColor.textSecondary,
                    )
                }
            }
            // Counts sit beside the avatar rather than under the bio so the numbers stay
            // above the fold on a small phone.
            Row(Modifier.weight(1f).padding(start = VoiidSpacing.md)) {
                Stat(ClipCount.compact(p.clip_count), "Clips", Modifier.weight(1f))
                Stat(ClipCount.compact(p.follower_count), "Followers", Modifier.weight(1f))
                Stat(ClipCount.compact(p.following_count), "Following", Modifier.weight(1f))
            }
        }

        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    p.display_name ?: "@${p.handle}",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = VoiidColor.textPrimary,
                )
                if (p.is_verified) {
                    Spacer(Modifier.width(4.dp))
                    Icon(Icons.Filled.Verified, null,
                        tint = VoiidColor.primary, modifier = Modifier.size(14.dp))
                }
            }
            if (p.display_name != null) {
                Text("@${p.handle}", style = VoiidFont.rounded(13),
                    color = VoiidColor.textSecondary)
            }
            p.bio?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = VoiidFont.rounded(15), color = VoiidColor.textPrimary)
            }
            p.link_url?.takeIf { it.isNotEmpty() }?.let {
                Text(it, style = VoiidFont.rounded(13), color = VoiidColor.primary, maxLines = 1)
            }
        }

        // Your own page shows nothing to follow; everyone else's shows Follow. There is
        // deliberately no Message button — see the header note.
        if (!p.is_self) {
            Box(
                Modifier
                    .fillMaxWidth()
                    .height(44.dp)
                    .clip(RoundedCornerShape(VoiidRadius.md))
                    .background(if (p.following) VoiidColor.fieldFill else VoiidColor.primary)
                    .softClickable(scale = 0.98f) {
                        haptics.tap()
                        creators.toggleFollow(p.handle)
                    },
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    if (p.following) "Following" else "Follow",
                    style = VoiidFont.rounded(17, FontWeight.SemiBold),
                    color = if (p.following) VoiidColor.textPrimary else VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

@Composable
private fun Stat(value: String, label: String, modifier: Modifier = Modifier) {
    Column(modifier, horizontalAlignment = Alignment.CenterHorizontally) {
        Text(value, style = VoiidFont.rounded(17, FontWeight.Bold), color = VoiidColor.textPrimary)
        Text(label, style = VoiidFont.rounded(12), color = VoiidColor.textSecondary)
    }
}

@Composable
private fun CreatorClipTile(clip: CreatorService.CreatorClipRow) {
    Box(Modifier.aspectRatio(9f / 16f)) {
        ClipThumbnail(url = clip.thumb_url, modifier = Modifier.fillMaxSize())
        Box(
            Modifier
                .fillMaxSize()
                .background(
                    Brush.verticalGradient(
                        0.5f to Color.Transparent,
                        1f to Color.Black.copy(alpha = 0.55f),
                    )
                )
        )
        Row(
            Modifier.align(Alignment.BottomStart).padding(6.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(3.dp),
        ) {
            Icon(Icons.Filled.Visibility, null, tint = Color.White, modifier = Modifier.size(10.dp))
            Text(
                ClipCount.compact(clip.view_count),
                style = VoiidFont.rounded(11, FontWeight.SemiBold),
                color = Color.White,
            )
        }
    }
}
