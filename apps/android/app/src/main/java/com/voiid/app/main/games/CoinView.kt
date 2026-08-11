package com.voiid.app.main.games

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.unit.sp
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.sin

/**
 * The spinning gold coin, drawn as a SOLID rather than a flat disc.
 *
 * WHY THIS IS HAND-DRAWN GEOMETRY. iOS renders this as a real SceneKit cylinder; Android has no
 * 3D framework in this project, and adding Filament/SceneView — several MB of native libraries
 * and a whole render surface — for one spinning object is a bad trade. So the cylinder is
 * projected by hand, which for a shape this simple is a dozen lines of maths and produces the
 * same silhouette.
 *
 * THE POINT IS THE SILHOUETTE. A coin turning is not a rectangle appearing at its edge — the rim
 * is a curved surface, so side-on it reads as a narrow ELLIPSE-ended band whose top and bottom
 * bow outward, never as a hard-cornered bar. Getting that outline right is most of what makes
 * this read as metal rather than as a card flipping, and it is exactly what a squashed
 * rectangle cannot do.
 *
 * Mirrors iOS `CoinSceneView.swift`: same gold, same milling, same landing behaviour.
 */
@Composable
fun CoinView(
    /** Null while the toss is undecided — the coin idles. Set to land it. */
    result: String?,
    modifier: Modifier = Modifier,
) {
    // Rotation in degrees about the vertical axis. One number drives the whole projection.
    val angle = remember { Animatable(0f) }
    val measurer = rememberTextMeasurer()

    LaunchedEffect(result) {
        if (result == null) {
            // Idle: a dead-still coin under "Heads or tails?" reads as a disabled control, and
            // turning it shows both faces before the player bets on one.
            angle.animateTo(
                targetValue = angle.value + 360f,
                animationSpec = androidx.compose.animation.core.infiniteRepeatable(
                    tween(3400, easing = LinearEasing),
                ),
            )
        } else {
            // LAND ON THE FACE THAT ACTUALLY CAME UP. The end angle is exact, not approximate:
            // a whole number of turns shows heads, a half turn more shows tails. Anything else
            // stops the coin edge-on or on the wrong side, contradicting the result printed
            // under it.
            val current = angle.value % 360f
            angle.snapTo(current)
            val turns = if (result == "heads") 5f else 5.5f
            angle.animateTo(
                targetValue = current - (current % 360f) + 360f * turns,
                animationSpec = tween(1150, easing = androidx.compose.animation.core.EaseOutCubic),
            )
        }
    }

    Canvas(modifier) {
        drawCoin(angle.value, measurer)
    }
}

// Gold, mixed by hand rather than taken from the theme: VoiidColor.accent is the app's amber,
// tuned for text on dark surfaces, not for a metal object that must read as gold on both themes.
private val GOLD = Color(0xFFD4A637)
private val GOLD_LIGHT = Color(0xFFEEC761)
private val GOLD_RIM = Color(0xFF735013)
private val GOLD_DARK = Color(0xFF8A6412)
private val GOLD_LETTER = Color(0xFF422C05)

/** Thickness as a fraction of the diameter. Real coins are thin; a fat one is a poker chip. */
private const val RELATIVE_THICKNESS = 0.11f
/** Fine, dense milling. Too few grooves and the rim reads as a barcode. */
private const val RIDGES = 44

