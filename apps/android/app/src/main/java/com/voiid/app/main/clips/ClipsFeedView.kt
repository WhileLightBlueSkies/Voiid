package com.voiid.app.main.clips

import androidx.compose.foundation.layout.PaddingValues

import androidx.compose.material.icons.filled.Apps
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.foundation.border
import androidx.compose.material.icons.filled.Add
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
import androidx.compose.foundation.layout.sizeIn
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.GridItemSpan
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.GridView
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipCount
import com.voiid.app.model.ClipUploadState
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.net.SocialService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.components.voiidPullRefresh
import com.voiid.app.ui.components.rememberVoiidPullRefresh
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius

/**
 * The Clips grid — a dense 3-column Instagram/Explore-style grid of cover frames.
 * Port of iOS `ClipsFeedView.swift`.
 *
 * Replaces the old vertical card list (one clip per screen-width card), which showed
 * ~1.5 clips per screen and made browsing feel empty. The grid is thumbnails only:
 * tapping one opens the fullscreen pager at that index.
 */
@Composable
fun ClipsFeedView(
    clips: ClipsStore,
    creators: com.voiid.app.model.SocialStore,
    onOpenClip: (Int) -> Unit,
    onOpenFollowingClip: (Int) -> Unit,
    onNewClip: () -> Unit,
    onMyClips: () -> Unit,
    onOpenCreator: (String) -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val gridState = rememberLazyGridState()
    val followingState = rememberLazyGridState()

    /**
     * Which feed the grid is showing. Following is a separate SOURCE, not a filter over
     * Explore — it is its own endpoint with its own cursor, so mixing them into one list
     * would break keyset pagination.
     */
    var followingScope by androidx.compose.runtime.saveable.rememberSaveable {
        androidx.compose.runtime.mutableStateOf(false)
    }

    val pull = rememberVoiidPullRefresh {
        clips.refresh()
        creators.refreshFollowing()
    }
    LaunchedEffect(Unit) {
        if (!clips.hasLoadedOnce) clips.refresh()
        creators.ensureMeLoaded()
    }

    // Loaded on first switch only; afterwards the cached page is reused so toggling back and
    // forth is instant rather than a round-trip each way.
    LaunchedEffect(followingScope) {
        if (followingScope && !creators.followingLoadedOnce) creators.refreshFollowing()
    }

    LaunchedEffect(followingState) {
        snapshotFlow { followingState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { creators.loadMoreFollowingIfNeeded(it) }
    }

    // Page as the grid nears its end. Driven off the last visible index rather than a
    // per-item callback so a fast fling triggers one append, not thirty.
    LaunchedEffect(gridState) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { clips.loadMoreIfNeeded(it) }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        // iOS ClipsFeedView `topBar`: NO title. One row — the Explore/Following switch in a
        // single recessed track, then the floating cluster: My clips, New clip (38 circles
        // with a hairline) and your creator avatar once a profile exists.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp).padding(top = 4.dp, bottom = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(
                Modifier.clip(RoundedCornerShape(VoiidRadius.pill)).background(VoiidColor.fieldFill)
                    .border(1.dp, VoiidColor.divider, RoundedCornerShape(VoiidRadius.pill))
                    .padding(horizontal = 3.dp, vertical = 3.dp),
            ) {
                listOf(false to "Explore", true to "Following").forEach { (following, label) ->
                    val selected = followingScope == following
                    Box(
                        Modifier.height(38.dp).clip(RoundedCornerShape(VoiidRadius.pill))
                            .background(if (selected) VoiidColor.primary else androidx.compose.ui.graphics.Color.Transparent)
                            .softClickable(scale = 0.96f) { haptics.selection(); followingScope = following }
                            .padding(horizontal = 18.dp),
                        contentAlignment = Alignment.Center,
                    ) {
                        Text(label, style = VoiidFont.rounded(15, FontWeight.SemiBold),
                            color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary)
                    }
                }
            }
            Spacer(Modifier.weight(1f))
            ClipFloatingButton(Icons.Default.Apps, "My clips") { haptics.tap(); onMyClips() }   // iOS square.grid.3x3
            ClipFloatingButton(Icons.Default.Add, "New clip") { haptics.tap(); onNewClip() }
            creators.me?.let { mine ->
                Box(
                    Modifier.size(44.dp).softClickable(scale = 0.9f) { haptics.tap(); onOpenCreator(mine.handle) },
                    contentAlignment = Alignment.Center,
                ) {
                    // iOS: 38 avatar, 2pt accent ring 3pt outside it.
                    Box(Modifier.size(44.dp).border(2.dp, VoiidColor.accent, CircleShape), contentAlignment = Alignment.Center) {
                        MyCreatorAvatar(mine, 38.dp)
                    }
                }
            }
        }

        val error = clips.loadError
        // Every branch takes the same weighted slot: this Column's other child is the
        // header, so a child without weight would size to its intrinsic height and the
        // skeleton's fillMaxSize would resolve against an unbounded constraint.
        // The pull moves the grid only; the top bar stays fixed, as it sits outside the
        // ScrollView on iOS.
        val slot = Modifier.fillMaxWidth().weight(1f).voiidPullRefresh(pull, VoiidColor.primary)
        if (followingScope) {
            FollowingFeed(
                creators = creators,
                gridState = followingState,
                modifier = slot,
                onOpenClip = onOpenFollowingClip,
                onExplore = { haptics.tap(); followingScope = false },
            )
            return@Column
        }
        val entrance = rememberGridEntrance(ready = clips.clips.isNotEmpty())
        when {
            // Order matters: the error state must win over the empty state. Rendering
            // "No clips yet" for a failed request tells the user the feature is dead.
            error != null && clips.clips.isEmpty() ->
                ClipsEmptyState(
                    kind = ClipsEmptyKind.Failed(error),
                    onAction = { clips.refresh() },
                    modifier = slot,
                )

            clips.loading && clips.clips.isEmpty() -> ClipsGridSkeleton(modifier = slot)

            clips.clips.isEmpty() && clips.hasLoadedOnce ->
                ClipsEmptyState(
                    kind = ClipsEmptyKind.NoClips,
                    onAction = { haptics.tap(); onNewClip() },
                    modifier = slot,
                )

            else -> LazyVerticalGrid(
                columns = GridCells.Fixed(3),
                state = gridState,
                modifier = Modifier.fillMaxWidth().weight(1f),
                contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
                verticalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                itemsIndexed(clips.clips, key = { _, c -> c.id }) { index, clip ->
                    ClipTile(
                        clip = clip,
                        modifier = Modifier.clipTileEntrance(index, entrance),
                        onTap = {
                            // A still-uploading tile has no server row to play yet.
                            if (clip.uploadState == ClipUploadState.None) {
                                haptics.tap()
                                onOpenClip(index)
                            }
                        },
                        onRetry = if (clips.canRetryUpload(clip.id)) {
                            { haptics.tap(); clips.retryUpload(clip.id) }
                        } else null,
                        onDiscard = { clips.discardFailedUpload(clip.id) },
                    )
                }
                if (clips.loadingMore) {
                    item(span = { GridItemSpan(maxLineSpan) }) {
                        Box(
                            Modifier.fillMaxWidth().padding(24.dp),
                            contentAlignment = Alignment.Center,
                        ) { CircularProgressIndicator(color = VoiidColor.primary) }
                    }
                }
                // Clears the floating tab bar.
                item(span = { GridItemSpan(maxLineSpan) }) { Spacer(Modifier.height(100.dp)) }
            }
        }
    }
}

