package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
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

    // 80% of the cell, so a token sits INSIDE its square instead of spilling over its
    // neighbours. The pin is drawn at 0.8 of the size it was first cut at.
    const val WIDTH_FACTOR = 0.62f
    const val HEIGHT_FACTOR = 0.82f

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
    /** How much larger a playable token draws than a resting one. */
    const val ACTIVE_SCALE = 1.14f

    fun DrawScope.drawPawn(
        origin: Offset,
        width: Float,
        height: Float,
        hue: Color,
        active: Boolean,
        colors: LudoThemeColors,
        /** Advances the marching dashes on a playable token; only the fraction matters. */
        dashPhase: Float = 0f,
    ) {
        translate(origin.x, origin.y) {
            val pin = path(width, height)
            val baseR = baseRect(width, height)
            val base = Path().apply { addOval(baseR) }
            // A playable token carries a heavier border as well as the ring, so the difference
            // survives at small board sizes where a 1dp dash is nearly invisible.
            val border = max(1.2f, width * (if (active) 0.105f else 0.085f))
            val outline = max(0.7f, width * 0.032f)
            // FULL COLOUR IN BOTH STATES. Tokens used to desaturate when they were not playable,
            // which meant a token changed colour halfway through its own walk: the turn advances
            // the moment the move commits, so the pawn still travelling stopped being "legal"
            // and washed out mid-step. Playability is carried by the ring, the glow and the size
            // — never by the seat's colour, which has to stay readable as identity at all times.
            val fill = hue

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

            val hole = holeRect(width, height)

            // Specular: small, off-centre, up-left, sitting on the dome ABOVE the hole. Placement
            // matters more than size — centred it reads as a blemish, offset it reads as a curved
            // surface catching a light, which is what turns a flat disc into a moulded piece.
            // Drawn before the hole so the hole punches through it rather than the other way
            // round. Mirrors iOS `LudoPawnShape.draw`.
            drawOval(
                Color.White.copy(alpha = .38f),
                Offset(hole.center.x - width * .26f, hole.center.y - height * .20f),
                androidx.compose.ui.geometry.Size(width * .20f, height * .10f),
            )

            // Hollow centre, in the border colour so it reads as a hole punched through.
            drawOval(
                colors.c(colors.pawnBorder),
                Offset(hole.left, hole.top),
                androidx.compose.ui.geometry.Size(hole.width, hole.height),
            )

            // Marching dashes around a playable token. Motion is what makes it read as an
            // invitation rather than decoration, and it survives colour-blindness and dark mode
            // in a way a hue change never could.
            if (active) {
                val ringInset = border + outline + width * 0.085f
                val ring = path(width + ringInset * 2f, height + ringInset * 2f)
                val dash = width * 0.20f
                val intervals = floatArrayOf(dash, dash * 0.75f)
                translate(-ringInset, -ringInset) {
                    drawPath(
                        ring, colors.c(colors.pawnOutline).copy(alpha = 0.55f),
                        style = Stroke(
                            width = max(1.1f, width * 0.052f),
                            cap = StrokeCap.Round, join = StrokeJoin.Round,
                            pathEffect = PathEffect.dashPathEffect(
                                intervals, -dashPhase * dash * 3.2f),
                        ),
                    )
                    drawPath(
                        ring, colors.c(colors.pawnBorder),
                        style = Stroke(
                            width = max(0.8f, width * 0.030f),
                            cap = StrokeCap.Round, join = StrokeJoin.Round,
                            pathEffect = PathEffect.dashPathEffect(
                                intervals, -dashPhase * dash * 3.2f),
                        ),
                    )
                }
            }
        }
    }

}
