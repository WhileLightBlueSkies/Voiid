package com.voiid.app.main.games

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * A die that tumbles as a SOLID (docs/games/VISUALS_AUDIO_AND_PARITY.md §5.3).
 *
 * WHY THIS EXISTS. The die was a flat pip face with a face-swap tumble, and it is the most-watched
 * object in the game — it is on screen for every single turn. Ludo King's die tumbles as a cube,
 * and that is most of why its rolls feel like rolls.
 *
 * HAND-PROJECTED, NOT A 3D FRAMEWORK. This is the exact trade [CoinView] already made for the
 * coin: adding Filament for one spinning object is a bad deal, and a cube is EASIER than a
 * cylinder — eight vertices, a fixed camera, back-face culling, three visible faces.
 *
 * THE LANDED FACE IS THE SERVER'S. The tumble is presentation; the frame is the truth. Nothing in
 * this file ever picks a number — [face] comes in from `LudoState.die` and the rotation settles to
 * show it.
 *
 * Ported from iOS `LudoDie.swift`.
 */
private val CUBE_CORNERS = listOf(
    Triple(-1.0, -1.0, -1.0), Triple(1.0, -1.0, -1.0),
    Triple(1.0, 1.0, -1.0), Triple(-1.0, 1.0, -1.0),
    Triple(-1.0, -1.0, 1.0), Triple(1.0, -1.0, 1.0),
    Triple(1.0, 1.0, 1.0), Triple(-1.0, 1.0, 1.0),
)

/**
 * The six faces, as corner indices, with the die value each carries.
 *
 * Opposite faces sum to 7, as on a real die. That is not decoration — a player who can see two
 * faces at once will notice if the arithmetic is wrong.
 */
private val CUBE_FACES = listOf(
    listOf(4, 5, 6, 7) to 1,   // +z
    listOf(1, 2, 6, 5) to 2,   // +x
    listOf(3, 2, 6, 7) to 3,   // +y
    listOf(0, 1, 5, 4) to 4,   // -y
    listOf(0, 3, 7, 4) to 5,   // -x
    listOf(0, 1, 2, 3) to 6,   // -z
)

private val PIP_LAYOUTS = mapOf(
    1 to listOf(1 to 1),
    2 to listOf(0 to 0, 2 to 2),
    3 to listOf(0 to 0, 1 to 1, 2 to 2),
    4 to listOf(0 to 0, 2 to 0, 0 to 2, 2 to 2),
    5 to listOf(0 to 0, 2 to 0, 1 to 1, 0 to 2, 2 to 2),
    6 to listOf(0 to 0, 2 to 0, 0 to 1, 2 to 1, 0 to 2, 2 to 2),
)

private val DiePip = Color(0.16f, 0.14f, 0.18f)

/**
 * Rotation that brings [value]'s face toward the camera, so the die SETTLES on the server's
 * number rather than landing on whatever the tumble happened to leave facing out.
 */
private fun restRotation(value: Int): Pair<Double, Double> = when (value) {
    1 -> 0.0 to 0.0
    2 -> 0.0 to -Math.PI / 2
    3 -> Math.PI / 2 to 0.0
    4 -> -Math.PI / 2 to 0.0
    5 -> 0.0 to Math.PI / 2
    else -> Math.PI to 0.0
}

/** Y first, then X. Order is fixed so the rest rotations above stay correct. */
private fun rotatePoint(p: Triple<Double, Double, Double>, x: Double, y: Double):
    Triple<Double, Double, Double> {
    val cy = cos(y); val sy = sin(y)
    val ax = p.first * cy + p.third * sy
    val ay = p.second
    val az = -p.first * sy + p.third * cy
    val cx = cos(x); val sx = sin(x)
    return Triple(ax, ay * cx - az * sx, ay * sx + az * cx)
}

/** Weak perspective. A real projection matrix is more code for a difference nobody can see. */
private fun projectPoint(p: Triple<Double, Double, Double>, half: Float): Offset {
    val depth = 4.2
    val k = depth / (depth - p.third * 0.45)
    return Offset(
        half + (p.first * k).toFloat() * half * 0.52f,
        half + (p.second * k).toFloat() * half * 0.52f,
    )
}

@Composable
fun LudoDie(
    /** The face to land on. The tumble settles to show exactly this. */
    face: Int,
    modifier: Modifier = Modifier,
    /** 0 = settled, 1 = mid-tumble. Driven by the caller's animation. */
    tumble: Float = 0f,
    bodyColor: Color = Color.White,
) {
    Canvas(modifier.fillMaxSize()) {
        val half = min(size.width, size.height) / 2f
        val (restX, restY) = restRotation(face.coerceIn(1, 6))
        // TUMBLE ON TWO AXES, settling to the rest rotation. Two, not one: a die spinning on a
        // single axis reads as a wheel.
        val rx = restX + tumble * 4.2 * Math.PI
        val ry = restY + tumble * 3.1 * Math.PI

        val rotated = CUBE_CORNERS.map { rotatePoint(it, rx, ry) }
        val projected = rotated.map { projectPoint(it, half) }

        // BACK-FACE CULLING by winding order, then paint back-to-front. Three faces are visible
        // on a cube from any angle; drawing all six in order would put a back face over a front.
        data class Visible(val z: Double, val path: Path, val bounds: Rect, val value: Int)
        val visible = mutableListOf<Visible>()
        for ((indices, value) in CUBE_FACES) {
            val pts = indices.map { projected[it] }
            var area = 0f
            for (i in pts.indices) {
                val a = pts[i]
                val b = pts[(i + 1) % pts.size]
                area += (b.x - a.x) * (b.y + a.y)
            }
            if (area <= 0f) continue

            val path = Path().apply {
                moveTo(pts[0].x, pts[0].y)
                pts.drop(1).forEach { lineTo(it.x, it.y) }
                close()
            }
            val depth = indices.map { rotated[it].third }.average()
            visible.add(Visible(depth, path, path.getBounds(), value))
        }
        visible.sortBy { it.z }

        for (v in visible) {
            // Faces angled away from the light are darker — one directional shade is what makes
            // the cube read as a solid rather than as three flat quads.
            val shade = (0.72 + 0.28 * ((v.z + 1) / 2)).toFloat()
            // Fill, then darken with black at the complement — a real multiply, rather than
            // dropping the fill's own alpha, which would let the board show through the die.
            drawPath(v.path, bodyColor)
            drawPath(v.path, Color.Black.copy(alpha = 1f - shade))
            drawPath(v.path, DiePip.copy(alpha = 0.30f), style = Stroke(width = 0.8f))
            drawPips(v.bounds, v.value, shade)
        }
    }
}

/**
 * Pips on a face, laid out in the face's own bounding box.
 *
 * An approximation — the exact thing would project each pip through the same transform — but at
 * this size the difference is under a pixel and the box is stable.
 */
private fun DrawScope.drawPips(rect: Rect, value: Int, shade: Float) {
    val unitW = rect.width / 3f
    val unitH = rect.height / 3f
    val r = min(unitW, unitH) * 0.22f
    for ((px, py) in PIP_LAYOUTS[value] ?: emptyList()) {
        drawCircle(
            color = DiePip.copy(alpha = (0.55f + 0.45f * shade).coerceAtMost(1f)),
            radius = r,
            center = Offset(
                rect.left + (px + 0.5f) * unitW,
                rect.top + (py + 0.5f) * unitH,
            ),
        )
    }
}
