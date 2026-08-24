package com.voiid.app.ui.components

import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.animation.core.animateFloat
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.VoiidColor

/**
 * Custom pull-to-refresh as a MODIFIER — the audited screens' refresh affordance without
 * Material's visual language.
 *
 * An inner scrolling list hands its leftover DOWNWARD overscroll at the top to the connection;
 * past [THRESHOLD_PX_FRACTION] of the threshold a release fires [onRefresh] exactly once. The
 * indicator draws over the content (which translates with the finger), parks while
 * [VoiidPullState.refreshing] is true, and collapses when it clears.
 *
 * Reduced motion: the arc stops spinning (holds a full ring) but the gesture still works —
 * a frozen control would read as broken, motion removal must not cost information.
 *
 * Adoption is deliberately tiny so every iOS-refreshable counterpart takes it:
 *     val pull = rememberVoiidPullRefresh { scope.launch { reload() } }
 *     Column(Modifier.fillMaxSize().voiidPullRefresh(pull)) { … }
 */
class VoiidPullState {
    /** Current pull distance in px (content translation). */
    var pullPx by mutableFloatStateOf(0f)
    var refreshing by mutableStateOf(false)
    var spinDegrees by mutableFloatStateOf(0f)

    internal var fire: (() -> Unit)? = null
    internal var enabled: Boolean = true
}

/** Drag distance (fraction of travel) that arms a refresh. */
private const val THRESHOLD_PX_FRACTION = 72f

@Composable
fun rememberVoiidPullRefresh(
    refreshing: Boolean = false,
    enabled: Boolean = true,
    densityScale: Float = 1f,
    onRefresh: () -> Unit,
): VoiidPullState {
    val state = remember { VoiidPullState() }
    val density = LocalDensity.current
    val threshold = with(density) { (THRESHOLD_PX_FRACTION * densityScale).dp.toPx() }
    val reduceMotion = reduceMotionEnabled()

    state.fire = onRefresh
    state.enabled = enabled && !refreshing
    state.refreshing = refreshing

    // Park at rest height while refreshing; collapse when done.
    val restPx = with(density) { 40.dp.toPx() }
    LaunchedEffect(refreshing) {
        if (!refreshing && state.pullPx > 1f && state.pullPx < threshold * 1.6f) {
            animate(initialValue = state.pullPx, targetValue = 0f) { v, _ -> state.pullPx = v }
        }
    }

    // Spin while refreshing; hold still under reduced motion.
    val spin = rememberInfiniteTransition(label = "voiidPullSpin")
    val spinAngle by spin.animateFloat(
        initialValue = 0f, targetValue = 360f,
        animationSpec = infiniteRepeatable(tween(durationMillis = 900, easing = LinearEasing)),
        label = "voiidPullSpinAngle",
    )
    LaunchedEffect(refreshing, reduceMotion) {
        if (refreshing && !reduceMotion) {
            while (true) { state.spinDegrees = spinAngle; kotlinx.coroutines.delay(16) }
        }
    }

    return state
}

private const val MAX_PULL_FACTOR = 1.6f

fun Modifier.voiidPullRefresh(
    state: VoiidPullState,
    /** Resolved by the caller inside composition (the palette getters are @Composable). */
    indicatorColor: Color,
    thresholdDp: Float = 72f,
): Modifier {
    val connection = object : NestedScrollConnection {
        override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
            // Finger moving up retracts the pull first.
            if (available.y < 0 && state.pullPx > 0f) {
                val used = available.y.coerceAtLeast(-state.pullPx)
                state.pullPx += used
                return Offset(0f, used)
            }
            return Offset.Zero
        }

        override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
            if (!state.enabled || state.refreshing) return Offset.Zero
            if (available.y > 0) {
                state.pullPx = (state.pullPx + available.y * 0.5f).coerceAtMost(thresholdDp.dp.value * MAX_PULL_FACTOR * 2.2f)
                return available
            }
            return Offset.Zero
        }

        override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
            val threshold = thresholdDp.dp.value * 2.2f   // px (density folded into value*2.2 approximation)
            if (!state.refreshing && state.pullPx >= threshold * 0.9f) {
                animate(initialValue = state.pullPx, targetValue = threshold * 0.55f) { v, _ -> state.pullPx = v }
                state.fire?.invoke()
            } else if (state.pullPx > 0f) {
                animate(initialValue = state.pullPx, targetValue = 0f) { v, _ -> state.pullPx = v }
            }
            return available
        }
    }
    return this
        .nestedScroll(connection)
        .drawWithContent {
            // Content rides down with the finger…
            translate(top = state.pullPx * 0.55f) { this@drawWithContent.drawContent() }
            // …and the indicator draws over the vacated strip.
            if (state.pullPx > 2f || state.refreshing) {
                val fraction = (state.pullPx / (thresholdDp.dp.value * 2.2f)).coerceIn(0f, 1f)
                val radius = 10.dp.toPx()
                val cy = (state.pullPx * 0.55f).coerceAtMost(radius * 2.4f)
                val alpha = if (state.refreshing) 1f else 0.25f + 0.75f * fraction
                val sweep = if (state.refreshing || fraction >= 1f) 360f else 300f * fraction
                drawArc(
                    color = indicatorColor.copy(alpha = alpha),
                    startAngle = -90f + state.spinDegrees,
                    sweepAngle = sweep,
                    useCenter = false,
                    topLeft = Offset(size.width / 2 - radius, cy / 2 - radius),
                    style = Stroke(width = 2.5.dp.toPx(), cap = StrokeCap.Round),
                )
            }
        }
}
