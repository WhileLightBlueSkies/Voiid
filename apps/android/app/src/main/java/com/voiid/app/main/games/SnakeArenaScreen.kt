package com.voiid.app.main.games

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.runtime.collectAsState
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.store.UserDirectory
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.log10
import kotlin.math.min
import kotlin.math.sin

/**
 * Snake — the first CONTINUOUS game screen (docs/GAMES.md §71, §80).
 *
 * WHY THIS ONE IS DIFFERENT FROM EVERY OTHER GAME SCREEN HERE. Tic Tac Toe, RPS and cricket
 * recompose when a frame lands and are done: their state changes a few times a minute.
 * Snake's server ticks 10 times a second, so drawing frames on arrival would show visible
 * 10 fps stepping. This screen therefore runs its own 60 fps clock (`withFrameNanos`) and
 * INTERPOLATES between the last two server frames.
 *
 * That is interpolation, not prediction. It only ever draws positions the server has already
 * confirmed, rendered ~100 ms in the past. It cannot invent a position, so the
 * "renderer, not referee" rule in GamesEngine.kt still holds exactly.
 *
 * Mirrors iOS `SnakeArenaView.swift`.
 */
@Composable
fun SnakeArenaScreen(matchId: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val engine = remember { GamesEngine.get(context) }

    val state by engine.snake.collectAsState()
    val previous by engine.snakePrevious.collectAsState()

    var boosting by remember { mutableStateOf(false) }
    var lastHeading by remember { mutableDoubleStateOf(0.0) }
    /** Ticks every display frame purely to drive redraws off the server's frame clock. */
    var frameClock by remember { mutableDoubleStateOf(0.0) }

    val me = engine.myUserId

    LaunchedEffect(matchId) { engine.open(matchId) }

    // 60 fps redraw loop. Reading `frameClock` inside Canvas is what subscribes the draw to
    // it, so every frame produces a new interpolated position.
    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { frameClock = it / 1_000_000_000.0 }
            engine.flushSteering(context)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black)
            .pointerInput(Unit) {
                detectDragGestures(
                    onDrag = { change, _ ->
                        val dx = change.position.x - size.width / 2f
                        val dy = change.position.y - size.height / 2f
                        if (dx * dx + dy * dy > 64f) {
                            val heading = atan2(dy.toDouble(), dx.toDouble())
                            lastHeading = heading
                            engine.steer(context, heading, boosting)
                        }
                    },
                    // Releasing does NOT stop the snake — it keeps its heading, which is the
                    // genre's expectation.
                    onDragEnd = {},
                )
            }
            .pointerInput(Unit) {
                detectTapGestures(onPress = { offset ->
                    val dx = offset.x - size.width / 2f
                    val dy = offset.y - size.height / 2f
                    if (dx * dx + dy * dy > 64f) {
                        val heading = atan2(dy.toDouble(), dx.toDouble())
                        lastHeading = heading
                        engine.steer(context, heading, boosting)
                    }
                })
            }
    ) {
        Canvas(Modifier.fillMaxSize()) {
            // Touch the clock so this redraws every display frame.
            @Suppress("UNUSED_EXPRESSION") frameClock
            val current = state ?: return@Canvas
            drawArena(current, previous, me, engine.snakeFrameAt)
        }

        Overlay(
            state = state,
            me = me,
            boosting = boosting,
            onClose = onClose,
            onBoostChange = { held ->
                boosting = held
                engine.steer(context, lastHeading, held)
            })
    }
}

/**
 * Distinct, high-contrast body colours. The index comes from the server so a snake keeps its
 * colour for the whole match and every device agrees on who is who.
 */
private val PALETTE = listOf(
    Color(0xFFFF3B47), Color(0xFF22E0F0), Color(0xFF9B5CFF), Color(0xFF5CE65C),
    Color(0xFFFF8A2B), Color(0xFFFFD93D), Color(0xFFFF4FD8), Color(0xFF12C98C),
    Color(0xFF4DA8FF), Color(0xFFC6F53D), Color(0xFFFFB020), Color(0xFF8DF7C8),
)

private fun paletteColor(index: Int): Color =
    PALETTE[((index % PALETTE.size) + PALETTE.size) % PALETTE.size]

/** Server tick period. Interpolation spans exactly one of these. */
private const val TICK_MS = 100.0

