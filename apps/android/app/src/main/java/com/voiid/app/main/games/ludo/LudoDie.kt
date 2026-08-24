package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import com.voiid.app.ui.theme.LudoThemeColors
import kotlin.math.cos
import kotlin.math.sin

/**
 * The 2.5D projected die (§14). Same cube on both platforms, drawn in Canvas — all six rounded
 * faces and pips code-generated, no texture pipeline, deterministic parity.
 *
 * PHYSICALLY CONSISTENT FACES (opposites sum to 7):
 *   front +Z = 1   back -Z = 6    right +X = 2   left -X = 5    top -Y = 3   bottom +Y = 4
 *
 * At rest the displayed result faces the viewer with a fixed three-quarter pose of x=-8°,
 * y=+10°. Pips use the CURRENT ACTIVE HUE on all six faces simultaneously; the body is one
 * neutral token in every state and never changes color during a roll or turn change (§1).
 */
object LudoDie {

    /** Pip layouts as (column,row) in 0..2; grid coordinates at 0.23 / 0.50 / 0.77. */
    val PIPS: Map<Int, List<Pair<Int, Int>>> = mapOf(
        1 to listOf(1 to 1),
        2 to listOf(0 to 0, 2 to 2),
        3 to listOf(0 to 0, 1 to 1, 2 to 2),
        4 to listOf(0 to 0, 2 to 0, 0 to 2, 2 to 2),
        5 to listOf(0 to 0, 2 to 0, 1 to 1, 0 to 2, 2 to 2),
        6 to listOf(0 to 0, 2 to 0, 0 to 1, 2 to 1, 0 to 2, 2 to 2),
    )

    private data class V3(val x: Float, val y: Float, val z: Float)

    private data class FaceDef(val value: Int, val normal: V3, val corners: List<Int>)

    // Corner order per face is a consistent CCW loop seen from OUTSIDE.
    private val FACES = listOf(
        FaceDef(1, V3(0f, 0f, 1f), listOf(4, 5, 7, 6)),   // front +Z : (-,-,+)(+,-,+)(+,+,+)(-,+,+)
        FaceDef(6, V3(0f, 0f, -1f), listOf(1, 0, 2, 3)),  // back  -Z
        FaceDef(2, V3(1f, 0f, 0f), listOf(5, 1, 3, 7)),   // right +X
        FaceDef(5, V3(-1f, 0f, 0f), listOf(0, 4, 6, 2)),  // left  -X
        FaceDef(3, V3(0f, -1f, 0f), listOf(4, 0, 1, 5)),  // top   -Y
        FaceDef(4, V3(0f, 1f, 0f), listOf(2, 6, 7, 3)),   // bottom +Y
    )

    // Corner index → sign vector: bit0 x, bit1 y, bit2 z (value −1 / +1).
    private fun corner(i: Int): V3 {
        val x = if (i and 1 == 0) -1f else 1f
        val y = if (i and 2 == 0) -1f else 1f
        val z = if (i and 4 == 0) -1f else 1f
        return V3(x, y, z)
    }

    /** Rest pose showing `value` at the viewer with the fixed three-quarter tilt (§14.1). */
    fun restAngles(value: Int): Pair<Float, Float> = when (value) {
        1 -> 0f to 0f       // front
        6 -> 180f to 0f     // back
        2 -> 0f to -90f     // right
        5 -> 0f to 90f      // left
        3 -> 90f to 0f      // top toward viewer
        else -> -90f to 0f  // bottom toward viewer
    }

    /**
     * Draw the die centered in the current box. `pose` carries rotation + impact squash +
     * airborne lift; pips take the ACTIVE hue (neutral when no decision is open).
     */
    fun DrawScope.drawDie(
        sidePx: Float,
        value: Int,
        rotationXDeg: Float,
        rotationYDeg: Float,
        translationYPx: Float,
        scaleX: Float,
        scaleY: Float,
        pipColor: Color,
        edgeStrokePx: Float,
        colors: LudoThemeColors,
    ) {
        translate(center.x - sidePx / 2, center.y - sidePx / 2 + translationYPx) {
            scale(scaleX, scaleY, pivot = Offset(sidePx / 2, sidePx / 2)) {
                drawCube(sidePx, value, rotationXDeg, rotationYDeg, pipColor, edgeStrokePx, colors)
            }
        }
    }

    private fun rad(deg: Float): Float = Math.toRadians(deg.toDouble()).toFloat()

