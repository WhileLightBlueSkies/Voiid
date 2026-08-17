package com.voiid.app.main.games

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.lerp
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * The shared visual language for game boards: paper grain, felt, inset cells, and the specular
 * highlight that makes a token read as an object rather than a filled circle.
 *
 * WHY THIS IS SHARED RATHER THAN THREE SEPARATE TREATMENTS. Three boards styled independently is
 * three different games stapled to a tab — the same failure SOUND_DESIGN.md §3 describes for
 * audio. A player should be able to tell they are still inside Voiid when they move between
 * games, and that is carried by grain, depth and light behaving the same way everywhere.
 *
 * IT IS ALL PROCEDURAL. No image assets, nothing to ship or version — every effect is drawn from
 * a seed, so it scales to any board size and costs nothing in APK weight.
 *
 * DETERMINISTIC, DELIBERATELY. Grain comes from a positional hash rather than `Random`, so a
 * board looks identical on every recomposition. A texture that shimmers as the view redraws is
 * worse than no texture at all.
 *
 * Ported from iOS `GameSurface.swift`. KEEP THE CONSTANTS IDENTICAL — SNAKE.md §2.4 records two
 * renderers that drifted, and warns that divergent constants are how two builds of one game end
 * up feeling different.
 */
object GameSurface {

    /**
     * A stable pseudo-random value in 0..1 for a grid position.
     *
     * The classic sine-hash: cheap, no state, and — the point — the SAME answer for the same
     * (x, y, seed) every call.
     */
    fun noise(x: Int, y: Int, seed: Int = 0): Double {
        val v = sin(x * 127.1 + y * 311.7 + seed * 74.7) * 43758.5453
        return v - floor(v)
    }

    /** PAPER: a warm surface with fine grain and a soft vignette. */
    fun DrawScope.paper(rect: Rect, base: Color, grain: Double = 0.022, seed: Int = 7) {
        drawRect(base, topLeft = rect.topLeft, size = rect.size)
        speckle(rect, grain, seed, cell = 3)
        vignette(rect, 0.10f)
    }

    /** FELT: a table surface. Ludo's board (§8.1 asks for warm and tactile). */
    fun DrawScope.felt(rect: Rect, base: Color, seed: Int = 11) {
        drawRect(base, topLeft = rect.topLeft, size = rect.size)
        speckle(rect, 0.028, seed, cell = 4)
        vignette(rect, 0.14f)
    }

    /**
     * Fine grain, drawn as sparse translucent dots.
     *
     * A high threshold keeps it sparse. Too low and it stops reading as texture and starts
     * reading as dirt on the screen.
     */
    fun DrawScope.speckle(rect: Rect, amount: Double, seed: Int, cell: Int) {
        val cols = (rect.width / cell).toInt()
        val rows = (rect.height / cell).toInt()
        if (cols <= 0 || rows <= 0) return
        for (gy in 0 until rows) {
            for (gx in 0 until cols) {
                val n = noise(gx, gy, seed)
                if (n <= 0.93) continue
                val x = rect.left + (gx * cell).toFloat()
                val y = rect.top + (gy * cell).toFloat()
                val dark = noise(gx, gy, seed + 1) > 0.5
                val a = (amount * (0.4 + n * 0.6)).toFloat()
                drawRect(
                    color = if (dark) Color.Black.copy(alpha = a) else Color.White.copy(alpha = a * 0.8f),
                    topLeft = Offset(x, y),
                    size = Size(cell * 0.7f, cell * 0.7f),
                )
            }
        }
    }

    /**
     * Darken the edges. A board with even light across it reads as a screenshot of a board; a
     * slight falloff reads as a physical object under a lamp.
     */
    fun DrawScope.vignette(rect: Rect, strength: Float) {
        drawRect(
            brush = Brush.radialGradient(
                colors = listOf(Color.Transparent, Color.Black.copy(alpha = strength)),
                center = rect.center,
                radius = max(rect.width, rect.height) * 0.72f,
            ),
            topLeft = rect.topLeft,
            size = rect.size,
        )
    }