private fun DrawScope.drawArena(
    state: GamesEngine.SnakeState,
    previous: GamesEngine.SnakeState?,
    me: String?,
    frameAt: Long,
) {
    // Interpolation factor, clamped to 1: if a frame is late the snake HOLDS at the last
    // known position rather than extrapolating past it. Extrapolating looks smoother right up
    // until the real frame arrives somewhere else and the snake snaps, which reads as a much
    // worse glitch than a brief pause.
    val elapsed = (android.os.SystemClock.elapsedRealtime() - frameAt).toDouble()
    val t = (elapsed / TICK_MS).coerceIn(0.0, 1.0)

    val mine = state.snakes.firstOrNull { it.id == me }
    val prevMine = previous?.snakes?.firstOrNull { it.id == me }

    val focusX = lerp(prevMine?.x, mine?.x ?: 0.0, t)
    val focusY = lerp(prevMine?.y, mine?.y ?: 0.0, t)

    // Zoom so a growing snake stays framed, easing out so growth is not nauseating.
    val mass = mine?.mass ?: 10.0
    val zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
    val scale = (min(size.width, size.height) / 900f) * zoom.toFloat()

    withTransform({
        translate(size.width / 2f, size.height / 2f)
        scale(scale, scale, pivot = Offset.Zero)
        translate(-focusX.toFloat(), -focusY.toFloat())
    }) {
        drawBoundary(state.arenaRadius.toFloat())
        drawFood(state)

        // Others first, the local player last, so your own body is never buried under
        // someone else's in a scrum.
        state.snakes.filter { it.alive && it.id != me }.forEach {
            drawSnake(it, previous, t, false, state.time)
        }
        mine?.takeIf { it.alive }?.let { drawSnake(it, previous, t, true, state.time) }
    }
}

private fun lerp(from: Double?, to: Double, t: Double): Double =
    if (from == null) to else from + (to - from) * t

private fun DrawScope.drawBoundary(radius: Float) {
    val topLeft = Offset(-radius, -radius)
    val diameter = Size(radius * 2, radius * 2)

    // Interior wash, so "inside" reads as a place rather than as empty black.
    drawCircle(Color(0xFF120E28), radius = radius, center = Offset.Zero)

    // The boundary is drawn EXACTLY at the lethal line, not inside or outside it. A wall
    // whose visible edge disagrees with the killing surface makes every border death feel
    // unfair, and players cannot learn a boundary they cannot see precisely.
    drawCircle(
        Color(0xFF5AD8FF).copy(alpha = 0.16f), radius = radius - 20f,
        center = Offset.Zero, style = Stroke(width = 40f))
    drawCircle(Color(0xFF5AD8FF), radius = radius, center = Offset.Zero, style = Stroke(width = 6f))
}

private fun DrawScope.drawFood(state: GamesEngine.SnakeState) {
    state.food.forEach { item ->
        val r = if (item.value >= 2) 7f else if (item.value < 1) 4.5f else 5.5f
        val color = if (item.value >= 2) Color(0xFFFFB873) else Color(0xFFFFEE9E)
        val centre = Offset(item.x.toFloat(), item.y.toFloat())
        drawCircle(color.copy(alpha = 0.18f), radius = r * 2f, center = centre)
        drawCircle(color, radius = r, center = centre)
    }
}

private fun DrawScope.drawSnake(
    snake: GamesEngine.SnakeState.Snake,
    previous: GamesEngine.SnakeState?,
    t: Double,
    isMe: Boolean,
    time: Double,
) {
    if (snake.path.size < 2) return

    val prev = previous?.snakes?.firstOrNull { it.id == snake.id }
    val color = paletteColor(snake.colorIndex)

    // Body width grows sub-linearly with mass: linear growth would have a long snake filling
    // the screen, and length is meant to dominate by covering space, not by being fat.
    val width = (20.0 * (1 + log10(1 + snake.mass / 25) * 0.55)).toFloat()

    // Interpolate point-by-point against the previous frame, matched by index — correct here
    // because a path only grows or shifts by one point per tick, so index i is very nearly
    // the same piece of snake between frames.
    val points = snake.path.mapIndexed { i, p ->
        val pp = prev?.path?.getOrNull(i)
        Offset(lerp(pp?.x, p.x, t).toFloat(), lerp(pp?.y, p.y, t).toFloat())
    }

    val path = Path().apply {
        moveTo(points[0].x, points[0].y)
        // Quadratic smoothing through midpoints: the server sends a decimated polyline, and
        // drawing it as straight segments would show every corner.
        for (i in 1 until points.size - 1) {
            val mid = Offset(
                (points[i].x + points[i + 1].x) / 2f,
                (points[i].y + points[i + 1].y) / 2f)
            quadraticBezierTo(points[i].x, points[i].y, mid.x, mid.y)
        }
        lineTo(points.last().x, points.last().y)
    }

    // Spawn invulnerability reads as translucency, so a player knows not to bother attacking
    // and knows why they were not killed.
    val alpha = if (time < snake.invulnUntil) 0.55f else 1f

    drawPath(path, color.copy(alpha = 0.22f * alpha),
        style = Stroke(width = width * 2.1f, cap = androidx.compose.ui.graphics.StrokeCap.Round,
            join = androidx.compose.ui.graphics.StrokeJoin.Round))
    drawPath(path, color.copy(alpha = alpha),
        style = Stroke(width = width, cap = androidx.compose.ui.graphics.StrokeCap.Round,
            join = androidx.compose.ui.graphics.StrokeJoin.Round))

    if (isMe) {
        // The local player's snake carries a rim no one else has. In a crowded arena hue
        // alone is not enough to find yourself quickly.
        drawPath(path, Color.White.copy(alpha = 0.85f * alpha),
            style = Stroke(width = 2.5f, cap = androidx.compose.ui.graphics.StrokeCap.Round,
                join = androidx.compose.ui.graphics.StrokeJoin.Round))
    }
    if (snake.boosting) {
        drawPath(path, Color.White.copy(alpha = 0.35f),
            style = Stroke(width = width * 0.45f,
                cap = androidx.compose.ui.graphics.StrokeCap.Round,
                join = androidx.compose.ui.graphics.StrokeJoin.Round))
    }

    drawHead(points[0], snake, prev, t, width, color, alpha)
}

