package com.voiid.app.ui.components

import androidx.compose.foundation.layout.statusBars
import androidx.compose.ui.layout.positionInWindow
import androidx.compose.ui.layout.onGloballyPositioned
import androidx.compose.ui.composed
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
                // A caller that reports `refreshing` collapses the indicator when its work ends
                // (rememberVoiidPullRefresh). One that does not — most of them — used to leave it
                // PARKED for good, the list shifted down under a frozen arc, until the screen was
                // left. Give the caller a beat to report; if it has not, collapse now.
                kotlinx.coroutines.delay(450)
                if (!state.refreshing && state.pullPx > 0f) {
                    animate(initialValue = state.pullPx, targetValue = 0f) { v, _ -> state.pullPx = v }
                }
            } else if (state.pullPx > 0f) {
                animate(initialValue = state.pullPx, targetValue = 0f) { v, _ -> state.pullPx = v }
            }
            return available
        }
    }
    // Screens whose scroll area starts at the very top (under the status bar) would draw the
    // spinner beneath the clock. iOS puts it just below the bar, so shift it by however much
    // of the status bar this container sits under.
    return this.composed {
        val statusTop = androidx.compose.foundation.layout.WindowInsets.statusBars
            .getTop(LocalDensity.current).toFloat()
        var windowTop by remember { mutableFloatStateOf(0f) }
        Modifier
        .onGloballyPositioned { windowTop = it.positionInWindow().y }
        .nestedScroll(connection)
        .drawWithContent {
            val underBar = (statusTop - windowTop).coerceAtLeast(0f)
            // Content rides down with the finger…
            translate(top = state.pullPx * 0.55f) { this@drawWithContent.drawContent() }
            // …and the indicator draws over the vacated strip.
            // iOS UIRefreshControl, not a Material arc: an 8-spoke activity indicator ~20dp
            // across in system grey, centred in the gap the content leaves. Spokes appear one by
            // one as the pull arms it, then the wheel ticks round while refreshing.
            //
            // (The old arc passed no `size`, so drawArc filled the WHOLE canvas — a screen-wide
            // ring instead of a spinner.)
            // Only a PULL shows the wheel. A background reload (a tab opening, a sync) also sets
            // `refreshing`, and drawing for it put the spinner over the title with no gap
            // under it — iOS's refresh control likewise appears only for a user pull.
            if (state.pullPx > 2f) {
                val fraction = (state.pullPx / (thresholdDp.dp.value * 2.2f)).coerceIn(0f, 1f)
                val gap = state.pullPx * 0.55f
                val outer = 9.5.dp.toPx()
                val inner = 4.8.dp.toPx()
                val cx = size.width / 2
                val cy = underBar + (gap / 2).coerceIn(outer + 2.dp.toPx(), 30.dp.toPx())
                val spokes = 8
                val shown = if (state.refreshing) spokes else (fraction * spokes).toInt().coerceIn(1, spokes)
                // Stepped rotation, like the iOS wheel: the lead spoke jumps 45° at a time.
                val lead = if (state.refreshing) ((state.spinDegrees / 45f).toInt() % spokes) else 0
                val grey = Color(0xFF8E8E93)
                for (k in 0 until shown) {
                    val angle = Math.toRadians((-90.0 + k * 45.0)).toFloat()
                    val alpha = if (state.refreshing) {
                        val age = ((lead - k) % spokes + spokes) % spokes
                        1f - age * (0.75f / spokes)
                    } else 0.35f + 0.55f * fraction
                    val c = kotlin.math.cos(angle); val sn = kotlin.math.sin(angle)
                    drawLine(
                        color = grey.copy(alpha = alpha.coerceIn(0f, 1f)),
                        start = Offset(cx + c * inner, cy + sn * inner),
                        end = Offset(cx + c * outer, cy + sn * outer),
                        strokeWidth = 2.3.dp.toPx(),
                        cap = StrokeCap.Round,
                    )
                }
            }
        }
    }
}
