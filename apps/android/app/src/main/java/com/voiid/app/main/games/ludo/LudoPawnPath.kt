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
    const val WIDTH_FACTOR = 0.82f
    const val HEIGHT_FACTOR = 1.18f

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

        // Base body — rounded trapezoid.
        val baseTopY = 0.78f * h
        val baseBotY = 0.98f * h
        val insetTopBase = 0.10f * w
        val corner = 0.09f * w
        p.moveTo(0.05f * w + corner, baseBotY)
        lineTo(p, 0.95f * w - corner, baseBotY)
        cubicTo(
            p, 0.95f * w, baseBotY, 0.95f * w, baseBotY - corner,
            0.95f * w - insetTopBase * 0.4f, baseTopY + 0.02f * h,
        )
        lineTo(p, 0.76f * w + 0.02f * w, baseTopY)
        cubicTo(
            p, 0.80f * w, baseTopY, 0.72f * w, 0.70f * h,
            0.62f * w, 0.55f * h,
        )
        // Neck up to under the head.
        cubicTo(
            p, 0.56f * w, 0.44f * h, 0.56f * w, 0.40f * h, 0.575f * w, 0.345f * h,
        )
        lineTo(p, 0.425f * w, 0.345f * h)
        // Mirror down the left side.
        cubicTo(
            p, 0.44f * w, 0.40f * h, 0.44f * w, 0.44f * h, 0.38f * w, 0.55f * h,
        )
        cubicTo(
            p, 0.28f * w, 0.70f * h, 0.20f * w, baseTopY, 0.24f * w + 0.02f * w, baseTopY,
        )
        lineTo(p, 0.05f * w + insetTopBase * 0.4f, baseTopY + 0.02f * h)
        p.close()
        return p
    }

    private fun lineTo(p: Path, x: Float, y: Float) = p.lineTo(x, y)
    private fun cubicTo(
        p: Path, x1: Float, y1: Float, x2: Float, y2: Float, x3: Float, y3: Float,
    ) = p.cubicTo(x1, y1, x2, y2, x3, y3)

    /** Base top rim ellipse spanning x=0.11W..0.89W centered y=0.79H, height 0.16H. */
    fun rimPath(width: Float, height: Float): Path {
        val rect = Rect(
            left = 0.11f * width,
            top = 0.79f * height - 0.08f * height,
            right = 0.89f * width,
            bottom = 0.79f * height + 0.08f * height,
        )
        return Path().apply { addOval(rect) }
    }

    /**
     * Restrained head highlight: white arc at 14%/10% opacity, stroke 0.035W covering the
     * upper-left 70°. Material lighting, not a face (§4).
     */
    fun highlightArc(width: Float, height: Float): Path {
        val cx = 0.50f * width
        val cy = 0.20f * height
        val r = 0.185f * height
        val start = (-200.0).toRadians()   // upper-left sweep of 70 degrees
        val end = (-130.0).toRadians()
        return Path().apply {
            arcTo(
                rect = Rect(cx - r, cy - r, cx + r, cy + r),
                startAngleDegrees = Math.toDegrees(start).toFloat(),
                sweepAngleDegrees = Math.toDegrees(end - start).toFloat(),
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