/** A header action in a 48dp frame — the glyph alone was well under the minimum target. */
@Composable
private fun HeaderIcon(
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    label: String,
    tint: Color = VoiidColor.textPrimary,
    size: androidx.compose.ui.unit.Dp = 24.dp,
    onClick: () -> Unit,
) {
    Box(
        Modifier.size(48.dp).softClickable(scale = 0.9f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Icon(icon, label, tint = tint, modifier = Modifier.size(size))
    }
}

/** 28dp circle: the real avatar when there is one, the handle's initial when there is not. */
@Composable
private fun MyCreatorAvatar(me: SocialService.Profile, size: androidx.compose.ui.unit.Dp = 28.dp) {
    if (me.avatar_url != null) {
        ClipThumbnail(
            url = me.avatar_url,
            modifier = Modifier.size(size).clip(CircleShape),
        )
    } else {
        Box(
            Modifier.size(size).clip(CircleShape).background(VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                me.handle.take(1).uppercase(),
                style = VoiidFont.rounded(13, FontWeight.SemiBold),
                color = VoiidColor.textSecondary,
            )
        }
    }
}

@Composable
private fun ClipTile(
    clip: VClip,
    modifier: Modifier = Modifier,
    onTap: () -> Unit,
    onRetry: (() -> Unit)? = null,
    onDiscard: (() -> Unit)? = null,
    onCreator: (() -> Unit)? = null,
) {
    ClipCard(
        clipId = clip.id,
        thumbUrl = clip.thumbUrl,
        localThumbPath = clip.localThumbPath,
        viewCount = clip.viewCount,
        durationMs = clip.durationMs,
        handle = clip.authorHandle,
        authorName = clip.authorName,
        authorPhotoUrl = clip.authorPhotoUrl,
        verified = clip.authorVerified,
        modifier = modifier,
        showMeta = clip.uploadState == ClipUploadState.None,
        onOpen = onTap,
        onCreator = onCreator,
    ) {
        when (val state = clip.uploadState) {
            is ClipUploadState.Uploading -> Box(
                Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.45f)),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(6.dp),
                ) {
                    LinearProgressIndicator(
                        progress = { state.progress },
                        modifier = Modifier.width(56.dp),
                        color = VoiidColor.primary,
                    )
                    Text(
                        if (state.processing) "Preparing" else "Uploading ${(state.progress * 100).toInt()}%",
                        style = VoiidFont.rounded(10, FontWeight.Medium),
                        color = Color.White,
                    )
                }
            }

            is ClipUploadState.Failed -> Box(
                Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.55f)),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(2.dp),
                ) {
                    Icon(
                        Icons.Default.WarningAmber, null,
                        tint = VoiidColor.error, modifier = Modifier.size(16.dp),
                    )
                    Text(
                        "Upload failed",
                        style = VoiidFont.rounded(10, FontWeight.SemiBold),
                        color = Color.White,
                    )
                    // This tile previously offered NOTHING — a failed upload was a dead
                    // square with no way to retry it and no way to clear it. Retry comes
                    // first: the video has already cost the user an export.
                    //
                    // Both targets are 48dp tall even though the tile is only a third of
                    // the screen wide. This is the ONE tile where a mis-tap throws away a
                    // video the user has already waited through an export for, so the
                    // targets overlap the tile's own tap area rather than being sized to
                    // the text that labels them.
                    if (onRetry != null) {
                        Box(
                            Modifier
                                .sizeIn(minWidth = 64.dp, minHeight = 48.dp)
                                .padding(top = 2.dp)
                                .clip(CircleShape)
                                .background(VoiidColor.fieldFill)
                                .softClickable(scale = 0.92f, onClick = onRetry),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "Retry",
                                style = VoiidFont.rounded(12, FontWeight.SemiBold),
                                color = VoiidColor.textPrimary,
                            )
                        }
                    }
                    if (onDiscard != null) {
                        Box(
                            Modifier
                                .sizeIn(minWidth = 64.dp, minHeight = 48.dp)
                                .softClickable(scale = 0.92f, onClick = onDiscard),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                "Dismiss",
                                style = VoiidFont.rounded(12),
                                color = Color.White.copy(alpha = 0.75f),
                            )
                        }
                    }
                }
            }

            ClipUploadState.None -> Unit
        }
    }
}