    /**
     * An INSET cell — shadow on the top-left, catch-light on the bottom-right.
     *
     * Reads as a hole pressed into the surface, which is what a board square is.
     *
     * LIGHT COMES FROM THE TOP-LEFT everywhere in this app. One light direction, every game.
     */
    fun DrawScope.inset(rect: Rect, radius: Float, depth: Float = 1.2f) {
        drawRoundRect(
            color = Color.Black.copy(alpha = 0.10f),
            topLeft = Offset(rect.left + depth, rect.top + depth),
            size = rect.size,
            cornerRadius = CornerRadius(radius),
            style = Stroke(width = depth * 1.4f),
        )
        drawRoundRect(
            color = Color.White.copy(alpha = 0.35f),
            topLeft = Offset(rect.left - depth * 0.5f, rect.top - depth * 0.5f),
            size = rect.size,
            cornerRadius = CornerRadius(radius),
            style = Stroke(width = depth),
        )
    }

    /**
     * A RAISED disc with a contact shadow, a lit body and a specular highlight.
     *
     * THIS IS WHAT MAKES A TOKEN READ AS AN OBJECT rather than a filled circle, and it is the
     * highest-value effect in this file — LUDO.md §8.1 asks for "rounded pieces that look like
     * objects that can be picked up", and three cheap layers get most of the way there with no
     * sprite and no model.
     *
     * THE BODY STAYS ON `centre`. An earlier iOS version shifted it up to make room for the
     * shadow, which drifted every token off the square the rules say it occupies — the piece and
     * its position must agree, so the shadow moves instead.
     */
    /**
     * A LUDO PAWN — a moulded plastic piece, not a lit disc (§5.1).
     *
     * [token] below draws a disc, which was right when the board was flat but is the reason the
     * pieces never read as objects you could pick up. A pawn is four stacked shapes: base, waist,
     * collar, head. Glossy rather than matte, because Ludo King's pieces read as polished plastic
     * and that is most of the appeal.
     *
     * THE PIECE STILL SITS ON [centre]. The shadow moves for the hop, never the body — the piece
     * and the square the rules say it occupies must agree.
     */
    fun DrawScope.pawn(centre: Offset, radius: Float, color: Color, lifted: Boolean = false) {
        val shadowDrop = radius * if (lifted) 0.72f else 0.52f
        val shadowScale = if (lifted) 0.72f else 0.92f

        // 1. Contact shadow, UNDER the piece.
        drawOval(
            color = Color.Black.copy(alpha = if (lifted) 0.13f else 0.26f),
            topLeft = Offset(
                centre.x - radius * shadowScale,
                centre.y + shadowDrop - radius * 0.18f),
            size = Size(radius * 2 * shadowScale, radius * 0.46f),
        )

        // 2. Base: a squashed ellipse the piece stands on.
        val baseRy = radius * 0.22f
        val baseY = centre.y + radius * 0.52f
        drawOval(
            brush = Brush.verticalGradient(
                listOf(color, darken(color, 0.34f)),
                startY = baseY - baseRy, endY = baseY + baseRy,
            ),
            topLeft = Offset(centre.x - radius * 0.50f, baseY - baseRy),
            size = Size(radius, baseRy * 2),
        )

        // 3. Waist: two mirrored curves from the base up to the neck. This is the silhouette
        //    that says "pawn" — a cylinder would read as a checker.
        val waist = Path().apply {
            moveTo(centre.x - radius * 0.50f, baseY)
            quadraticTo(
                centre.x - radius * 0.46f, centre.y + radius * 0.10f,
                centre.x - radius * 0.22f, centre.y - radius * 0.10f)
            lineTo(centre.x + radius * 0.22f, centre.y - radius * 0.10f)
            quadraticTo(
                centre.x + radius * 0.46f, centre.y + radius * 0.10f,
                centre.x + radius * 0.50f, baseY)
            close()
        }
        drawPath(
            waist,
            Brush.horizontalGradient(
                listOf(lighten(color, 0.20f), color, darken(color, 0.28f)),
                startX = centre.x - radius * 0.5f, endX = centre.x + radius * 0.5f,
            ),
        )

        // 4. Collar: the thin band between waist and head. The detail that makes it read as
        //    MOULDED rather than carved.
        drawOval(
            color = lighten(color, 0.12f),
            topLeft = Offset(centre.x - radius * 0.30f, centre.y - radius * 0.20f),
            size = Size(radius * 0.60f, radius * 0.16f),
        )

        // 5. Head.
        val headTopLeft = Offset(centre.x - radius * 0.34f, centre.y - radius * 0.78f)
        val headSize = Size(radius * 0.68f, radius * 0.68f)
        drawOval(
            brush = Brush.linearGradient(
                listOf(lighten(color, 0.30f), color, darken(color, 0.24f)),
                start = headTopLeft,
                end = Offset(headTopLeft.x + headSize.width, headTopLeft.y + headSize.height),
            ),
            topLeft = headTopLeft,
            size = headSize,
        )

        // 6. Specular on the head's upper-left, and a rim light. Two lights is what separates
        //    gloss from a flat fill.
        drawOval(
            color = Color.White.copy(alpha = 0.72f),
            topLeft = Offset(
                headTopLeft.x + headSize.width * 0.16f,
                headTopLeft.y + headSize.height * 0.12f),
            size = Size(headSize.width * 0.30f, headSize.height * 0.26f),
        )
        drawOval(
            color = Color.White.copy(alpha = 0.25f),
            topLeft = Offset(headTopLeft.x + radius * 0.03f, headTopLeft.y + radius * 0.03f),
            size = Size(headSize.width - radius * 0.06f, headSize.height - radius * 0.06f),
            style = Stroke(width = maxOf(0.6f, radius * 0.05f)),
        )
    }

