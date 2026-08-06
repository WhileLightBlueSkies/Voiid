package com.voiid.app.main.clips

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.grid.GridCells
import androidx.compose.foundation.lazy.grid.LazyVerticalGrid
import androidx.compose.foundation.lazy.grid.items
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Verified
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.outlined.Groups
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
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.blur
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.LayoutCoordinates
import androidx.compose.ui.layout.boundsInRoot
import androidx.compose.ui.layout.findRootCoordinates
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import coil.compose.AsyncImage
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
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

    /**
     * You follow nobody yet. A DIFFERENT problem from [NoClips] — there is plenty to watch,
     * you just have not picked anyone — so it gets its own copy and its own CTA. Offering
     * "post a clip" here would be a non-sequitur.
     */
    object FollowingNobody : ClipsEmptyKind()
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
        is ClipsEmptyKind.FollowingNobody ->
            "Nothing here yet" to "Follow a few creators and their clips will land here."
        is ClipsEmptyKind.Failed -> "Couldn't load clips" to kind.message
    }
    val actionTitle = when (kind) {
        is ClipsEmptyKind.Failed -> "Retry"
        is ClipsEmptyKind.FollowingNobody -> "Explore creators"
        else -> "Create clip"
    }
    val icon: ImageVector = when (kind) {
        is ClipsEmptyKind.Failed -> Icons.Default.WarningAmber
        is ClipsEmptyKind.FollowingNobody -> Icons.Outlined.Groups
        else -> Icons.Outlined.PlayCircleOutline
    }

    // A slow breath on the icon. An empty screen with nothing moving on it reads as a
    // screen that failed to load; this is the cheapest signal that it is alive and
    // deliberate. Failure is deliberately EXCLUDED — a pulsing warning implies work is
    // still happening when in fact it stopped.
    val pulse = rememberInfiniteTransition(label = "emptyPulse")
    val iconAlpha by pulse.animateFloat(
        initialValue = 1f,
        targetValue = if (kind is ClipsEmptyKind.Failed) 1f else 0.55f,
        animationSpec = infiniteRepeatable(tween(1400), RepeatMode.Reverse),
        label = "emptyPulseAlpha",
    )

    Column(
        modifier.fillMaxWidth().padding(top = 80.dp, start = 24.dp, end = 24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        Box(
            Modifier.size(72.dp).clip(CircleShape).background(VoiidColor.fieldFill),
            contentAlignment = Alignment.Center,
        ) {
            Icon(
                icon, null,
                // Primary, not a dimmed grey: the disc already carries the "quiet" job, and a
                // faded icon inside a faded circle left nothing for the eye to land on.
                tint = if (kind is ClipsEmptyKind.Failed) VoiidColor.error else VoiidColor.primary,
                modifier = Modifier.size(32.dp).alpha(iconAlpha),
            )
        }
        Spacer(Modifier.height(VoiidSpacing.xs))
        Text(title, style = VoiidFont.rounded(22, FontWeight.SemiBold), color = VoiidColor.textPrimary)
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
                    // 48, not 44: the text plus its 12dp padding only reached ~46, and this is
                    // the ONE control on an otherwise empty screen.
                    .heightIn(min = 48.dp)
                    .clip(CircleShape)
                    .background(VoiidColor.primary)
                    .softClickable(scale = 0.95f) { haptics.tap(); onAction() }
                    .padding(horizontal = 24.dp, vertical = 12.dp),
                contentAlignment = Alignment.Center,
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

/**
 * The verification seal, shared so a creator page and a player chrome cannot draw two
 * different badges.
 *
 * AMBER ([VoiidColor.accent]), never [VoiidColor.primary]: primary is the colour of every
 * button on a creator page, so a seal drawn in it reads as one more control rather than a
 * badge. Amber is the palette's scarcity colour — see the SPARK note in Color.kt — which is
 * exactly the job a verification mark has.
 */
@Composable
fun VerifiedSeal(size: Dp = 16.dp, modifier: Modifier = Modifier) {
    Icon(
        Icons.Filled.Verified,
        "Verified",
        tint = VoiidColor.accent,
        modifier = modifier.size(size),
    )
}

/**
 * Where on screen the tile that opened the fullscreen player sat, as a [TransformOrigin].
 *
 * The player grows out of that point instead of sliding up from the bottom edge. A slide says
 * "here is an unrelated screen"; the tile and the player are the same clip, and the eye needs
 * to be told so.
 *
 * PARKED IN AN OBJECT rather than threaded through the open callbacks because the player is not
 * a child of any grid — it is a full-screen overlay drawn as a SIBLING of the whole tab surface,
 * and three separate grids (explore, following, a creator's page) can raise it. Widening three
 * `(Int) -> Unit` callbacks to carry a transform origin would push a purely presentational
 * detail through every screen in between.
 *
 * Deliberately NOT a `SharedTransitionLayout` morph: the shared scope would have to wrap the
 * entire tab surface to cover both the grid and the overlay, and Compose's shared elements do
 * not survive `LazyVerticalGrid` recycling the tile they are anchored to mid-transition.
 */
object ClipZoomOrigin {
    var value by mutableStateOf(TransformOrigin.Center)
        private set

    fun record(coords: LayoutCoordinates?) {
        val tile = coords?.takeIf { it.isAttached } ?: return
        val root = tile.findRootCoordinates()
        val w = root.size.width.toFloat()
        val h = root.size.height.toFloat()
        // A zero-sized root means the tile was measured before layout settled; the previous
        // origin is a better guess than a divide by zero.
        if (w <= 0f || h <= 0f) return
        val center = tile.boundsInRoot().center
        value = TransformOrigin(center.x / w, center.y / h)
    }
}

/**
 * A grid tile that opens the fullscreen player: notes where it is before firing [onTap], so the
 * overlay can grow out of it. See [ClipZoomOrigin].
 *
 * The position hook comes FIRST in the chain so it reads the tile's settled bounds rather than
 * the press-scale layer [softClickable] adds beneath it.
 */
@Composable
fun Modifier.clipZoomSource(scale: Float = 0.98f, onTap: () -> Unit): Modifier {
    // A PLAIN holder, never snapshot state: `onGloballyPositioned` fires on every frame of a
    // scroll, and a state write there would recompose every visible tile for the whole fling.
    // Nothing in composition reads this — only the click handler does, at which point the
    // coordinates object is live and reports the tile's current position.
    val tile = remember { ClipTileCoords() }
    return this
        .onGloballyPositioned { tile.value = it }
        .softClickable(scale = scale) {
            ClipZoomOrigin.record(tile.value)
            onTap()
        }
}

private class ClipTileCoords {
    var value: LayoutCoordinates? = null
}

/**
 * True while the first page's entrance animation should still play.
 *
 * Hoisted out of the tile because a LazyGrid DISPOSES the composables it scrolls past: a
 * per-tile `remember` would replay the fade every time a tile came back into view, which
 * reads as flicker rather than an entrance. [ready] should be "the first page has landed".
 */
@Composable
fun rememberGridEntrance(ready: Boolean): Boolean {
    var played by remember { mutableStateOf(false) }
    LaunchedEffect(ready) {
        if (ready && !played) {
            delay(700)
            played = true
        }
    }
    return ready && !played
}

/**
 * Staggered opacity fade-in for a grid tile. Only the first screenful is staggered — past
 * that the delay would be dead time on a tile the user has already scrolled to, so the
 * offset is capped.
 */
@Composable
fun Modifier.clipTileEntrance(index: Int, enabled: Boolean): Modifier {
    // [enabled] is read only at the first composition of this tile, deliberately: branching
    // on it would make `remember`/`LaunchedEffect` conditional, and a tile that entered
    // mid-animation would lose the state driving it.
    val alpha = remember { Animatable(if (enabled) 0f else 1f) }
    LaunchedEffect(Unit) {
        if (!enabled) return@LaunchedEffect
        delay((index.coerceAtMost(11) * 18).toLong())
        alpha.animateTo(1f, tween(250))
    }
    return this.alpha(alpha.value)
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