/** One of the two feed-scope pills. Filled when selected, quiet when not. */
/** iOS `floatingButton`: 38 circle, material fill + hairline, 15 semibold glyph, 44 target. */
@Composable
private fun ClipFloatingButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).softClickable(scale = 0.9f, onClick = onClick)
        .semantics { contentDescription = label }, contentAlignment = Alignment.Center) {
        Box(Modifier.size(38.dp).clip(CircleShape).background(VoiidColor.fieldFill)
            .border(0.5.dp, VoiidColor.divider, CircleShape), contentAlignment = Alignment.Center) {
            Icon(icon, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(17.dp))
        }
    }
}

@Composable
private fun ScopePill(label: String, selected: Boolean, onClick: () -> Unit) {
    // The PILL is unchanged — this is the treatment iOS is being aligned TO. What is new is
    // the frame around it: the tap area is 48dp tall while the drawn capsule stays ~34dp, so
    // the control meets the minimum target without growing into a slab.
    Box(
        Modifier
            .sizeIn(minHeight = 48.dp)
            .softClickable(scale = 0.96f, onClick = onClick),
        contentAlignment = Alignment.Center,
    ) {
        Box(
            Modifier
                .clip(RoundedCornerShape(VoiidRadius.pill))
                .background(if (selected) VoiidColor.primary else VoiidColor.fieldFill)
                .padding(horizontal = 16.dp, vertical = 7.dp),
        ) {
            Text(
                label,
                style = VoiidFont.rounded(14, FontWeight.SemiBold),
                color = if (selected) VoiidColor.textOnPrimary else VoiidColor.textSecondary,
            )
        }
    }
}

