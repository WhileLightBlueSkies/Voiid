package com.voiid.app.main.games.ludobot

import androidx.compose.animation.core.RepeatMode
import androidx.compose.animation.core.animateFloat
import androidx.compose.animation.core.infiniteRepeatable
import androidx.compose.animation.core.rememberInfiniteTransition
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke

import kotlin.math.cos
import kotlin.math.sin

/**
 * The static board: yards, ring, home columns and the centre rosette.
 *
 * Port of iOS `BoardCanvas` in `Games/Ludo/LudoBoardView.swift`.
 */
@Composable
fun LudoBoardCanvas(unit: Float, modifier: Modifier = Modifier) {
    Canvas(modifier) {
        drawBoard(unit)
    }
}

private fun DrawScope.drawBoard(u: Float) {
    fun rect(x: Float, y: Float, w: Float, h: Float) =
        Rect(Offset(x * u, y * u), Size(w * u, h * u))

    fun cell(r: Rect, fill: Color) {
        drawRect(fill, topLeft = r.topLeft, size = r.size)
        drawRect(LudoTheme.line, topLeft = r.topLeft, size = r.size, style = Stroke(0.5f))
    }

    // Board ground, so the gaps between cells are wood rather than the backdrop.
    drawRect(LudoTheme.board, topLeft = Offset.Zero, size = Size(15 * u, 15 * u))

    // Yards
    LudoEngine.seats.forEachIndexed { i, seat ->
        val o = seat.yardOrigin
        val outer = rect(o.x.toFloat(), o.y.toFloat(), 6f, 6f)
        drawRoundRect(
            LudoTheme.seat(i),
            topLeft = outer.topLeft,
            size = outer.size,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(u * 0.18f),
        )

        val inner = rect(o.x + 1f, o.y + 1f, 4f, 4f)
        drawRoundRect(
            LudoTheme.board,
            topLeft = inner.topLeft,
            size = inner.size,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(u * 0.14f),
        )
        drawRoundRect(
            LudoTheme.line,
            topLeft = inner.topLeft,
            size = inner.size,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(u * 0.14f),
            style = Stroke(0.5f),
        )

        for ((sx, sy) in LudoEngine.yardSlots) {
            val d = rect(o.x + sx - 0.42f, o.y + sy - 0.42f, 0.84f, 0.84f)
            drawOval(LudoTheme.board2, topLeft = d.topLeft, size = d.size)
            drawOval(LudoTheme.line, topLeft = d.topLeft, size = d.size, style = Stroke(0.5f))
        }
    }

    // Ring
    LudoEngine.ring.forEachIndexed { index, p ->
        val r = rect(p.x.toFloat(), p.y.toFloat(), 1f, 1f)
        val owner = LudoEngine.seats.indexOfFirst { it.start == index }.takeIf { it >= 0 }
        cell(r, owner?.let { LudoTheme.seat(it) } ?: LudoTheme.board)

        if (LudoEngine.safeSquares.contains(index) && owner == null) {
            val inset = r.width * 0.19f
            drawPath(
                starPath(Rect(r.left + inset, r.top + inset, r.right - inset, r.bottom - inset)),
                Color(0xFF6B5B44).copy(alpha = 0.55f),
                style = Stroke(width = 1.4f),
            )
        }
    }

    // Home columns
    LudoEngine.seats.forEachIndexed { i, seat ->
        for (p in seat.column) {
            cell(rect(p.x.toFloat(), p.y.toFloat(), 1f, 1f), LudoTheme.seat(i).copy(alpha = 0.88f))
        }
    }

    // Centre rosette
    cell(rect(6f, 6f, 3f, 3f), LudoTheme.board2)
    val c = Offset(7.5f * u, 7.5f * u)
    val corners = listOf(
        Offset(6.5f * u, 6.5f * u), Offset(8.5f * u, 6.5f * u),
        Offset(8.5f * u, 8.5f * u), Offset(6.5f * u, 8.5f * u),
    )
    val wedges = listOf(
        Triple(0, 3, 0), Triple(1, 0, 1), Triple(2, 1, 2), Triple(3, 2, 3),
    )
    for ((seat, a, b) in wedges) {
        val path = Path().apply {
            moveTo(c.x, c.y)
            lineTo(corners[a].x, corners[a].y)
            lineTo(corners[b].x, corners[b].y)
            close()
        }
        drawPath(path, LudoTheme.seat(seat))
    }
}

private fun starPath(r: Rect): Path {
    val path = Path()
    val cx = r.center.x
    val cy = r.center.y
    val outer = minOf(r.width, r.height) / 2f
    val inner = outer * 0.45f
    for (i in 0 until 10) {
        val radius = if (i % 2 == 0) outer else inner
        val angle = (-Math.PI / 2 + i * Math.PI / 5).toFloat()
        val x = cx + radius * cos(angle)
        val y = cy + radius * sin(angle)
        if (i == 0) path.moveTo(x, y) else path.lineTo(x, y)
    }
    path.close()
    return path
}

