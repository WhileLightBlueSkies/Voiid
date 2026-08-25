package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.asAndroidPath
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

/**
 * Turn-border sweep (§12). The perimeter is a rounded rectangle inset by half the stroke;
 * anchors are normalized clockwise fractions: red 0.00 bottom-left, green 0.25 top-left,
 * yellow 0.50 top-right, blue 0.75 bottom-right.
 *
 * CONSTRUCTION (§12.2): the OLD hue stays as the base full stroke; a new-hue OVERLAY travels
 * from the outgoing anchor to the incoming anchor using path trim with WRAPPED segments when
 * the phase crosses path length. Rounded leading cap during travel, butt cap at completion.
 * Never two cross-faded borders, never a gradient disguise.
 */
object LudoTurnBorder {

    /** Phase from seat A to seat B clockwise, in [0,1): adjacent 0.25, duel opposite 0.5, wrap 0.75. */
    fun sweepPhase(fromSeat: Int, toSeat: Int): Float {
        val delta = ((toSeat - fromSeat) % 4 + 4) % 4
        return delta / 4f
    }

    /**
     * Draw one frame of the border.
     *
     * @param baseColor steady full border under everything (old hue, or podBorder waiting)
     * @param overlayColor traveling new hue, or null when resting
     * @param phaseStart normalized start anchor of travel
     * @param progress 0..1 along the FULL perimeter from phaseStart (eased by the caller)
     */
    fun DrawScope.drawBorder(
        rectPath: Path,
        strokePx: Float,
        baseColor: Color,
        overlayColor: Color?,
        phaseStart: Float,
        progress: Float,
    ) {
        // Base full stroke — butt caps, continuous.
        drawPath(rectPath, baseColor, style = Stroke(strokePx))

        val overlay = overlayColor ?: return
        if (progress <= 0f) return
        if (progress >= 1f) {
            // Completion replaces the base hue entirely (§12.2).
            drawPath(rectPath, overlay, style = Stroke(strokePx))
            return
        }
        // Traveling segment may wrap past path length; draw up to two sub-strokes.
        val total = 1f
        val head = (phaseStart + progress * total) % 1f
        val tail = phaseStart % 1f
        if (tail < head) {
            trimStroke(rectPath, overlay, strokePx, tail, head, rounded = true)
        } else {
            trimStroke(rectPath, overlay, strokePx, tail, 1f, rounded = true)
            trimStroke(rectPath, overlay, strokePx, 0f, head, rounded = true)
        }
    }

    /**
     * Android has no native path-trim; PathMeasure.getSegment provides exact wrapped
     * segments (§18.2). The segment is written into the backing store of a fresh compose
     * Path via its own asAndroidPath().
     */
    /**
     * One arc of [length] (0..1 of the perimeter) starting at [phaseStart], wrapping if it runs
     * past the end of the path. Used by the turn clock, which shortens this arc from the active
     * seat's own anchor as their window runs down.
     */
    fun DrawScope.drawArc(
        path: Path,
        strokePx: Float,
        color: Color,
        phaseStart: Float,
        length: Float,
    ) {
        if (length >= 1f) {
            drawPath(path, color, style = Stroke(strokePx))
            return
        }
        val tail = phaseStart % 1f
        val head = tail + length
        if (head <= 1f) {
            trimStroke(path, color, strokePx, tail, head, rounded = false)
        } else {
            trimStroke(path, color, strokePx, tail, 1f, rounded = false)
            trimStroke(path, color, strokePx, 0f, head - 1f, rounded = false)
        }
    }

    private fun DrawScope.trimStroke(
        path: Path,
        color: Color,
        strokePx: Float,
        fromFrac: Float,
        toFrac: Float,
        rounded: Boolean,
    ) {
        if (toFrac <= fromFrac) return
        val pm = android.graphics.PathMeasure()
        pm.setPath(path.asAndroidPath(), false)
        val len = pm.length
        if (len <= 0f) return
        val start = len * fromFrac
        val stop = len * toFrac
        if (stop - start <= 0.5f) return
        val out = Path()
        if (!pm.getSegment(start, stop, out.asAndroidPath(), true)) return
        drawPath(
            out,
            color,
            style = Stroke(
                width = strokePx,
                cap = if (rounded) StrokeCap.Round else StrokeCap.Butt,
            ),
        )
    }
}