    fun DrawScope.token(centre: Offset, radius: Float, color: Color, lifted: Boolean = false) {
        val shadowDrop = radius * if (lifted) 0.62f else 0.40f
        val shadowScale = if (lifted) 0.80f else 0.94f

        // 1. Contact shadow, UNDER the piece. It shrinks, drops away and softens as the piece
        //    lifts, which is most of what sells a hop as leaving the surface (§9).
        drawOval(
            color = Color.Black.copy(alpha = if (lifted) 0.14f else 0.24f),
            topLeft = Offset(centre.x - radius * shadowScale, centre.y + shadowDrop - radius * 0.22f),
            size = Size(radius * 2 * shadowScale, radius * 0.52f),
        )

        val topLeft = Offset(centre.x - radius, centre.y - radius)
        val size = Size(radius * 2, radius * 2)

        // 2. Body: lit from above.
        drawOval(
            brush = Brush.verticalGradient(
                colors = listOf(lighten(color, 0.28f), color, darken(color, 0.30f)),
                startY = topLeft.y,
                endY = topLeft.y + size.height,
            ),
            topLeft = topLeft,
            size = size,
        )

        // A darker rim, so the piece has an edge rather than fading into the board.
        drawOval(
            color = darken(color, 0.45f).copy(alpha = 0.55f),
            topLeft = topLeft,
            size = size,
            style = Stroke(width = max(0.8f, radius * 0.07f)),
        )

        // 3. Specular: small, off-centre, up-left. Placement matters more than size — centred it
        //    reads as a hole; offset it reads as a curved surface catching a light.
        drawOval(
            color = Color.White.copy(alpha = 0.42f),
            topLeft = Offset(centre.x - radius * 0.52f, centre.y - radius * 0.62f),
            size = Size(radius * 0.62f, radius * 0.44f),
        )
    }

    fun lighten(c: Color, amount: Float): Color = lerp(c, Color.White, min(1f, max(0f, amount)))
    fun darken(c: Color, amount: Float): Color = lerp(c, Color.Black, min(1f, max(0f, amount)))
}
