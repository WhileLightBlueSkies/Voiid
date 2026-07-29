package com.voiid.app.main.clips

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.PlayCircleOutline
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay

/**
 * Shared pieces for the Clips surface — shimmer, thumbnail, video loader, empty/error
 * states. Port of iOS `ClipsUIKit.swift`; kept in one file so the grid and the player
 * cannot drift apart visually.
 */

/**
 * The skeleton sweep. One implementation, one period — the grid skeleton and the
 * thumbnail placeholder must pulse in sympathy, not at two different rates.
 */
@Composable
fun ClipShimmer(modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "shimmer")
    val phase by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(1200), RepeatMode.Restart),
        label = "shimmerPhase",
    )
    Box(
        modifier
            .background(VoiidColor.fieldFill)
            .background(
                Brush.linearGradient(
                    colors = listOf(
                        Color.Transparent,
                        VoiidColor.textSecondary.copy(alpha = 0.10f),
                        Color.Transparent,
                    ),
                    start = androidx.compose.ui.geometry.Offset(phase * 900f - 300f, 0f),
                    end = androidx.compose.ui.geometry.Offset(phase * 900f + 300f, 600f),
                )
            )
    )
}

/**
 * A grid thumbnail: shimmer until it resolves, then the image. Never a blank box and
 * never a layout jump — the frame is fixed by the caller's aspect ratio. Coil handles
 * the memory/disk cache and request coalescing.
 */
@Composable
fun ClipThumbnail(
    url: String?,
    localPath: String? = null,
    modifier: Modifier = Modifier,
) {
    val model = localPath ?: url
    if (model == null) {
        ClipShimmer(modifier)
        return
    }
    var loading by remember(model) { mutableStateOf(true) }
    var failed by remember(model) { mutableStateOf(false) }

    Box(modifier) {
        AsyncImage(
            model = model,
            contentDescription = null,
            modifier = Modifier.fillMaxSize(),
            contentScale = androidx.compose.ui.layout.ContentScale.Crop,
            onSuccess = { loading = false },
            onError = { loading = false; failed = true },
        )
        if (loading) ClipShimmer(Modifier.fillMaxSize())
        if (failed) {
            // Resolved-but-broken is visually distinct from still-loading: a static
            // placeholder, not an endless shimmer that implies progress.
            Box(
                Modifier.fillMaxSize().background(VoiidColor.fieldFill),
                contentAlignment = Alignment.Center,
            ) {
                Icon(
                    Icons.Outlined.PlayCircleOutline, null,
                    tint = VoiidColor.textSecondary.copy(alpha = 0.5f),
                    modifier = Modifier.size(22.dp),
                )
            }
        }
    }
}

/**
 * Shown while a clip buffers. Draws over the clip's own blurred cover frame so the screen
 * is never black, with a branded ring rather than a stock spinner.
 */
@Composable
fun ClipVideoLoader(
    thumbUrl: String?,
    localThumbPath: String? = null,
    modifier: Modifier = Modifier,
) {
    var slow by remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        // Only admit to slowness after 3s — showing it immediately makes a fast load
        // feel slow.
        delay(3000)
        slow = true
    }

    Box(modifier.background(Color.Black), contentAlignment = Alignment.Center) {
        if (thumbUrl != null || localThumbPath != null) {
            ClipThumbnail(
                url = thumbUrl,
                localPath = localThumbPath,
                modifier = Modifier.fillMaxSize().blur(24.dp),
            )
        }
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            CircularProgressIndicator(
                modifier = Modifier.size(42.dp),
                color = VoiidColor.primary,
                strokeWidth = 3.dp,
            )
            if (slow) {
                Text(
                    "Still loading…",
                    style = VoiidFont.rounded(12),
                    color = Color.White.copy(alpha = 0.75f),
                )
            }
        }
    }
}

/**
 * The one empty-state shape for the Clips surface.
 *
 * A LOAD FAILURE must use [Kind.Failed], never [Kind.NoClips] — telling a user "No clips
 * yet" when the request actually errored is the classic bug in this pattern, and it
 * teaches them the feature is dead.
 */
sealed class ClipsEmptyKind {
    object NoClips : ClipsEmptyKind()
    object NoneFromYou : ClipsEmptyKind()
    data class Failed(val message: String) : ClipsEmptyKind()
}

@Composable
fun ClipsEmptyState(
    kind: ClipsEmptyKind,
    onAction: (() -> Unit)? = null,
    modifier: Modifier = Modifier,
) {
    val haptics = LocalVoiidHaptics.current
    val (title, subtitle) = when (kind) {
        is ClipsEmptyKind.NoClips -> "No clips yet" to "Be the first to post one."
        is ClipsEmptyKind.NoneFromYou -> "You haven't posted a clip" to "Your clips will appear here."
        is ClipsEmptyKind.Failed -> "Couldn't load clips" to kind.message
    }
    val actionTitle = if (kind is ClipsEmptyKind.Failed) "Retry" else "Create clip"

    Column(
        modifier.fillMaxWidth().padding(top = 80.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Icon(
            if (kind is ClipsEmptyKind.Failed) Icons.Default.WarningAmber
            else Icons.Outlined.PlayCircleOutline,
            null,
            tint = VoiidColor.textSecondary.copy(alpha = 0.5f),
            modifier = Modifier.size(44.dp),
        )
        Text(title, style = VoiidFont.rounded(18, FontWeight.SemiBold), color = VoiidColor.textPrimary)
        Text(
            subtitle,
            style = VoiidFont.rounded(15),
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
        )
        if (onAction != null) {
            Box(
                Modifier
                    .padding(top = 8.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .softClickable(scale = 0.95f) { haptics.tap(); onAction() }
                    .padding(horizontal = 24.dp, vertical = 12.dp)
            ) {
                Text(
                    actionTitle,
                    style = VoiidFont.rounded(16, FontWeight.SemiBold),
                    color = VoiidColor.textOnPrimary,
                )
            }
        }
    }
}

/** Placeholder tiles in the real grid geometry, so nothing reflows when content lands. */
@Composable
fun ClipsGridSkeleton(columns: Int = 3, count: Int = 12, modifier: Modifier = Modifier) {
    LazyVerticalGrid(
        columns = GridCells.Fixed(columns),
        modifier = modifier.fillMaxSize(),
        horizontalArrangement = Arrangement.spacedBy(2.dp),
        verticalArrangement = Arrangement.spacedBy(2.dp),
        userScrollEnabled = false,
    ) {
        items(count) {
            ClipShimmer(Modifier.fillMaxWidth().aspectRatio(9f / 16f))
        }
    }
}
