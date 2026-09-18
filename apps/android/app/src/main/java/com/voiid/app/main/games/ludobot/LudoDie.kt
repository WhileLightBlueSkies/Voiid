package com.voiid.app.main.games.ludobot

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import kotlin.math.cos
import kotlin.math.sin
import kotlin.math.sqrt

/**
 * Real 3D Tumbling Die with Recessed Tray (Android parity with iOS SceneKit `LudoDiceView.swift`).
 *
 * - Physically consistent 6-sided 3D cube (opposites sum to 7: 1-6, 2-5, 3-4).
 * - 3D perspective projection with real depth sorting & Lambert directional lighting.
 * - Smooth forward tumble ($4\pi$ pitch, $2\pi$ yaw) over 520ms matching iOS.
 * - Iconic Crimson Red Ace pip (Face 1) and glossy obsidian black pips (Faces 2–6).
 * - Lays 100% FLAT at rest, with tactile landing squash and dynamic tray floor cast shadow.
 * - Direct-tap on die or tray to roll.
 */
@Composable
fun LudoDie(
    value: Int,
    rolling: Boolean,
    enabled: Boolean,
    side: Dp = 74.dp,
    onClick: () -> Unit,
) {
    val reduceMotion = com.voiid.app.ui.components.reduceMotionEnabled()

    // 0f (start of roll) -> 1f (settled on result)
    val rollProgress = remember { Animatable(1f) }
    val squash = remember { Animatable(1f) }

    LaunchedEffect(rolling) {
        if (rolling && !reduceMotion) {
            rollProgress.snapTo(0f)
            squash.snapTo(1f)

            // 520ms smooth forward tumble roll (matching iOS SCNAction duration)
            rollProgress.animateTo(1f, tween(520, easing = FastOutSlowInEasing))

            // Landing micro-bounce (squash & stretch)
            squash.snapTo(1.06f)
            squash.animateTo(1f, spring(dampingRatio = 0.5f, stiffness = 450f))
        } else {
            rollProgress.snapTo(1f)
            squash.snapTo(1f)
        }
    }

    val displayValue = if (value in 1..6) value else 1

    // Recessed Wood & Brass Tray (Matches iOS DiceBox)
    Box(
        modifier = Modifier
            .size(side)
            .clip(RoundedCornerShape(13.dp))
            .background(
                Brush.radialGradient(
                    colors = listOf(Color(0xFF1E252E), Color(0xFF0F1318)),
                    radius = 120f,
                )
            )
            .border(1.dp, Color(0xFF8C7A58).copy(alpha = 0.40f), RoundedCornerShape(13.dp))
            .clickable(enabled = enabled) { onClick() },
        contentAlignment = Alignment.Center,
    ) {
        val dieSide = side * 0.72f

        Canvas(Modifier.size(dieSide)) {
            val s = size.minDimension
            val t = rollProgress.value
            val isResting = t >= 1f

            // Dynamic 3D rotation angles
            val rxDeg = if (isResting) 0f else 720f * (1f - t)
            val ryDeg = if (isResting) 0f else 360f * (1f - t)
            val liftPx = if (isResting) 0f else -sin(t * Math.PI.toFloat()) * s * 0.24f

            // 1. Dynamic Cast Shadow on Tray Floor
            val shadowLiftRatio = (-liftPx / (s * 0.24f)).coerceIn(0f, 1f)
            val shadowW = s * (0.88f - 0.20f * shadowLiftRatio)
            val shadowH = s * (0.30f - 0.10f * shadowLiftRatio)
            val shadowAlpha = 0.38f * (1f - 0.55f * shadowLiftRatio)
            drawOval(
                Color.Black.copy(alpha = shadowAlpha),
                topLeft = Offset((s - shadowW) / 2f, s * 0.76f),
                size = Size(shadowW, shadowH),
            )

            // 2. 3D Cube or Flat Resting Die
            translate(top = liftPx) {
                scale(squash.value, pivot = Offset(s / 2f, s / 2f)) {
                    if (isResting) {
                        drawFlatRestingDie(s, displayValue)
                    } else {
                        draw3DCube(s, displayValue, rxDeg, ryDeg)
                    }
                }
            }
        }
    }
}