    private fun rotate(v: V3, rx: Float, ry: Float): V3 {
        val cy = cos(rx); val sy = sin(rx)
        val y1 = v.y * cy - v.z * sy
        val z1 = v.y * sy + v.z * cy
        val cx = cos(ry); val sx = sin(ry)
        val x2 = v.x * cx + z1 * sx
        val z2 = -v.x * sx + z1 * cx
        return V3(x2, y1, z2)
    }

    private fun DrawScope.drawCube(
        s: Float,
        value: Int,
        rx: Float,
        ry: Float,
        pipColor: Color,
        edgeStrokePx: Float,
        colors: LudoThemeColors,
    ) {
        // Project all eight corners with weak perspective into LOCAL coordinates.
        val projected = Array(8) { i ->
            val c = corner(i).let { it.times(s / 2f) }
            val r = rotate(c, rad(rx), rad(ry))
            val k = 3.4f / (3.4f + r.z / s)
            Offset(s / 2f + r.x * k, s / 2f + r.y * k)
        }

        val visible = FACES.mapNotNull { f ->
            val n = rotate(f.normal, rad(rx), rad(ry))
            if (n.z >= 0.02f) return@mapNotNull null            // back-face culled by winding
            val depth = f.corners.sumOf { corner(it).let { c -> rotate(c.times(s), rad(rx), rad(ry)).z.toDouble() } }
            f to depth
        }.sortedByDescending { it.second }                      // far → near

        val radius = 0.10f * s

        for ((face, _) in visible) {
            val pts = face.corners.map { projected[it] }

            // Face quad path (used for clipping only).
            val quad = Path().apply {
                moveTo(pts[0].x, pts[0].y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                close()
            }

            clipPath(quad) {
                // Rounded square fitted to the quad's bounds — the rounded FACE look.
                val tl = Offset(pts.minOf { it.x }, pts.minOf { it.y })
                val br = Offset(pts.maxOf { it.x }, pts.maxOf { it.y })
                val rect = Rect(tl, Size(br.x - tl.x, br.y - tl.y))

                // Body — ONE neutral token on every face, every value (§1).
                drawRoundRect(colors.c(colors.dieBody), topLeft = rect.topLeft, size = rect.size,
                    cornerRadius = CornerRadius(radius))

                // Directional shade ≤14% black on tilted faces: lighting, not color change.
                val n = rotate(face.normal, rad(rx), rad(ry))
                val shade = n.z.coerceIn(0f, 1f) * 0.14f
                if (shade > 0.01f) {
                    drawRoundRect(Color.Black.copy(alpha = shade), topLeft = rect.topLeft,
                        size = rect.size, cornerRadius = CornerRadius(radius))
                }

                // Edge stroke (§14.2): 1pt light / 1.25pt dark supplied by caller.
                drawRoundRect(colors.c(colors.dieEdge), topLeft = rect.topLeft, size = rect.size,
                    cornerRadius = CornerRadius(radius), style = Stroke(edgeStrokePx))

                // Pips projected through the SAME transform via bilinear mapping over the quad.
                val layout = PIPS[face.value] ?: return@clipPath
                val inset = 0.23f * s
                val step = (s - 2 * inset) / 2f
                val diameter = 0.18f * s
                for ((col, row) in layout) {
                    val u = (inset + col * step) / s
                    val v = (inset + row * step) / s
                    val c = bilinear(pts, u, v)
                    // Inset-depth treatment: dark shadow slightly low + top-left highlight.
                    drawCircle(Color.Black.copy(alpha = 0.18f), diameter / 2f,
                        Offset(c.first, c.second + 0.018f * s))
                    drawCircle(pipColor, diameter / 2f, Offset(c.first, c.second))
                    drawCircle(Color.White.copy(alpha = 0.12f), diameter * 0.28f,
                        Offset(c.first - diameter * 0.16f, c.second - diameter * 0.16f))
                }
            }
        }
    }

    private fun bilinear(corners: List<Offset>, u: Float, v: Float): Pair<Float, Float> {
        fun lerp(a: Offset, b: Offset, t: Float) =
            Offset(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)
        val top = lerp(corners[0], corners[1], u)
        val bottom = lerp(corners[3], corners[2], u)
        val r = lerp(top, bottom, v)
        return r.x to r.y
    }

    private operator fun V3.times(k: Float) = V3(x * k, y * k, z * k)
}
