package com.voiid.app.ui.components

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.AnimationSpec
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.gestures.detectVerticalDragGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.WindowInsets
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.ime
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Shape
import androidx.compose.ui.input.nestedscroll.NestedScrollConnection
import androidx.compose.ui.input.nestedscroll.NestedScrollSource
import androidx.compose.ui.input.nestedscroll.nestedScroll
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.input.pointer.util.VelocityTracker
import androidx.compose.ui.layout.onSizeChanged
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.Velocity
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties
import com.voiid.app.ui.theme.VoiidColor
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlin.math.abs
import kotlin.math.roundToInt

/**
 * The Voiid sheet — the one custom modal-surface primitive behind every audited sheet in the
 * app. Replaces Material `ModalBottomSheet`, whose defaults (expanded-only travel, stock scrim,
 * stock handle, stock motion) cannot reproduce the iOS interaction model.
 *
 * Contract:
 *  - Detents ([VoiidDetent]): fixed dp height, `.medium` (half container), `.large`
 *    (SwiftUI-large, leaving the status area), and content-computed. Combine smallest → largest;
 *    dragging travels between them.
 *  - Configurable opening detent ([initialDetentIndex]) and optional 40×4dp handle.
 *  - Branded surface with controlled top radius/scrim — centralised in [VoiidSheetTokens],
 *    which exist to be tuned once against device captures of the SwiftUI system presentation
 *    (iOS specifies no numbers here; do not scatter literals across call sites).
 *  - DIRECT finger tracking with light rubber-band past the end detents; velocity-aware settle;
 *    drag-to-dismiss; Back and scrim-tap dismissal; nested-scroll handoff (an inner scrolling
 *    list drags the sheet only at its edges).
 *  - Navigation-bar insets built in; keyboard avoidance lifts the sheet above the IME so the
 *    keyboard never covers interactive content.
 *  - Reduced motion replaces travel with a plain fade.
 *  - ASYNC-SAFE dismissal: [onDismiss] fires only after the hide animation completes, so
 *    callers may swap screens or pop flows inside it ("hide-before-completion").
 *
 * Layout model: the surface is laid out at the LARGEST detent's height, anchored to the bottom,
 * and translated DOWN so only the active detent's height shows above the bottom edge — which is
 * exactly how an iOS detented sheet reads while travelling.
 */
object VoiidSheetTokens {
    /** Centralised so they can be tuned once against captures of the iOS reference. */
    var scrimAlpha: Float = 0.42f
    var topRadius: Dp = 16.dp
    /** Gap left above a fully expanded large sheet (status area), like SwiftUI `.large`. */
    var largeTopGap: Dp = 12.dp
    /** Fraction of container height for the medium detent (SwiftUI `.medium`). */
    const val MEDIUM_FRACTION: Float = 0.5f
    var settleDamping: Float = 0.86f
    var settleStiffness: Float = 380f
    /** Resistance while pulling past the end detents (rubber-band). */
    const val OVERDRAG_RESISTANCE: Float = 0.30f
    /** Release beyond this fraction of sheet height past the last detent dismisses. */
    const val DISMISS_EXCESS_FRACTION: Float = 0.22f
    /** Downward fling faster than this (px/s) while past the lowest detent dismisses. */
    const val DISMISS_FLING_VELOCITY: Float = 1900f
}

/** A stopping height for a [VoiidSheet]. */
sealed interface VoiidDetent {
    /** Exact height. */
    data class Fixed(val height: Dp) : VoiidDetent

    /** Half the container — SwiftUI `.medium`. */
    data object Medium : VoiidDetent

    /** Near-full — SwiftUI `.large`. */
    data object Large : VoiidDetent

    /** Height computed from the wrapped content itself (capped by the container). */
    data object Content : VoiidDetent
}

/**
 * @param visible     Whether the sheet should be presented.
 * @param onDismiss   Called AFTER the exit animation finishes (async-safe).
 * @param detents     Ordered smallest → largest.
 * @param initialDetentIndex Which detent to open at.
 */
