package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.clipPath
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import com.voiid.app.main.games.GameSurface
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

    // Corner order per face is a consistent CCW loop seen from OUTSIDE. Normals and winding are
    // fixed; only the VALUES are rotated, by facesFor().
    private val FACE_GEOMETRY = listOf(
        V3(0f, 0f, 1f) to listOf(4, 5, 7, 6),    // front +Z : (-,-,+)(+,-,+)(+,+,+)(-,+,+)
        V3(0f, 0f, -1f) to listOf(1, 0, 2, 3),   // back  -Z
        V3(1f, 0f, 0f) to listOf(5, 1, 3, 7),    // right +X
        V3(-1f, 0f, 0f) to listOf(0, 4, 6, 2),   // left  -X
        V3(0f, -1f, 0f) to listOf(4, 0, 1, 5),   // top   -Y
        V3(0f, 1f, 0f) to listOf(2, 6, 7, 3),    // bottom +Y
    )

    /**
     * Face values as front, back, right, left, top, bottom — the result on the front, its
     * complement behind it, and the two remaining opposite pairs on the sides and poles.
     *
     * The alternative — a fixed labelling plus a per-value landing orientation — is what made
     * the die appear to change its number after settling: the tumble ended at whatever angles
     * the pose carried, showing some other face, and the handoff to the flat resting face then
     * snapped to the real result. Turning the labels instead of the cube lets every roll settle
     * at rotation (0,0), square-on and upright.
     */
    fun faceValues(result: Int): List<Int> {
        val r = result.coerceIn(1, 6)
        val remaining = listOf(listOf(1, 6), listOf(2, 5), listOf(3, 4)).filter { r !in it }
        return listOf(r, 7 - r,
            remaining[0][0], remaining[0][1],
            remaining[1][0], remaining[1][1])
    }

    private fun facesFor(result: Int): List<FaceDef> {
        val values = faceValues(result)
        return FACE_GEOMETRY.mapIndexed { i, (normal, corners) ->
            FaceDef(values[i], normal, corners)
        }
    }

    /** Fraction of the die's own box the settled die occupies. */
    const val REST_FILL_FACTOR = 0.92f

    /**
     * How much bigger the drawing surface is than the die's layout footprint.
     *
     * A turning cube spans up to √3 of its side and the throw lifts it clear of the ground, so
     * the surface has to be larger than the space the die occupies in the row — otherwise the
     * airborne die is sliced off at the top and the throw looks like it happens in a box.
     */
    const val CANVAS_FACTOR = 1.75f

    // Corner index → sign vector: bit0 x, bit1 y, bit2 z (value −1 / +1).
    private fun corner(i: Int): V3 {
        val x = if (i and 1 == 0) -1f else 1f
        val y = if (i and 2 == 0) -1f else 1f
        val z = if (i and 4 == 0) -1f else 1f
        return V3(x, y, z)
    }

    /**
     * Rest pose. Always square-on: the rolled result is placed on the cube's front face by
     * facesFor(), so no per-value re-orientation is needed and the tumble can wind down to
     * (0,0) showing the committed number upright.
     */
    fun restAngles(@Suppress("UNUSED_PARAMETER") value: Int): Pair<Float, Float> = 0f to 0f

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
        // Cast shadow on the tray floor. It stays put while the die rises, shrinking and fading
        // with height — the cue that separates a die thrown into the air from a picture being
        // rotated in place. Drawn before the transform so the lift does not move it.
        if (translationYPx < -0.5f) {
            val h = (-translationYPx / 21f).coerceAtMost(1f)
            val r = size.width * 0.30f * (1f - 0.34f * h)
            val cx = center.x + size.width * 0.05f * h   // light is up-left, so it slides right
            val cy = center.y + size.height * 0.30f
            drawOval(
                Color.Black.copy(alpha = 0.20f * (1f - 0.65f * h)),
                Offset(cx - r, cy - r * 0.34f),
                androidx.compose.ui.geometry.Size(r * 2f, r * 0.68f),
            )
        }
        translate(center.x - sidePx / 2, center.y - sidePx / 2 + translationYPx) {
            scale(scaleX, scaleY, pivot = Offset(sidePx / 2, sidePx / 2)) {
                drawCube(sidePx, value, rotationXDeg, rotationYDeg, pipColor, edgeStrokePx, colors)
            }
        }
    }

    /** How far the airborne die shrinks so a turning cube stays inside its tray. */
    const val AIRBORNE_SCALE = 0.62f

    /**
     * The RESTING die: one rounded square, one crisp upright pip grid, no projection.
     *
     * Every projected face is a rounded rect built from the face's bounding box and clipped to
     * the face quad, which is exact only square-on; and a rest pose such as 3's (90°,0°) draws
     * its pip grid in a rotated frame. Drawing the settled face directly keeps it upright and
     * identical on both platforms.
     */
    fun DrawScope.drawRestingDie(
        sidePx: Float,
        value: Int,
        pipColor: Color,
        edgeStrokePx: Float,
        colors: LudoThemeColors,
        /** Bevel and gradient strengths differ per theme; `LudoThemeColors` carries no flag. */
        darkTheme: Boolean,
    ) {
        translate(center.x - sidePx / 2, center.y - sidePx / 2) {
            val corner = .18f * sidePx

            // DEPTH SLABS (§14.3). At rest exactly one face points at the camera, and a single
            // face is a square, not a die — the projection in `drawProjectedDie` carries the
            // volume while the die turns, and is switched off here so the number stays legible.
            //
            // Rather than tilt the resting pose — which costs legibility at the one moment the
            // result matters — the depth is DRAWN: two slabs stepped down-right, so the cube has
            // a visible bottom and right edge under a number that is still flat on. Laid down
            // first, so the face itself covers everything but the exposed lip.
            // Mirrors iOS `LudoDieView.drawFlatFace`.
            for ((offset, tone) in listOf(.055f * sidePx to .30f, .028f * sidePx to .16f)) {
                val slab = Path().apply {
                    addRoundRect(
                        androidx.compose.ui.geometry.RoundRect(
                            left = offset, top = offset,
                            right = sidePx + offset, bottom = sidePx + offset,
                            cornerRadius = CornerRadius(corner),
                        )
                    )
                }
                drawPath(slab, colors.c(colors.dieEdge).copy(alpha = tone))
            }

            val body = androidx.compose.ui.geometry.RoundRect(
                left = 0f, top = 0f, right = sidePx, bottom = sidePx,
                cornerRadius = CornerRadius(corner),
            )
            val path = Path().apply { addRoundRect(body) }

            // A diagonal gradient rather than a flat fill, so the face has a direction to it. The
            // stops stay within a few percent of `dieBody` in both themes: the die is ONE neutral
            // token (§1), and this must read as light falling across it, never as a second colour.
            val bodyColor = colors.c(colors.dieBody)
            drawPath(
                path,
                brush = Brush.linearGradient(
                    colors = listOf(
                        GameSurface.lighten(bodyColor, if (darkTheme) .10f else .06f),
                        bodyColor,
                        GameSurface.darken(bodyColor, if (darkTheme) .06f else .08f),
                    ),
                    start = Offset.Zero,
                    end = Offset(sidePx, sidePx),
                ),
            )

            // BEVEL (§14.2): bright along the top-left lip, dark along the bottom-right. This is
            // the layer that reads as a moulded edge rather than a printed square — without it
            // the face is a rounded rect with pips on it. Inset by half its own width so the
            // stroke sits inside the silhouette instead of straddling the outline below.
            val bevelWidth = .045f * sidePx
            val bevelPath = Path().apply {
                addRoundRect(
                    androidx.compose.ui.geometry.RoundRect(
                        left = bevelWidth / 2f, top = bevelWidth / 2f,
                        right = sidePx - bevelWidth / 2f, bottom = sidePx - bevelWidth / 2f,
                        cornerRadius = CornerRadius(corner - bevelWidth / 2f),
                    )
                )
            }
            drawPath(
                bevelPath,
                brush = Brush.linearGradient(
                    colors = listOf(
                        Color.White.copy(alpha = if (darkTheme) .34f else .85f),
                        Color.Transparent,
                        Color.Black.copy(alpha = if (darkTheme) .34f else .22f),
                    ),
                    start = Offset.Zero,
                    end = Offset(sidePx, sidePx),
                ),
                style = Stroke(bevelWidth),
            )

            // The outline that separates the die from whatever is behind it — drawn LAST so the
            // bevel cannot bleed past the silhouette.
            drawPath(path, colors.c(colors.dieEdge), style = Stroke(edgeStrokePx))

            val layout = PIPS[value] ?: return@translate
            val inset = .26f * sidePx
            val step = (sidePx - 2 * inset) / 2f
            val radius = .093f * sidePx
            for ((col, row) in layout) {
                val cx = inset + col * step
                val cy = inset + row * step
                drawCircle(Color.Black.copy(alpha = .18f), radius,
                    Offset(cx, cy + .016f * sidePx))
                drawCircle(pipColor, radius, Offset(cx, cy))
                drawCircle(Color.White.copy(alpha = .14f), radius * .30f,
                    Offset(cx - radius * .30f, cy - radius * .30f))
            }
        }
    }

    private fun rad(deg: Float): Float = Math.toRadians(deg.toDouble()).toFloat()

    // Key light from up and to the left, in front of the die. Normalised so a face square to the
    // camera — the settled result — returns exactly 1 and takes no shading at all.
    private const val LX = -0.30f
    private const val LY = -0.45f
    private const val LZ = -1.0f
    private val L_LEN = kotlin.math.sqrt(LX * LX + LY * LY + LZ * LZ)

    private fun lambert(n: V3): Float {
        val dot = (n.x * LX + n.y * LY + n.z * LZ) / L_LEN
        // A face-on normal is (0,0,-1); dividing by that response puts it at exactly 1.
        return (dot / (1f / L_LEN)).coerceIn(0f, 1f)
    }

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
            // Stronger foreshortening than a near-orthographic projection: without it the cube
            // read as a flat square swapping pictures rather than a solid turning over.
            val k = 1.75f / (1.75f + r.z / s)
            Offset(s / 2f + r.x * k, s / 2f + r.y * k)
        }

        val visible = facesFor(value).mapNotNull { f ->
            val n = rotate(f.normal, rad(rx), rad(ry))
            if (n.z >= 0.02f) return@mapNotNull null            // back-face culled by winding
            val depth = f.corners.sumOf { corner(it).let { c -> rotate(c.times(s), rad(rx), rad(ry)).z.toDouble() } }
            f to depth
        }.sortedByDescending { it.second }                      // far → near

        for ((face, _) in visible) {
            val pts = face.corners.map { projected[it] }

            // The face is the PROJECTED QUAD itself, not a rounded rect sized to its bounding
            // box. The bbox of a turned quad is far larger than the quad, so filling it and
            // clipping to the quad painted a full grey slab with the pip grid laid out against
            // the wrong rectangle — which is why the tumbling die read as a flat square swapping
            // pictures instead of a cube turning over.
            val quad = Path().apply {
                moveTo(pts[0].x, pts[0].y)
                for (i in 1 until pts.size) lineTo(pts[i].x, pts[i].y)
                close()
            }

            clipPath(quad) {
                // Body — ONE neutral token on every face, every value (§1).
                drawPath(quad, colors.c(colors.dieBody))

                // Lambert shading against a fixed light, NOT a flat darkening of tilted faces.
                //
                // The old term darkened by how far a face had turned away from the camera, so
                // the face showing the result dimmed as it tumbled and the body read as
                // changing colour — an off-white die. Lighting the cube instead means the face
                // squarest to the light stays exactly the body colour, and the faces around it
                // fall off, which is what makes it look like an object rather than a picture.
                val n = rotate(face.normal, rad(rx), rad(ry))
                val shade = (1f - lambert(n)) * 0.42f
                if (shade > 0.01f) {
                    drawPath(quad, Color.Black.copy(alpha = shade))
                }

                // Edge stroke (§14.2): 1pt light / 1.25pt dark supplied by caller.
                drawPath(quad, colors.c(colors.dieEdge),
                    style = Stroke(edgeStrokePx, join = StrokeJoin.Round))

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
