package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import com.voiid.app.ui.theme.LudoThemeColors
import kotlin.math.acos
import kotlin.math.max
import kotlin.math.min

/**
 * The code-drawn token (§4): a map-pin disc with a tail drawn to a point, a hollow centre, and a
 * ground ellipse. ONE normalized path for all colors; surfaces stay BLANK — no numbers, faces,
 * initials or symbols.
 *
 * Two states: ACTIVE (full saturation, soft colored glow) when the current roll can be played
 * with that token, INACTIVE (desaturated, no glow) otherwise. Two themes: a white border in
 * light and a light grey-white one in dark, each with a thin outline for contrast.
 */
object LudoPawnPath {

    const val WIDTH_FACTOR = 0.78f
    const val HEIGHT_FACTOR = 1.02f

    /**
     * Built as a circle plus the two tangents to the tip, so the tail meets the disc smoothly at
     * any proportion rather than at a visible seam.
     */
    fun path(width: Float, height: Float): Path {
        val cx = 0.5f * width
        val cy = 0.36f * height
        val r = 0.33f * width
        val tipY = 0.80f * height
        val d = tipY - cy
        val betaDeg = if (d > r) Math.toDegrees(acos(min(1f, r / d).toDouble())).toFloat() else 0f

        return Path().apply {
            // Sweeping from 90+β by (360 − 2β) passes left, over the top, to the right tangent.
            arcTo(
                rect = Rect(cx - r, cy - r, cx + r, cy + r),
                startAngleDegrees = 90f + betaDeg,
                sweepAngleDegrees = 360f - 2f * betaDeg,
                forceMoveTo = true,
            )
            lineTo(cx, tipY)
            close()
        }
    }

    /** The hollow centre of the pin head. */
    fun holeRect(width: Float, height: Float): Rect {
        val r = 0.132f * width
        return Rect(0.5f * width - r, 0.36f * height - r, 0.5f * width + r, 0.36f * height + r)
    }

    /** The ground ellipse the pin stands on, so a token reads as placed rather than floating. */
    fun baseRect(width: Float, height: Float): Rect {
        val rx = 0.30f * width
        val ry = 0.115f * width
        return Rect(
            0.5f * width - rx, 0.845f * height - ry,
            0.5f * width + rx, 0.845f * height + ry,
        )
    }

    /**
     * Draws one token with its top-left at [origin].
     *
     * Layering runs widest-first — outline, then border, then the colour — so the border comes
     * from three strokes of ONE path instead of three separately inset paths that would drift
     * apart at small sizes.
     */
    fun DrawScope.drawPawn(
        origin: Offset,
        width: Float,
        height: Float,
        hue: Color,
        active: Boolean,
        colors: LudoThemeColors,
    ) {
        translate(origin.x, origin.y) {
            val pin = path(width, height)
            val baseR = baseRect(width, height)
            val base = Path().apply { addOval(baseR) }
            val border = max(1.2f, width * 0.085f)
            val outline = max(0.7f, width * 0.032f)
            val fill = if (active) hue else muted(hue)

            // Contact shadow first, under everything.
            drawOval(
                Color.Black.copy(alpha = 0.16f),
                Offset(baseR.left - width * 0.02f, baseR.top + height * 0.012f - width * 0.01f),
                androidx.compose.ui.geometry.Size(
                    baseR.width + width * 0.04f, baseR.height + width * 0.02f,
                ),
            )

            // Active glow: concentric strokes fading outward. Cheaper than a real blur and it
            // stays crisp at every board size.
            if (active) {
                for (step in 3 downTo 1) {
                    val spread = border + step * width * 0.055f
                    drawPath(
                        pin,
                        hue.copy(alpha = 0.052f * (4 - step) + 0.03f),
                        style = Stroke(width = spread * 2f, join = StrokeJoin.Round),
                    )
                }
            }

            for (shape in listOf(base, pin)) {
                drawPath(
                    shape, colors.c(colors.pawnOutline),
                    style = Stroke(width = border * 2f + outline * 2f, join = StrokeJoin.Round),
                )
                drawPath(
                    shape, colors.c(colors.pawnBorder),
                    style = Stroke(width = border * 2f, join = StrokeJoin.Round),
                )
            }
            drawPath(base, fill)
            drawPath(pin, fill)

            // Hollow centre, in the border colour so it reads as a hole punched through.
            val hole = holeRect(width, height)
            drawOval(
                colors.c(colors.pawnBorder),
                Offset(hole.left, hole.top),
                androidx.compose.ui.geometry.Size(hole.width, hole.height),
            )
        }
    }

    /** Desaturated, muted version of a seat hue for a token that cannot move this turn. */
    fun muted(base: Color): Color {
        val luma = 0.299f * base.red + 0.587f * base.green + 0.114f * base.blue
        // Partway to its own grey, then lifted slightly. Enough desaturation to read as "not
        // playable this turn", but the seat is still identifiable at a glance — a token pulled
        // all the way to grey loses which player it belongs to.
        fun mix(c: Float) = ((c * 0.58f + luma * 0.42f) * 0.80f + 0.15f).coerceIn(0f, 1f)
        return Color(mix(base.red), mix(base.green), mix(base.blue), 1f)
    }
}
