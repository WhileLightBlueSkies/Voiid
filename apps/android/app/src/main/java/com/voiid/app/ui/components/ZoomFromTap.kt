package com.voiid.app.ui.components

import androidx.compose.animation.EnterTransition
import androidx.compose.animation.ExitTransition
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.TransformOrigin
import androidx.compose.ui.input.pointer.PointerEventPass
import androidx.compose.ui.input.pointer.changedToDown
import androidx.compose.ui.input.pointer.pointerInput

/**
 * WHERE THE LAST TAP LANDED, so a page can open OUT OF the tile that was tapped — a chat
 * from its grid tile, a game from its card, a community from its row — and close back into
 * it, the way iOS's zoom transitions keep a page feeling like part of the grid it came from.
 *
 * One recorder on the root sees every touch-down (Initial pass, never consumed), so no tile
 * has to be wired individually. A tap older than [FRESH_MS] is stale (the page opened for
 * some other reason: a deep link, a push) and the page grows from the centre instead.
 */
object TapOrigin {
    private const val FRESH_MS = 1500L
    @Volatile private var fx = 0.5f
    @Volatile private var fy = 0.5f
    @Volatile private var at = 0L

    internal fun record(x: Float, y: Float) { fx = x; fy = y; at = System.currentTimeMillis() }

    fun current(): TransformOrigin =
        if (System.currentTimeMillis() - at < FRESH_MS) TransformOrigin(fx, fy) else TransformOrigin.Center
}

/** Put on the app's root container. Records touch-downs; never consumes them. */
fun Modifier.recordTapOrigin(): Modifier = this.pointerInput(Unit) {
    awaitPointerEventScope {
        while (true) {
            val event = awaitPointerEvent(PointerEventPass.Initial)
            event.changes.firstOrNull { it.changedToDown() }?.let {
                if (size.width > 0 && size.height > 0)
                    TapOrigin.record(it.position.x / size.width, it.position.y / size.height)
            }
        }
    }
}

private class OriginHolder { var origin = TransformOrigin.Center; var wasVisible = false }

/**
 * The origin a page opened from, captured the moment it becomes visible and HELD until it
 * closes — so it shrinks back to the tile it came from, not to wherever the Back tap was.
 */
@Composable
fun rememberZoomOrigin(visible: Boolean): TransformOrigin {
    val h = remember { OriginHolder() }
    if (visible && !h.wasVisible) h.origin = TapOrigin.current()
    h.wasVisible = visible
    return h.origin
}

private val Emphasized = CubicBezierEasing(0.2f, 0f, 0f, 1f)
private val EmphasizedAccel = CubicBezierEasing(0.3f, 0f, 0.8f, 0.15f)

fun zoomEnter(origin: TransformOrigin): EnterTransition =
    scaleIn(tween(320, easing = Emphasized), initialScale = 0.14f, transformOrigin = origin) +
        fadeIn(tween(160))

fun zoomExit(origin: TransformOrigin): ExitTransition =
    scaleOut(tween(240, easing = EmphasizedAccel), targetScale = 0.14f, transformOrigin = origin) +
        fadeOut(tween(200, delayMillis = 40))