// MARK: - 3D Geometry & Rendering

private data class Vec3(val x: Float, val y: Float, val z: Float) {
    operator fun times(k: Float) = Vec3(x * k, y * k, z * k)
}

private data class CubeFace(val value: Int, val normal: Vec3, val corners: List<Int>)

// 6 faces of the cube (opposites sum to 7)
private val BASE_FACES = listOf(
    Vec3(0f, 0f, 1f) to listOf(4, 5, 7, 6),    // front +Z
    Vec3(0f, 0f, -1f) to listOf(1, 0, 2, 3),   // back  -Z
    Vec3(1f, 0f, 0f) to listOf(5, 1, 3, 7),    // right +X
    Vec3(-1f, 0f, 0f) to listOf(0, 4, 6, 2),   // left  -X
    Vec3(0f, -1f, 0f) to listOf(4, 0, 1, 5),   // top   -Y
    Vec3(0f, 1f, 0f) to listOf(2, 6, 7, 3),    // bottom +Y
)

private fun getFaceValues(result: Int): List<Int> {
    val r = result.coerceIn(1, 6)
    val remaining = listOf(listOf(1, 6), listOf(2, 5), listOf(3, 4)).filter { r !in it }
    return listOf(
        r, 7 - r,
        remaining[0][0], remaining[0][1],
        remaining[1][0], remaining[1][1],
    )
}

private fun getFacesFor(result: Int): List<CubeFace> {
    val values = getFaceValues(result)
    return BASE_FACES.mapIndexed { i, (normal, corners) ->
        CubeFace(values[i], normal, corners)
    }
}

// 8 vertices of the unit cube
private fun cubeCorner(i: Int): Vec3 {
    val x = if (i and 1 == 0) -1f else 1f
    val y = if (i and 2 == 0) -1f else 1f
    val z = if (i and 4 == 0) -1f else 1f
    return Vec3(x, y, z)
}

private fun rad(deg: Float): Float = Math.toRadians(deg.toDouble()).toFloat()

// Key light from top-left front
private const val LX = -0.32f
private const val LY = -0.48f
private const val LZ = -1.0f
private val L_LEN = sqrt(LX * LX + LY * LY + LZ * LZ)

private fun lambert(n: Vec3): Float {
    val dot = (n.x * LX + n.y * LY + n.z * LZ) / L_LEN
    return (dot / (1f / L_LEN)).coerceIn(0f, 1f)
}

private fun rotateVec(v: Vec3, rx: Float, ry: Float): Vec3 {
    val cy = cos(rx); val sy = sin(rx)
    val y1 = v.y * cy - v.z * sy
    val z1 = v.y * sy + v.z * cy
    val cx = cos(ry); val sx = sin(ry)
    val x2 = v.x * cx + z1 * sx
    val z2 = -v.x * sx + z1 * cx
    return Vec3(x2, y1, z2)
}

/**
 * Projects and renders the true 3D solid cube with perspective foreshortening,
 * Lambert directional shading, and bilinear mapped pips on visible faces.
 */