private fun DrawScope.drawCoin(angleDeg: Float, measurer: TextMeasurer) {
    val rad = angleDeg * PI.toFloat() / 180f
    // How much of the FACE is toward the viewer: 1 flat on, 0 perfectly side-on. This is the
    // horizontal squash of a rotating disc, and every other measurement follows from it.
    val faceScale = cos(rad)
    // How side-on it is, 0-1. The rim's visible width.
    val edgeOn = abs(sin(rad))

    val diameter = size.minDimension * 0.74f
    val r = diameter / 2f
    val cx = size.width / 2f
    val cy = size.height / 2f
    val halfThickness = diameter * RELATIVE_THICKNESS / 2f

    // Where the two rim silhouettes sit. As the coin turns, the near and far faces separate
    // horizontally by the thickness — this offset IS the visible depth.
    val depth = halfThickness * edgeOn

    // --- the rim, drawn first so the face sits in front of it -----------------------------
    //
    // Built as a closed path from two arcs: the outer silhouette of the far face and of the
    // near face, joined top and bottom. That gives the BOWED outline a real cylinder has —
    // the thing a rectangle can never produce.
    if (edgeOn > 0.004f) {
        val faceHalfWidth = r * abs(faceScale)
        val rim = Path().apply {
            // Far edge, sweeping down one side.
            moveTo(cx - depth - faceHalfWidth, cy)
            arcTo(
                rect = Rect(
                    Offset(cx - depth - faceHalfWidth, cy - r),
                    Size(faceHalfWidth * 2f, r * 2f),
                ),
                startAngleDegrees = 180f, sweepAngleDegrees = 180f, forceMoveTo = false,
            )
            // Across to the near edge and back up the other side, closing the band.
            lineTo(cx + depth + faceHalfWidth, cy)
            arcTo(
                rect = Rect(
                    Offset(cx + depth - faceHalfWidth, cy - r),
                    Size(faceHalfWidth * 2f, r * 2f),
                ),
                startAngleDegrees = 0f, sweepAngleDegrees = -180f, forceMoveTo = false,
            )
            close()
        }

        drawPath(
            rim,
            Brush.horizontalGradient(
                0f to GOLD_RIM, 0.35f to GOLD, 0.5f to GOLD_LIGHT, 0.65f to GOLD, 1f to GOLD_RIM,
                startX = cx - depth - r, endX = cx + depth + r,
            ),
        )

        // MILLING. Each groove is a line of longitude on the cylinder, so its x follows
        // sin(theta) — grooves crowd together toward the silhouette exactly as they do on a
        // real turned edge, which is what stops this reading as flat stripes.
        for (i in 0 until RIDGES) {
            val theta = (i.toFloat() / RIDGES) * 2f * PI.toFloat()
            val x = sin(theta + rad)
            // Only the half facing the viewer is drawn.
            if (cos(theta + rad) <= 0f) continue
            val gx = cx + x * (depth + r * abs(faceScale) * 0f) + x * depth
            // Fade at the silhouette, where the surface turns away.
            val shade = (1f - abs(x)).coerceIn(0f, 1f)
            drawLine(
                color = GOLD_RIM.copy(alpha = 0.30f + 0.35f * shade),
                start = Offset(gx, cy - r * 0.985f),
                end = Offset(gx, cy + r * 0.985f),
                strokeWidth = size.minDimension * 0.006f,
            )
        }
    }

    // --- the face -------------------------------------------------------------------------
    //
    // An ellipse squashed by `faceScale`, offset to whichever side of the rim it belongs on.
    val faceHalfWidth = r * abs(faceScale)
    if (faceHalfWidth < 0.5f) return          // perfectly edge-on: nothing but rim to draw

    val faceCx = cx + (if (faceScale >= 0f) depth else -depth)
    val faceRect = Rect(
        Offset(faceCx - faceHalfWidth, cy - r),
        Size(faceHalfWidth * 2f, r * 2f),
    )

    drawOval(
        brush = Brush.verticalGradient(
            0f to GOLD_LIGHT, 0.45f to GOLD, 1f to GOLD_DARK,
            startY = cy - r, endY = cy + r,
        ),
        topLeft = faceRect.topLeft,
        size = faceRect.size,
    )

    // Struck rim, drawn INSIDE the edge so it reads as pressed metal rather than a ring
    // floating on top. Both inset amounts scale with the squash, or the border would appear to
    // thicken as the coin turns.
    val rimStroke = r * 0.10f
    drawOval(
        color = GOLD_RIM,
        topLeft = Offset(faceRect.left + rimStroke * abs(faceScale) * 0.5f, faceRect.top + rimStroke * 0.5f),
        size = Size(
            (faceRect.width - rimStroke * abs(faceScale)).coerceAtLeast(0.1f),
            (faceRect.height - rimStroke).coerceAtLeast(0.1f),
        ),
        style = Stroke(width = rimStroke * abs(faceScale).coerceAtLeast(0.08f)),
    )
    // A second, finer ridge — the detail that separates "gold circle" from "coin".
    val innerInset = r * 0.24f
    drawOval(
        color = GOLD_RIM.copy(alpha = 0.5f),
        topLeft = Offset(faceRect.left + innerInset * abs(faceScale), faceRect.top + innerInset),
        size = Size(
            (faceRect.width - innerInset * 2f * abs(faceScale)).coerceAtLeast(0.1f),
            (faceRect.height - innerInset * 2f).coerceAtLeast(0.1f),
        ),
        style = Stroke(width = r * 0.028f),
    )

    // --- the letter -------------------------------------------------------------------------
    //
    // H on one face, T on the other, chosen by which way the coin is pointing — so the faces
    // alternate as it turns, exactly like a real coin.
    val letter = if (faceScale >= 0f) "H" else "T"
    val fontPx = r * 1.05f
    val laid = measurer.measure(
        letter,
        TextStyle(
            color = GOLD_LETTER,
            fontSize = (fontPx / density).sp,
            fontWeight = FontWeight.Black,
        ),
    )
    // Squash the glyph horizontally by the same factor as the face, so it foreshortens WITH the
    // coin instead of sliding across it.
    val squash = abs(faceScale).coerceAtLeast(0.001f)
    drawContext.canvas.nativeCanvas.save()
    drawContext.canvas.nativeCanvas.scale(squash, 1f, faceCx, cy)
    drawText(
        laid,
        topLeft = Offset(faceCx - laid.size.width / 2f, cy - laid.size.height / 2f),
    )
    drawContext.canvas.nativeCanvas.restore()
}
