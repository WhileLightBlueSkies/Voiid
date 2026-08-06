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
import com.voiid.app.net.CreatorService
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
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
    creators: com.voiid.app.model.CreatorStore,
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
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "Clips",
                style = VoiidFont.display,
                color = VoiidColor.textPrimary,
                modifier = Modifier.padding(start = 8.dp),
            )
            Spacer(Modifier.weight(1f))
            // A GRID glyph, not a film reel: this opens your clips as the same 3-column grid
            // the screen behind it is already showing, and the reel icon read as "video
            // library" — a place to pick footage from.
            HeaderIcon(Icons.Default.GridView, "My clips") { haptics.tap(); onMyClips() }
            // Your own avatar is the identity anchor, the way it is on every other feed the
            // user has ever used; a generic person glyph told them nothing about whose page
            // it opened. Shown only once a creator profile exists — before that there is no
            // page to open, and the handle picker belongs to the compose flow.
            creators.me?.let { mine ->
                Box(
                    Modifier
                        .size(48.dp)
                        .softClickable(scale = 0.9f) { haptics.tap(); onOpenCreator(mine.handle) },
                    contentAlignment = Alignment.Center,
                ) {
                    MyCreatorAvatar(mine)
                }
            }
            HeaderIcon(Icons.Default.AddCircle, "New clip", tint = VoiidColor.primary, size = 28.dp) {
                haptics.tap(); onNewClip()
            }
        }

        // Explore / Following. Two pills rather than a top tab bar: there are exactly two
        // sources and they share one grid, so a full tab bar would imply more structure than
        // exists.
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            ScopePill("Explore", !followingScope) { haptics.tap(); followingScope = false }
            ScopePill("Following", followingScope) { haptics.tap(); followingScope = true }
        }

        val error = clips.loadError
        // Every branch takes the same weighted slot: this Column's other child is the
        // header, so a child without weight would size to its intrinsic height and the
        // skeleton's fillMaxSize would resolve against an unbounded constraint.
        val slot = Modifier.fillMaxWidth().weight(1f)
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
                horizontalArrangement = Arrangement.spacedBy(2.dp),
                verticalArrangement = Arrangement.spacedBy(2.dp),
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
private fun MyCreatorAvatar(me: CreatorService.Profile) {
    if (me.avatar_url != null) {
        ClipThumbnail(
            url = me.avatar_url,
            modifier = Modifier.size(28.dp).clip(CircleShape),
        )
    } else {
        Box(
            Modifier.size(28.dp).clip(CircleShape).background(VoiidColor.fieldFill),
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
) {
    Box(
        modifier
            .fillMaxWidth()
            .aspectRatio(9f / 16f)
            .clipZoomSource(scale = 0.98f) { onTap() },
    ) {
        ClipThumbnail(
            url = clip.thumbUrl,
            localPath = clip.localThumbPath,
            modifier = Modifier.fillMaxSize(),
        )

        // Scrim: the view count sits on arbitrary user video, so it needs its own
        // contrast floor rather than relying on the frame being dark.
        Box(
            Modifier.fillMaxSize().background(
                Brush.verticalGradient(
                    0.5f to Color.Transparent,
                    1f to Color.Black.copy(alpha = 0.55f),
                )
            )
        )

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
                        "Uploading",
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

            ClipUploadState.None -> Row(
                Modifier.align(Alignment.BottomStart).padding(6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                Icon(
                    Icons.Default.RemoveRedEye, null,
                    tint = Color.White, modifier = Modifier.size(11.dp),
                )
                Text(
                    ClipCount.compact(clip.viewCount),
                    style = VoiidFont.rounded(11, FontWeight.SemiBold),
                    color = Color.White,
                )
            }
        }
    }
}

/** One of the two feed-scope pills. Filled when selected, quiet when not. */
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
    creators: com.voiid.app.model.CreatorStore,
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
            verticalArrangement = Arrangement.spacedBy(2.dp),
            horizontalArrangement = Arrangement.spacedBy(2.dp),
        ) {
            itemsIndexed(rows, key = { _, c -> c.id }) { index, clip ->
                Box(
                    Modifier
                        .aspectRatio(9f / 16f)
                        .clipTileEntrance(index, entrance)
                        .clipZoomSource(scale = 0.97f) {
                            haptics.tap()
                            // Opens the CLIP now, not its creator. The pager takes an
                            // injected list, so this feed's own rows can drive it — the
                            // old creator-page detour existed only because the pager could
                            // index nothing but ClipsStore's page.
                            onOpenClip(index)
                        }
                ) {
                    ClipThumbnail(url = clip.thumb_url, modifier = Modifier.fillMaxSize())
                    Box(
                        Modifier.fillMaxSize().background(
                            Brush.verticalGradient(
                                0.5f to Color.Transparent,
                                1f to Color.Black.copy(alpha = 0.6f),
                            )
                        )
                    )
                    Column(Modifier.align(Alignment.BottomStart).padding(6.dp)) {
                        clip.author_handle?.let {
                            Text(
                                "@$it",
                                style = VoiidFont.rounded(10, FontWeight.SemiBold),
                                color = Color.White,
                                maxLines = 1,
                            )
                        }
                        Row(
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(3.dp),
                        ) {
                            Icon(
                                Icons.Default.RemoveRedEye, null,
                                tint = Color.White, modifier = Modifier.size(10.dp),
                            )
                            Text(
                                ClipCount.compact(clip.view_count),
                                style = VoiidFont.rounded(10, FontWeight.SemiBold),
                                color = Color.White,
                            )
                        }
                    }
                }
            }
            item(span = { androidx.compose.foundation.lazy.grid.GridItemSpan(3) }) {
                Spacer(Modifier.height(100.dp))
            }
        }
    }
}