/**
 * Clips from creators you follow. Its empty state is distinct from Explore's on purpose:
 * "you don't follow anyone yet" is a different problem from "there are no clips", and
 * offering "post a clip" here would be a non-sequitur.
 */
@Composable
private fun FollowingFeed(
    creators: com.voiid.app.model.SocialStore,
    gridState: androidx.compose.foundation.lazy.grid.LazyGridState,
    modifier: Modifier,
    onOpenClip: (Int) -> Unit,
    onExplore: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val rows = creators.following
    val error = creators.followingError
    val entrance = rememberGridEntrance(ready = rows.isNotEmpty())

    when {
        error != null && rows.isEmpty() ->
            ClipsEmptyState(
                kind = ClipsEmptyKind.Failed(error),
                onAction = { creators.refreshFollowing() },
                modifier = modifier,
            )

        creators.followingLoading && rows.isEmpty() -> ClipsGridSkeleton(modifier = modifier)

        rows.isEmpty() && creators.followingLoadedOnce ->
            ClipsEmptyState(
                kind = ClipsEmptyKind.FollowingNobody,
                onAction = onExplore,
                modifier = modifier,
            )

        else -> LazyVerticalGrid(
            columns = GridCells.Fixed(3),
            state = gridState,
            modifier = modifier,
            contentPadding = PaddingValues(start = 16.dp, end = 16.dp, top = 4.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            itemsIndexed(rows, key = { _, c -> c.id }) { index, clip ->
                // The same iOS ClipTile card as Explore. Opens the CLIP (the pager takes this
                // feed's own rows); the handle row opens the creator.
                ClipCard(
                    clipId = clip.id,
                    thumbUrl = clip.thumb_url,
                    viewCount = clip.view_count,
                    durationMs = clip.duration_ms,
                    handle = clip.author_handle,
                    authorName = clip.author_display_name ?: clip.author_handle ?: "",
                    authorPhotoUrl = null,
                    verified = clip.author_verified,
                    modifier = Modifier.clipTileEntrance(index, entrance),
                    onOpen = { haptics.tap(); onOpenClip(index) },
                )
            }
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(3) }) {
                Spacer(Modifier.height(100.dp))
            }
        }
    }
}