/**
 * A token. Mirrors iOS `TokenView`, including its reduced-motion behaviour: the halo and
 * bob mark a token the player may move, so under reduced motion they hold a static
 * highlight rather than disappearing.
 */
@Composable
fun LudoToken(
    seat: Int,
    diameter: Float,
    isLive: Boolean,
    isHopping: Boolean,
    isPopping: Boolean,
    modifier: Modifier = Modifier,
) {
    val reduceMotion = com.voiid.app.ui.components.reduceMotionEnabled()

    val transition = rememberInfiniteTransition(label = "token")
    val pulse by transition.animateFloat(
        initialValue = 0f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(650), RepeatMode.Reverse),
        label = "pulse",
    )

    // Smooth physics spring for hopping vertical arc and scale
    val hopLift by androidx.compose.animation.core.animateFloatAsState(
        targetValue = if (isHopping && !reduceMotion) -diameter * 0.38f else 0f,
        animationSpec = androidx.compose.animation.core.spring(
            dampingRatio = 0.55f,
            stiffness = 550f,
        ),
        label = "hopLift",
    )
    val hopScale by androidx.compose.animation.core.animateFloatAsState(
        targetValue = when {
            isPopping -> 1.45f
            isHopping && !reduceMotion -> 1.14f
            isLive && !reduceMotion -> 0.98f + 0.08f * pulse
            else -> 1f
        },
        animationSpec = androidx.compose.animation.core.spring(
            dampingRatio = 0.58f,
            stiffness = 580f,
        ),
        label = "hopScale",
    )

    Box(modifier) {
        Canvas(Modifier.fillMaxSize()) {
            val cx = size.width / 2f
            val cy = size.height / 2f + hopLift
            val r = diameter / 2f * hopScale

            if (isLive) {
                // Grounded radiant selection ring at base
                val p = if (reduceMotion) 0.5f else pulse
                drawCircle(
                    LudoTheme.seat(seat).copy(alpha = 0.85f - p * 0.5f),
                    radius = r * (1.18f + p * 0.16f),
                    center = Offset(cx, cy),
                    style = Stroke(width = 2.5f),
                )
                drawCircle(
                    Color.White.copy(alpha = 0.75f),
                    radius = r * 1.14f,
                    center = Offset(cx, cy),
                    style = Stroke(width = 1.2f),
                )

                // Downward pointer arrow indicating selectable pawn
                val arrowTipY = cy - r - diameter * 0.12f + (if (reduceMotion) 0f else -2f * p)
                val arrowW = diameter * 0.32f
                val arrowH = diameter * 0.22f
                val arrowPath = Path().apply {
                    moveTo(cx - arrowW / 2f, arrowTipY - arrowH)
                    lineTo(cx + arrowW / 2f, arrowTipY - arrowH)
                    lineTo(cx, arrowTipY)
                    close()
                }
                drawPath(arrowPath, Color.White)
            }

            // Grounded drop shadow
            drawCircle(
                if (isLive) LudoTheme.seat(seat).copy(alpha = 0.6f) else Color.Black.copy(alpha = 0.45f),
                radius = r,
                center = Offset(cx, cy + if (isLive) 1f else 3f),
            )

            drawCircle(LudoTheme.seat(seat), radius = r, center = Offset(cx, cy))
            drawCircle(
                Color.White.copy(alpha = 0.92f),
                radius = r * 0.34f,
                center = Offset(cx, cy),
            )
            drawCircle(
                Color.White.copy(alpha = 0.80f),
                radius = r,
                center = Offset(cx, cy),
                style = Stroke(width = 1.5f),
            )
        }
    }
}

/** Outlined square showing where a token would land. */
@Composable
fun LudoMoveHint(seat: Int, modifier: Modifier = Modifier) {
    val transition = rememberInfiniteTransition(label = "hint")
    val pulse by transition.animateFloat(
        initialValue = 0.45f,
        targetValue = 1f,
        animationSpec = infiniteRepeatable(tween(550), RepeatMode.Reverse),
        label = "pulse",
    )

    Canvas(modifier.fillMaxSize()) {
        val r = minOf(size.width, size.height) / 2f
        drawCircle(
            LudoTheme.seat(seat).copy(alpha = 0.75f * pulse),
            radius = r * 0.62f,
            center = center,
        )
        drawCircle(
            Color.White.copy(alpha = 0.85f * pulse),
            radius = r * 0.88f,
            center = center,
            style = Stroke(width = 2f),
        )
    }
}