private fun DrawScope.drawHead(
    head: Offset,
    snake: GamesEngine.SnakeState.Snake,
    prev: GamesEngine.SnakeState.Snake?,
    t: Double,
    width: Float,
    color: Color,
    alpha: Float,
) {
    val r = width * 0.62f
    drawCircle(color.copy(alpha = 0.28f * alpha), radius = r * 2.4f, center = head)
    drawCircle(color.copy(alpha = alpha), radius = r, center = head)

    // Angles interpolate on the SHORT arc, so a snake crossing the -pi/pi wrap does not spin
    // its eyes the long way round.
    var heading = snake.heading
    if (prev != null) {
        var delta = snake.heading - prev.heading
        while (delta > Math.PI) delta -= 2 * Math.PI
        while (delta < -Math.PI) delta += 2 * Math.PI
        heading = prev.heading + delta * t
    }

    val eyeR = r * 0.3f
    for (side in listOf(-1.0, 1.0)) {
        val ex = head.x + (cos(heading) * r * 0.35 - sin(heading) * side * r * 0.42).toFloat()
        val ey = head.y + (sin(heading) * r * 0.35 + cos(heading) * side * r * 0.42).toFloat()
        drawCircle(Color.White.copy(alpha = alpha), radius = eyeR, center = Offset(ex, ey))
        val pr = eyeR * 0.52f
        val px = ex + (cos(heading) * eyeR * 0.4).toFloat()
        val py = ey + (sin(heading) * eyeR * 0.4).toFloat()
        drawCircle(Color.Black.copy(alpha = alpha), radius = pr, center = Offset(px, py))
    }
}

@Composable
private fun Overlay(
    state: GamesEngine.SnakeState?,
    me: String?,
    boosting: Boolean,
    onClose: () -> Unit,
    onBoostChange: (Boolean) -> Unit,
) {
    Box(Modifier.fillMaxSize().padding(14.dp)) {
        Box(
            Modifier
                .align(Alignment.TopStart)
                .size(34.dp)
                .background(Color.White.copy(alpha = 0.14f), CircleShape)
                .pointerInput(Unit) { detectTapGestures { onClose() } },
            contentAlignment = Alignment.Center,
        ) {
            Text("✕", color = Color.White.copy(alpha = 0.9f), fontSize = 14.sp,
                fontWeight = FontWeight.Bold)
        }

        if (state != null) {
            Column(
                Modifier
                    .align(Alignment.TopEnd)
                    .background(Color.White.copy(alpha = 0.10f), RoundedCornerShape(12.dp))
                    .padding(horizontal = 10.dp, vertical = 8.dp),
                horizontalAlignment = Alignment.End,
                verticalArrangement = Arrangement.spacedBy(3.dp),
            ) {
                state.snakes.sortedByDescending { it.mass }.take(4).forEach { snake ->
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(6.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Box(Modifier.size(7.dp)
                            .background(paletteColor(snake.colorIndex), CircleShape))
                        Text(
                            // Bots are named plausibly and never labelled as bots — a "BOT"
                            // tag would change how players treat them, and practice is more
                            // useful when it feels like a real arena.
                            if (snake.id == me) "You"
                            else if (snake.isBot) snake.id.removePrefix("bot:").uppercase()
                            else UserDirectory.displayName(snake.id, "Player"),
                            color = Color.White.copy(alpha = if (snake.id == me) 1f else 0.75f),
                            fontSize = 11.sp, fontWeight = FontWeight.SemiBold)
                        Text(snake.mass.toInt().toString(),
                            color = Color.White.copy(alpha = 0.55f),
                            fontSize = 11.sp, fontWeight = FontWeight.Bold,
                            fontFamily = FontFamily.Monospace)
                    }
                }

                val left = (state.duration - state.time).coerceAtLeast(0.0).toInt()
                Text(String.format("%d:%02d", left / 60, left % 60),
                    color = Color.White.copy(alpha = 0.8f),
                    fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    fontFamily = FontFamily.Monospace)
            }
        }

        // Press-and-hold, not a toggle: boost is a held commitment, and a toggle costs a tap
        // to release at exactly the moment a player is busy steering.
        Box(
            Modifier
                .align(Alignment.BottomEnd)
                .padding(10.dp)
                .size(78.dp)
                .background(
                    Color.White.copy(alpha = if (boosting) 0.30f else 0.12f), CircleShape)
                .pointerInput(Unit) {
                    detectTapGestures(
                        onPress = {
                            onBoostChange(true)
                            tryAwaitRelease()
                            onBoostChange(false)
                        })
                },
            contentAlignment = Alignment.Center,
        ) {
            Text("BOOST", color = Color.White.copy(alpha = 0.9f),
                fontSize = 10.sp, fontWeight = FontWeight.Black)
        }
    }
}