private fun DrawScope.draw3DCube(
    s: Float,
    result: Int,
    rxDeg: Float,
    ryDeg: Float,
) {
    val rx = rad(rxDeg)
    val ry = rad(ryDeg)

    // Project all 8 corners with perspective
    val projected = Array(8) { i ->
        val c = cubeCorner(i) * (s / 2f)
        val r = rotateVec(c, rx, ry)
        val k = 1.75f / (1.75f + r.z / s)
        Offset(s / 2f + r.x * k, s / 2f + r.y * k)
    }

    // Depth-sort visible faces (back-face culled by normal.z)
    val visibleFaces = getFacesFor(result).mapNotNull { face ->
        val n = rotateVec(face.normal, rx, ry)
        if (n.z >= 0.02f) return@mapNotNull null // facing away from camera
        val depth = face.corners.sumOf { cornerIdx ->
            rotateVec(cubeCorner(cornerIdx) * s, rx, ry).z.toDouble()
        }
        face to (depth to n)
    }.sortedByDescending { it.second.first } // far -> near

    for ((face, data) in visibleFaces) {
        val (_, normal) = data
        val pts = face.corners.map { projected[it] }

        val quad = Path().apply {
            moveTo(pts[0].x, pts[0].y)
            for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
            close()
        }

        clipPath(quad) {
            // 1. Ivory Porcelain Body
            drawPath(quad, Color(0xFFF9F6F0))

            // 2. Lambert Directional Shading
            val shade = (1f - lambert(normal)) * 0.36f
            if (shade > 0.01f) {
                drawPath(quad, Color.Black.copy(alpha = shade))
            }

            // 3. Chamfer Edge Border
            drawPath(
                quad,
                Color(0xFFD4C8B6),
                style = Stroke(width = 1.2f, join = StrokeJoin.Round),
            )

            // 4. Project and Draw Pips for this Face
            drawProjectedFacePips(pts, face.value, s)
        }
    }
}

/**
 * Bilinear interpolation for placing pips on a projected 3D face quad.
 */
