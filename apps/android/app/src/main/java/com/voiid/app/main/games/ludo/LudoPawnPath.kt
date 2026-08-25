package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import kotlin.math.cos
import kotlin.math.sin

/**
 * The code-drawn pawn silhouette (§4): circular dome head, tapered body, broad rimmed base,
 * small contact shadow. ONE normalized Path for all colors; surfaces stay BLANK — no numbers,
 * faces, initials or symbols. Color is supported by lanes, safe symbols and finish slots.
 */
object LudoPawnPath {

    /** Visual box is 0.82 × 1.18 cellSide, centered on the cell, allowed to rise above it. */
    const val WIDTH_FACTOR = 0.64f
    const val HEIGHT_FACTOR = 1.14f

    /**
     * Normalized path over a box of width W and height H:
     *  - head: circle at (0.50W, 0.20H), radius 0.185H
     *  - neck from y=0.32H between x=0.38W..0.62W
     *  - body flares to x=0.24W..0.76W by y=0.77H
     *  - base top rim ellipse x=0.11W..0.89W centered y=0.79H, height 0.16H
     *  - base body rounded trapezoid y=0.78H..0.98H, x=0.05W..0.95W, corner 0.09W
     */
    fun path(width: Float, height: Float): Path {
        val w = width
        val h = height
        val p = Path()

        p.moveTo(.32f*w,.31f*h); p.lineTo(.68f*w,.31f*h)
        p.cubicTo(.73f*w,.52f*h,.78f*w,.64f*h,.85f*w,.71f*h)
        p.cubicTo(.96f*w,.71f*h,w,.76f*h,w,.82f*h); p.lineTo(w,.89f*h)
        p.cubicTo(.82f*w,.99f*h,.68f*w,h,.50f*w,h)
        p.cubicTo(.32f*w,h,.18f*w,.99f*h,0f,.89f*h); p.lineTo(0f,.82f*h)
        p.cubicTo(0f,.76f*h,.04f*w,.71f*h,.15f*w,.71f*h)
        p.cubicTo(.22f*w,.64f*h,.27f*w,.52f*h,.32f*w,.31f*h)
        p.close()
        val headRadius = .175f*h
        p.addOval(Rect(.5f*w-headRadius, 0f, .5f*w+headRadius, .35f*h))
        return p
    }

    private fun lineTo(p: Path, x: Float, y: Float) = p.lineTo(x, y)
    private fun cubicTo(
        p: Path, x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float,
    ) = p.cubicTo(x1, y1, x2, y2, x3, y3)

    /** Base top rim ellipse spanning x=0.11W..0.89W centered y=0.79H, height 0.16H. */
    fun rimPath(width: Float, height: Float): Path {
        return Path().apply {
            moveTo(.04f*width,.735f*height)
            cubicTo(.20f*width,.82f*height,.80f*width,.82f*height,.96f*width,.735f*height)
        }
    }

    /**
     * Restrained head highlight: white arc at 14%/10% opacity, stroke 0.035W covering the
     * upper-left 70°. Material lighting, not a face (§4).
     */
    fun highlightArc(width: Float, height: Float): Path {
        val cx = 0.50f * width
        val cy = 0.175f * height
        val r = 0.175f * height
        return Path().apply {
            arcTo(
                rect = Rect(cx - r, cy - r, cx + r, cy + r),
                startAngleDegrees = 20f,
                sweepAngleDegrees = 140f,
                forceMoveTo = true,
            )
        }
    }

    private fun Double.toRadians(): Double = this * Math.PI / 180.0

    /**
     * Darker same-hue rim color for the base line: RGB × 0.78 light / 0.72 dark (§4).
     */
    fun rimColor(base: Color, darkTheme: Boolean): Color {
        val f = if (darkTheme) 0.72f else 0.78f
        return Color(
            red = (base.red * f).coerceIn(0f, 1f),
            green = (base.green * f).coerceIn(0f, 1f),
            blue = (base.blue * f).coerceIn(0f, 1f),
            alpha = 1f,
        )
    }

    /** A legal pawn's halo: external 2dp ring in its hue at 45% opacity (breathes once). */
    fun haloPath(width: Float, height: Float): Path {
        val inflate = 6f
        return Path().apply {
            addPath(path(width + inflate * 2, height + inflate * 2), Offset(-inflate, -inflate))
        }
    }

    private fun addPath(receiver: Path, extra: Path, offset: Offset) {
        receiver.op(receiver, extra, androidx.compose.ui.graphics.PathOperation.Union)
    }
}
