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
import androidx.compose.foundation.lazy.grid.itemsIndexed
import androidx.compose.foundation.lazy.grid.rememberLazyGridState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.AddCircle
import androidx.compose.material.icons.filled.RemoveRedEye
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.voiid.app.model.ClipCount
import com.voiid.app.model.ClipUploadState
import com.voiid.app.model.ClipsStore
import com.voiid.app.model.VClip
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont

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
    onOpenClip: (Int) -> Unit,
    onNewClip: () -> Unit,
) {
    val haptics = LocalVoiidHaptics.current
    val gridState = rememberLazyGridState()

    LaunchedEffect(Unit) {
        if (!clips.hasLoadedOnce) clips.refresh()
    }

    // Page as the grid nears its end. Driven off the last visible index rather than a
    // per-item callback so a fast fling triggers one append, not thirty.
    LaunchedEffect(gridState) {
        snapshotFlow { gridState.layoutInfo.visibleItemsInfo.lastOrNull()?.index ?: 0 }
            .collect { clips.loadMoreIfNeeded(it) }
    }

    Column(Modifier.fillMaxSize().background(VoiidColor.background).statusBarsPadding()) {
        Row(
            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text("Clips", style = VoiidFont.display, color = VoiidColor.textPrimary)
            Spacer(Modifier.weight(1f))
            Icon(
                Icons.Default.AddCircle, "New clip", tint = VoiidColor.primary,
                modifier = Modifier.size(28.dp).softClickable(scale = 0.9f) {
                    haptics.tap(); onNewClip()
                },
            )
        }

        val error = clips.loadError
        // Every branch takes the same weighted slot: this Column's other child is the
        // header, so a child without weight would size to its intrinsic height and the
        // skeleton's fillMaxSize would resolve against an unbounded constraint.
        val slot = Modifier.fillMaxWidth().weight(1f)
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
                    ClipTile(clip) {
                        // A still-uploading tile has no server row to play yet.
                        if (clip.uploadState == ClipUploadState.None) {
                            haptics.tap()
                            onOpenClip(index)
                        }
                    }
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

@Composable
private fun ClipTile(clip: VClip, onTap: () -> Unit) {
    Box(
        Modifier
            .fillMaxWidth()
            .aspectRatio(9f / 16f)
            .softClickable(scale = 0.98f) { onTap() },
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
                    verticalArrangement = Arrangement.spacedBy(4.dp),
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