private fun DrawScope.drawProjectedFacePips(
    corners: List<Offset>,
    value: Int,
    s: Float,
) {
    fun lerp(a: Offset, b: Offset, t: Float) = Offset(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
    fun uvToPoint(u: Float, v: Float): Offset {
        val top = lerp(corners[0], corners[1], u)
        val bottom = lerp(corners[3], corners[2], u)
        return lerp(top, bottom, v)
    }

    val inset = 0.265f
    val step = (1f - 2 * inset) / 2f
    val left = inset
    val right = 1f - inset
    val mid = 0.5f

    val uvCenters = when (value) {
        1 -> listOf(mid to mid)
        2 -> listOf(left to left, right to right)
        3 -> listOf(left to left, mid to mid, right to right)
        4 -> listOf(left to left, right to left, left to right, right to right)
        5 -> listOf(left to left, right to left, mid to mid, left to right, right to right)
        6 -> listOf(
            left to left, right to left,
            left to mid, right to mid,
            left to right, right to right,
        )
        else -> listOf(mid to mid)
    }

    val isAce = value == 1
    val pipR = if (isAce) s * 0.13f else s * 0.082f
    val pipColor = if (isAce) Color(0xFFDE2B24) else Color(0xFF16161A)

    for ((u, v) in uvCenters) {
        val pt = uvToPoint(u, v)

        // Under-shadow
        drawCircle(
            Color.Black.copy(alpha = 0.26f),
            radius = pipR,
            center = Offset(pt.x, pt.y + s * 0.012f),
        )
        // Pip body
        drawCircle(pipColor, radius = pipR, center = pt)
        // Specular glint
        drawCircle(
            Color.White.copy(alpha = 0.78f),
            radius = pipR * 0.28f,
            center = Offset(pt.x - pipR * 0.30f, pt.y - pipR * 0.30f),
        )
    }
}

/**
 * Flat resting die: 100% square, upright, and sharp with dual bevel chamfers.
 */
private fun DrawScope.drawFlatRestingDie(s: Float, value: Int) {
    val corner = s * 0.20f
    val cornerRadius = CornerRadius(corner)

    // 1. Depth Chamfer Lip (bottom-right)
    drawRoundRect(
        color = Color(0xFFBFB19B),
        topLeft = Offset(0f, s * 0.038f),
        size = Size(s, s),
        cornerRadius = cornerRadius,
    )

    // 2. Pure Ivory Porcelain Gradient
    val ivoryGradient = Brush.linearGradient(
        colors = listOf(Color(0xFFFFFFFF), Color(0xFFF9F6F0), Color(0xFFECE4D4)),
        start = Offset.Zero,
        end = Offset(s, s),
    )
    drawRoundRect(
        brush = ivoryGradient,
        topLeft = Offset.Zero,
        size = Size(s, s),
        cornerRadius = cornerRadius,
    )

    // 3. 3D Convex Vignette
    val vignette = Brush.radialGradient(
        colors = listOf(Color.Transparent, Color(0xFFDED0BC).copy(alpha = 0.40f)),
        center = Offset(s / 2f, s / 2f),
        radius = s * 0.65f,
    )
    drawRoundRect(
        brush = vignette,
        topLeft = Offset.Zero,
        size = Size(s, s),
        cornerRadius = cornerRadius,
    )

    // 4. Bevel Highlight Lip (top-left)
    val highlightPath = Path().apply {
        moveTo(corner, 0f)
        lineTo(s - corner, 0f)
    }
    drawPath(highlightPath, Color.White.copy(alpha = 0.92f), style = Stroke(width = s * 0.035f))

    // 5. Outline Silhouette
    drawRoundRect(
        color = Color(0xFFD3C5AE),
        topLeft = Offset.Zero,
        size = Size(s, s),
        cornerRadius = cornerRadius,
        style = Stroke(width = 1f),
    )

    // 6. Draw Crisp Upright Pips
    drawFlatPips(s, value)
}

private fun DrawScope.drawFlatPips(s: Float, value: Int) {
    val margin = s * 0.265f
    val left = margin
    val right = s - margin
    val midX = s * 0.5f
    val top = margin
    val bottom = s - margin
    val midY = s * 0.5f

    val centers: List<Offset> = when (value) {
        1 -> listOf(Offset(midX, midY))
        2 -> listOf(Offset(left, top), Offset(right, bottom))
        3 -> listOf(Offset(left, top), Offset(midX, midY), Offset(right, bottom))
        4 -> listOf(Offset(left, top), Offset(right, top), Offset(left, bottom), Offset(right, bottom))
        5 -> listOf(Offset(left, top), Offset(right, top), Offset(midX, midY), Offset(left, bottom), Offset(right, bottom))
        6 -> listOf(
            Offset(left, top), Offset(right, top),
            Offset(left, midY), Offset(right, midY),
            Offset(left, bottom), Offset(right, bottom),
        )
        else -> listOf(Offset(midX, midY))
    }

    if (value == 1) {
        // Iconic Crimson Red Ace
        val r = s * 0.145f
        val c = centers[0]

        drawCircle(Color(0xFF5A0808).copy(alpha = 0.40f), radius = r, center = Offset(c.x, c.y + s * 0.018f))

        val crimsonGradient = Brush.radialGradient(
            colors = listOf(Color(0xFFFF3B30), Color(0xFFC41E18), Color(0xFF8B0D08)),
            center = Offset(c.x - r * 0.22f, c.y - r * 0.22f),
            radius = r * 1.1f,
        )
        drawCircle(crimsonGradient, radius = r, center = c)
        drawCircle(Color(0xFF580505).copy(alpha = 0.35f), radius = r, center = c, style = Stroke(width = 1.2f))
        drawCircle(Color.White.copy(alpha = 0.88f), radius = r * 0.28f, center = Offset(c.x - r * 0.32f, c.y - r * 0.32f))
    } else {
        // Obsidian Black Pips
        val r = s * 0.086f
        for (c in centers) {
            drawCircle(Color.Black.copy(alpha = 0.35f), radius = r, center = Offset(c.x, c.y + s * 0.014f))

            val obsidianGradient = Brush.radialGradient(
                colors = listOf(Color(0xFF2C2C32), Color(0xFF141417), Color(0xFF08080A)),
                center = Offset(c.x - r * 0.25f, c.y - r * 0.25f),
                radius = r * 1.15f,
            )
            drawCircle(obsidianGradient, radius = r, center = c)
            drawCircle(Color.White.copy(alpha = 0.82f), radius = r * 0.30f, center = Offset(c.x - r * 0.30f, c.y - r * 0.30f))
        }
    }
}