@Composable
fun VoiidSheet(
    visible: Boolean,
    onDismiss: () -> Unit,
    detents: List<VoiidDetent>,
    modifier: Modifier = Modifier,
    initialDetentIndex: Int = 0,
    showHandle: Boolean = false,
    dismissOnBack: Boolean = true,
    tapOutsideToDismiss: Boolean = true,
    content: @Composable ColumnScope.() -> Unit,
) {
    require(detents.isNotEmpty()) { "VoiidSheet needs at least one detent" }
    // Keep rendering while the exit animation plays so the hide can complete before the
    // parent's state change tears the composable down.
    var shown by remember { mutableStateOf(visible) }
    var hiding by remember { mutableStateOf(false) }

    if (visible && !shown) {
        shown = true
        hiding = false
    }
    if (!visible && shown && !hiding) hiding = true

    if (shown) {
        Dialog(
            onDismissRequest = {},
            properties = DialogProperties(
                usePlatformDefaultWidth = false,
                decorFitsSystemWindows = false,
                dismissOnBackPress = false,
                dismissOnClickOutside = false,
            ),
        ) {
            SheetBody(
                detents = detents,
                initialDetentIndex = initialDetentIndex,
                showHandle = showHandle,
                tapOutsideToDismiss = tapOutsideToDismiss,
                dismissOnBack = dismissOnBack,
                hiding = hiding,
                onRequestHide = { hiding = true },
                onHidden = {
                    shown = false
                    hiding = false
                    onDismiss()
                },
                content = content,
            )
        }
    }
}

@Composable
private fun SheetBody(
    detents: List<VoiidDetent>,
    initialDetentIndex: Int,
    showHandle: Boolean,
    tapOutsideToDismiss: Boolean,
    dismissOnBack: Boolean,
    hiding: Boolean,
    onRequestHide: () -> Unit,
    onHidden: () -> Unit,
    content: @Composable ColumnScope.() -> Unit,
) {
    val reduceMotion = reduceMotionEnabled()
    val scope = rememberCoroutineScope()
    val density = LocalDensity.current

    // Animated Back dismissal: the dialog's own back handling is disabled so Back plays the
    // exit instead of tearing the window down.
    androidx.activity.compose.BackHandler(enabled = !hiding && dismissOnBack) { onRequestHide() }

    // Container metrics (px).
    var containerH by remember { mutableIntStateOf(0) }
    var contentH by remember { mutableIntStateOf(0) }
    val imeH = WindowInsets.ime.getBottom(density)

    // Height (px) of each detent, matching [detents] order.
    val detentHeights = remember(detents, containerH, contentH) {
        detents.map { d ->
            when (d) {
                is VoiidDetent.Fixed -> with(density) { d.height.toPx() }
                VoiidDetent.Medium -> containerH * VoiidSheetTokens.MEDIUM_FRACTION
                VoiidDetent.Large -> containerH - with(density) { VoiidSheetTokens.largeTopGap.toPx() }
                VoiidDetent.Content -> contentH.toFloat()
            }.coerceIn(0f, containerH.toFloat())
        }
    }
    val largestH = detentHeights.maxOrNull() ?: 0f
    // Translation space: 0 = fully raised at the largest detent; larger = slid further down.
    val anchors = remember(detentHeights, largestH) {
        detentHeights.map { largestH - it }.sorted()
    }
    val minAnchor = anchors.firstOrNull() ?: 0f   // most-raised
    val maxAnchor = anchors.lastOrNull() ?: 0f    // most-lowered
    val offscreenAnchor = maxAnchor + largestH.coerceAtLeast(1f)
    // When any explicit detent exists the SURFACE pins to the largest one (content lives at its
    // top, like an iOS sheet grown to large); a Content-only sheet hugs its content.
    val pinnedSurfaceHeight = remember(detents, detentHeights) {
        detentHeights
            .filterIndexed { i, _ -> detents[i] !is VoiidDetent.Content }
            .maxOrNull()
            ?.let { px -> with(density) { px.toDp() } }
    }

    var settledIndex by remember {
        mutableIntStateOf(initialDetentIndex.coerceIn(0, (anchors.size - 1).coerceAtLeast(0)))
    }
    // NaN until entrance positions it; guards against drawing at 0 before measurement.
    var rawTranslate by remember { mutableStateOf(Float.NaN) }
    val anim = remember { Animatable(0f) }
    var animating by remember { mutableStateOf(false) }
    var settleJob by remember { mutableStateOf<Job?>(null) }

    fun displayTranslate(): Float =
        when {
            !rawTranslate.isNaN() && !animating -> rawTranslate
            animating -> anim.value
            else -> maxAnchor // unpositioned: treat as fully lowered (invisible)
        }

    fun beginDirectDrag() {
        settleJob?.cancel()
        if (animating) {
            rawTranslate = anim.value
            animating = false
        }
        if (rawTranslate.isNaN()) rawTranslate = minAnchor
    }

    fun animateTo(target: Float, spec: AnimationSpec<Float>, onDone: () -> Unit = {}) {
        settleJob?.cancel()
        val start = rawTranslate.takeUnless { it.isNaN() } ?: minAnchor
        settleJob = scope.launch {
            animating = true
            anim.snapTo(start)
            anim.animateTo(target, spec)
            rawTranslate = target
            animating = false
            onDone()
        }
    }

    val settleSpec = spring<Float>(
        dampingRatio = VoiidSheetTokens.settleDamping,
        stiffness = VoiidSheetTokens.settleStiffness,
    )

    // Entrance once the container has been measured.
    LaunchedEffect(containerH) {
        if (containerH > 0 && rawTranslate.isNaN()) {
            val target = anchors.getOrNull(settledIndex) ?: minAnchor
            if (reduceMotion) rawTranslate = target else animateTo(target, settleSpec)
        }
    }

    // Exit: travel fully offscreen (or fade under reduced motion) BEFORE completing the
    // callback — callers may safely tear down state in [onHidden].
    LaunchedEffect(hiding) {
        if (!hiding) return@LaunchedEffect
        if (reduceMotion) {
            kotlinx.coroutines.delay(140)
        } else {
            animateTo(offscreenAnchor, tween(durationMillis = 220))
        }
        onHidden()
    }

    fun settleAfterGesture(velocityY: Float) {
        beginDirectDrag()
        val current = rawTranslate
        val flungDown = velocityY > VoiidSheetTokens.DISMISS_FLING_VELOCITY
        val overdrag = current - maxAnchor
        if (overdrag > largestH * VoiidSheetTokens.DISMISS_EXCESS_FRACTION ||
            (flungDown && overdrag > 0f)
        ) {
            onRequestHide()
            return
        }
        val target = when {
            velocityY < -VoiidSheetTokens.DISMISS_FLING_VELOCITY ->
                anchors.lastOrNull { it < current } ?: minAnchor
            flungDown ->
                anchors.firstOrNull { it > current } ?: maxAnchor
            else -> anchors.minByOrNull { abs(it - current) } ?: minAnchor
        }
        settledIndex = anchors.indexOf(target).coerceAtLeast(0)
        if (reduceMotion) rawTranslate = target else animateTo(target, settleSpec)
    }

    // Nested-scroll handoff: an inner list drags the sheet up as it scrolls past its own top,
    // and hands its leftover downward overscroll to the sheet at its bottom.
    val nestedHandoff = remember(minAnchor, maxAnchor) {
        object : NestedScrollConnection {
            override fun onPreScroll(available: Offset, source: NestedScrollSource): Offset {
                if (available.y < 0 && !animating) {
                    val current = displayTranslate()
                    val room = current - minAnchor
                    if (room > 0f) {
                        val consume = available.y.coerceAtLeast(-room)
                        beginDirectDrag()
                        rawTranslate = current + consume
                        return Offset(0f, consume)
                    }
                }
                return Offset.Zero
            }

            override fun onPostScroll(consumed: Offset, available: Offset, source: NestedScrollSource): Offset {
                if (available.y > 0 && !animating) {
                    beginDirectDrag()
                    rawTranslate = displayTranslate() + available.y
                    return available
                }
                return Offset.Zero
            }

            override suspend fun onPostFling(consumed: Velocity, available: Velocity): Velocity {
                if (abs(available.y) > 100f) settleAfterGesture(available.y)
                return available
            }
        }
    }

    val tracker = remember { VelocityTracker() }
    val shape: Shape = RoundedCornerShape(
        topStart = VoiidSheetTokens.topRadius,
        topEnd = VoiidSheetTokens.topRadius,
    )

    // Travel progress drives the scrim: 1 = raised, 0 = gone/offscreen.
    val travel = if (largestH > 0) (1f - displayTranslate() / largestH).coerceIn(0f, 1f) else 0f
    val fadeAlpha by animateFloatAsState(
        targetValue = if (hiding && reduceMotion) 0f else 1f,
        animationSpec = tween(durationMillis = 140),
        label = "voiidSheetFade",
    )
    // Keyboard avoidance: lift the whole sheet above the IME.
    val effectiveTranslate = displayTranslate() - imeH

    Box(
        Modifier
            .fillMaxSize()
            .onSizeChanged { containerH = it.height }
            .pointerInput(tapOutsideToDismiss, hiding) {
                detectTapGestures {
                    if (tapOutsideToDismiss && !hiding) onRequestHide()
                }
            },
    ) {
        Box(
            Modifier
                .fillMaxSize()
                .alpha(travel * VoiidSheetTokens.scrimAlpha)
                .background(Color.Black),
        )

        Column(
            Modifier
                .align(Alignment.BottomCenter)
                .fillMaxWidth()
                .alpha(fadeAlpha)
                .nestedScroll(nestedHandoff)
                .offset { IntOffset(0, effectiveTranslate.roundToInt()) }
                .clip(shape)
                .background(VoiidColor.surfaceCard)
                .then(
                    pinnedSurfaceHeight?.let { Modifier.height(it) } ?: Modifier
                )
                // Consume taps landing on the surface so they never reach the scrim detector.
                .pointerInput(Unit) { detectTapGestures { } }
                .pointerInput(hiding, minAnchor, maxAnchor) {
                    detectVerticalDragGestures(
                        onDragStart = { tracker.resetTracking(); beginDirectDrag() },
                        onDragEnd = { settleAfterGesture(tracker.calculateVelocity().y) },
                        onDragCancel = { settleAfterGesture(0f) },
                    ) { change, dragAmount ->
                        tracker.addPosition(change.uptimeMillis, change.position)
                        change.consume()
                        val proposed = displayTranslate() + dragAmount
                        rawTranslate = when {
                            proposed < minAnchor ->
                                minAnchor - (minAnchor - proposed) * VoiidSheetTokens.OVERDRAG_RESISTANCE
                            proposed > maxAnchor ->
                                maxAnchor + (proposed - maxAnchor) * VoiidSheetTokens.OVERDRAG_RESISTANCE
                            else -> proposed
                        }
                    }
                }
                .navigationBarsPadding(),
        ) {
            if (showHandle) {
                Spacer(Modifier.height(8.dp))
                Box(
                    Modifier
                        .width(40.dp)
                        .height(4.dp)
                        .clip(RoundedCornerShape(2.dp))
                        .background(VoiidColor.divider.copy(alpha = 0.6f)),
                )
                Spacer(Modifier.height(6.dp))
            }
            Column(
                Modifier
                    .fillMaxWidth()
                    .onSizeChanged { if (detents.any { it is VoiidDetent.Content }) contentH = it.height },
            ) {
                content()
            }
        }
    }
}
