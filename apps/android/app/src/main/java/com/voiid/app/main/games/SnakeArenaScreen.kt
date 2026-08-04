package com.voiid.app.main.games

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.graphics.nativeCanvas
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
import kotlin.math.hypot
import kotlin.math.log10
import kotlin.math.min
import kotlin.math.sin

/**
 * Snake — the first CONTINUOUS game screen (docs/GAMES.md §71, §80).
 *
 * WHY THIS ONE IS DIFFERENT FROM EVERY OTHER GAME SCREEN HERE. Tic Tac Toe, RPS and cricket
 * recompose when a frame lands and are done: their state changes a few times a minute.
 * Snake's server ticks 10 times a second, so drawing frames on arrival would show visible
 * 10 fps stepping. This screen runs its own 60 fps clock (`withFrameNanos`) and reconstructs
 * the motion between server frames.
 *
 * THREE THINGS MAKE IT SMOOTH, and the first version shipped without any of them:
 *
 *  1. A JITTER BUFFER, not a frame pair. Interpolating between "current" and "previous" timed
 *     by ARRIVAL renders network jitter directly: frames do not land evenly, so the snake held
 *     and then jumped. The engine now buffers the last few frames stamped with the SERVER's
 *     own clock, and this screen renders ~150 ms in the past between whichever pair brackets
 *     that instant.
 *
 *  2. CLIENT-BUILT TRAILS. The body is NOT drawn by interpolating server path points. The
 *     server prepends a head point each tick and decimates long tails, so index i is a
 *     DIFFERENT piece of snake between frames — interpolating them made the whole body crawl
 *     and twitch. Each snake now keeps a local trail fed by the smoothly interpolated head.
 *
 *  3. A REAL JOYSTICK. Steering toward the finger's offset from screen centre gave no fixed
 *     reference and read as "the snake doesn't go where my hand goes". It also ran TWO
 *     competing pointerInput blocks over the same touches, which is why input sometimes did
 *     nothing at all.
 *
 * All interpolation and input, never prediction: no position is drawn that the server did not
 * send, so "renderer, not referee" still holds exactly.
 *
 * Mirrors iOS `SnakeArenaView.swift`.
 */
@Composable
fun SnakeArenaScreen(matchId: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val engine = remember { GamesEngine.get(context) }

    val frames by engine.snakeFrames.collectAsState()

    var boosting by remember { mutableStateOf(false) }
    var lastHeading by remember { mutableDoubleStateOf(0.0) }
    /** Live joystick vector, normalized to the ring radius; (0,0) at rest. */
    var stick by remember { mutableStateOf(Offset.Zero) }
    /** Ticks every display frame purely to drive redraws. */
    var frameClock by remember { mutableDoubleStateOf(0.0) }
    val trails = remember { TrailStore() }

    val me = engine.myUserId

    LaunchedEffect(matchId) { engine.open(matchId) }

    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { frameClock = it / 1_000_000_000.0 }
            engine.flushSteering(context)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            // Touch the clock so this redraws every display frame.
            @Suppress("UNUSED_EXPRESSION") frameClock
            drawArena(frames, me, trails, stick)
        }

        Overlay(
            state = frames.lastOrNull()?.state,
            me = me,
            boosting = boosting,
            onClose = onClose,
            onStick = { v ->
                stick = v
                // Deadzone: below this the thumb is resting, not steering, and atan2 on a
                // near-zero vector is meaningless noise.
                if (hypot(v.x, v.y) >= 0.15f) {
                    val heading = atan2(v.y.toDouble(), v.x.toDouble())
                    lastHeading = heading
                    engine.steer(context, heading, boosting)
                }
            },
            onBoostChange = { held ->
                boosting = held
                engine.steer(context, lastHeading, held)
            },
        )
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

/**
 * What to show above a head and in the leaderboard.
 *
 * Bots carry their name on the wire; humans are looked up locally, because only this device
 * knows what it calls its own contacts.
 */
private fun labelFor(snake: GamesEngine.SnakeState.Snake, me: String?): String = when {
    snake.id == me -> "You"
    !snake.name.isNullOrEmpty() -> snake.name!!
    else -> UserDirectory.displayName(snake.id, "Player")
}

/**
 * How far behind the newest frame to render, in seconds.
 *
 * Slightly more than one 10 Hz tick, so there is virtually always a NEWER frame to interpolate
 * towards. Less and the buffer runs dry constantly — the stutter this removes; much more and
 * the controls start to feel remote.
 */
private const val INTERP_DELAY = 0.15

private const val JOY_RADIUS_DP = 60f
private const val JOY_KNOB_DP = 26f

/** The pair of frames bracketing the render instant, plus the blend between them. */
private class Sample(
    val from: GamesEngine.SnakeState,
    val to: GamesEngine.SnakeState,
    val t: Double,
)

/**
 * Pick the two frames to draw between.
 *
 * The render clock derives from the SERVER's `t`, offset by how long the newest frame has been
 * sitting here, so arrival jitter moves the offset rather than the snake. When the buffer runs
 * dry the newest frame is HELD, never extrapolated — extrapolation looks smoother right up
 * until the real frame lands elsewhere and everything snaps, which reads far worse.
 */
private fun pickSample(frames: List<GamesEngine.SnakeFrame>): Sample? {
    val newest = frames.lastOrNull() ?: return null
    if (frames.size < 2) return Sample(newest.state, newest.state, 1.0)

    val elapsed = (android.os.SystemClock.elapsedRealtime() - newest.arrivedAtMs) / 1000.0
    val renderT = newest.state.time + elapsed - INTERP_DELAY

    for (i in frames.size - 2 downTo 0) {
        val a = frames[i].state
        val b = frames[i + 1].state
        if (renderT >= a.time) {
            val span = b.time - a.time
            val t = if (span > 1e-6) ((renderT - a.time) / span).coerceIn(0.0, 1.0) else 1.0
            return Sample(a, b, t)
        }
    }
    // renderT predates everything buffered (a long stall): show the oldest pair's start
    // rather than jumping to the newest.
    return Sample(frames[0].state, frames[1].state, 0.0)
}

private fun lerp(a: Double, b: Double, t: Double) = a + (b - a) * t

/** Short-arc angular interpolation, so crossing the -pi/pi wrap does not spin the long way. */
private fun lerpAngle(a: Double, b: Double, t: Double): Double {
    var delta = b - a
    while (delta > Math.PI) delta -= 2 * Math.PI
    while (delta < -Math.PI) delta += 2 * Math.PI
    return a + delta * t
}

private fun DrawScope.drawArena(
    frames: List<GamesEngine.SnakeFrame>,
    me: String?,
    trails: TrailStore,
    stick: Offset,
) {
    val s = pickSample(frames) ?: return
    val state = s.to

    // Interpolated head positions and headings for every snake this frame.
    val heads = HashMap<String, Offset>(state.snakes.size)
    val headings = HashMap<String, Double>(state.snakes.size)
    state.snakes.forEach { sn ->
        val prev = s.from.snakes.firstOrNull { it.id == sn.id }
        heads[sn.id] = Offset(
            lerp(prev?.x ?: sn.x, sn.x, s.t).toFloat(),
            lerp(prev?.y ?: sn.y, sn.y, s.t).toFloat(),
        )
        headings[sn.id] = lerpAngle(prev?.heading ?: sn.heading, sn.heading, s.t)
    }

    trails.update(state, heads)

    val focus = heads[me] ?: Offset.Zero
    val mass = state.snakes.firstOrNull { it.id == me }?.mass ?: 10.0

    // Zoom out as the snake grows so it stays framed, easing off so growth is not nauseating.
    val zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
    val scale = (min(size.width, size.height) / 900f) * zoom.toFloat()

    withTransform({
        translate(size.width / 2f, size.height / 2f)
        scale(scale, scale, pivot = Offset.Zero)
        translate(-focus.x, -focus.y)
    }) {
        drawBoundary(state.arenaRadius.toFloat())
        drawFood(state)

        // Rank by mass, so a label over a head and the HUD row can never disagree.
        val ranked = state.snakes.sortedByDescending { it.mass }
        val rankOf = ranked.withIndex().associate { (i, s) -> s.id to i + 1 }

        // Others first, the local player last, so your own body is never buried under
        // someone else's in a scrum.
        state.snakes.filter { it.alive && it.id != me }.forEach {
            drawSnake(it, trails, heads[it.id] ?: Offset.Zero,
                headings[it.id] ?: 0.0, false, state.time, stick,
                rankOf[it.id] ?: 0, me, scale)
        }
        state.snakes.firstOrNull { it.id == me && it.alive }?.let {
            drawSnake(it, trails, heads[it.id] ?: Offset.Zero,
                headings[it.id] ?: 0.0, true, state.time, stick,
                rankOf[it.id] ?: 0, me, scale)
        }
    }
}

private fun DrawScope.drawBoundary(radius: Float) {
    drawCircle(Color(0xFF120E28), radius = radius, center = Offset.Zero)

    // Drawn EXACTLY at the lethal line, not inside or outside it. A wall whose visible edge
    // disagrees with the killing surface makes every border death feel unfair, and players
    // cannot learn a boundary they cannot see precisely.
    drawCircle(
        Color(0xFF5AD8FF).copy(alpha = 0.16f), radius = radius - 20f,
        center = Offset.Zero, style = Stroke(width = 40f))
    drawCircle(Color(0xFF5AD8FF), radius = radius, center = Offset.Zero, style = Stroke(width = 6f))
}

private fun DrawScope.drawFood(state: GamesEngine.SnakeState) {
    // Food never moves, so it is drawn from the newest frame with no interpolation.
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
    trails: TrailStore,
    head: Offset,
    heading: Double,
    isMe: Boolean,
    time: Double,
    stick: Offset,
    rank: Int,
    me: String?,
    scale: Float,
) {
    val points = trails.points(snake.id)
    if (points.size < 2) return

    val color = paletteColor(snake.colorIndex)

    // Width comes from the SERVER's head radius, so the drawn body is exactly the shape that
    // kills. A local formula could drift from the hitbox on any tuning change — and the
    // snake now thickens as it eats, so that drift would grow with the snake.
    val width = (snake.headRadius * 1.9).toFloat()

    val path = Path().apply {
        moveTo(points[0].x, points[0].y)
        // Quadratic smoothing through midpoints: the trail is a polyline of per-frame samples,
        // and drawing it as straight segments would show every corner.
        for (i in 1 until points.size - 1) {
            val mx = (points[i].x + points[i + 1].x) / 2f
            val my = (points[i].y + points[i + 1].y) / 2f
            quadraticTo(points[i].x, points[i].y, mx, my)
        }
        lineTo(points.last().x, points.last().y)
    }

    // Spawn invulnerability reads as translucency, so a player knows not to bother attacking
    // and knows why they were not killed.
    val alpha = if (time < snake.invulnUntil) 0.55f else 1f

    drawPath(path, color.copy(alpha = 0.22f * alpha),
        style = Stroke(width = width * 2.1f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    drawPath(path, color.copy(alpha = alpha),
        style = Stroke(width = width, cap = StrokeCap.Round, join = StrokeJoin.Round))

    if (isMe) {
        // A rim no one else has. In a crowded arena hue alone is not enough to find yourself.
        drawPath(path, Color.White.copy(alpha = 0.85f * alpha),
            style = Stroke(width = 2.5f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }
    if (snake.boosting) {
        drawPath(path, Color.White.copy(alpha = 0.35f),
            style = Stroke(width = width * 0.45f, cap = StrokeCap.Round, join = StrokeJoin.Round))
    }

    drawHead(head, heading, width, color, alpha, isMe, stick)
    drawLabel(head, snake, rank, me, width, scale)
}

private fun DrawScope.drawHead(
    head: Offset,
    heading: Double,
    width: Float,
    color: Color,
    alpha: Float,
    isMe: Boolean,
    stick: Offset,
) {
    val r = width * 0.62f
    drawCircle(color.copy(alpha = 0.28f * alpha), radius = r * 2.4f, center = head)
    drawCircle(color.copy(alpha = alpha), radius = r, center = head)

    // The local player's eyes follow the JOYSTICK rather than the confirmed heading, so aim
    // responds on the same frame the thumb moves. Purely cosmetic — the body and every
    // collision still come from the server — but it is most of what makes the control feel
    // connected across a 10 Hz link.
    val look = if (isMe && stick != Offset.Zero) {
        atan2(stick.y.toDouble(), stick.x.toDouble())
    } else heading

    val eyeR = r * 0.3f
    for (side in listOf(-1.0, 1.0)) {
        val ex = head.x + (cos(look) * r * 0.35 - sin(look) * side * r * 0.42).toFloat()
        val ey = head.y + (sin(look) * r * 0.35 + cos(look) * side * r * 0.42).toFloat()
        drawCircle(Color.White.copy(alpha = alpha), radius = eyeR, center = Offset(ex, ey))
        val pr = eyeR * 0.52f
        val px = ex + (cos(look) * eyeR * 0.4).toFloat()
        val py = ey + (sin(look) * eyeR * 0.4).toFloat()
        drawCircle(Color.Black.copy(alpha = alpha), radius = pr, center = Offset(px, py))
    }
}

/**
 * Name, prefixed with the rank when the snake is in the top 10.
 *
 * Drawn through the native canvas because Compose's own text API is not available inside a
 * DrawScope without a TextMeasurer, and this needs to run for every visible snake every
 * frame. Sized in SCREEN terms and divided back out by the camera scale, so a label stays
 * legible at any zoom instead of shrinking to nothing as the snake grows.
 */
private fun DrawScope.drawLabel(
    head: Offset,
    snake: GamesEngine.SnakeState.Snake,
    rank: Int,
    me: String?,
    width: Float,
    scale: Float,
) {
    val name = labelFor(snake, me)
    if (name.isEmpty()) return
    val text = if (rank in 1..10) "#$rank $name" else name

    val px = 13f / scale.coerceAtLeast(0.0001f)
    val paint = android.graphics.Paint().apply {
        isAntiAlias = true
        textSize = px
        textAlign = android.graphics.Paint.Align.CENTER
        typeface = android.graphics.Typeface.create(
            android.graphics.Typeface.DEFAULT, android.graphics.Typeface.BOLD)
        color = if (snake.id == me) android.graphics.Color.WHITE
                else android.graphics.Color.argb(235, 217, 224, 255)
        // A shadow rather than an outline: labels sit over a busy arena and pure white text
        // on a bright snake is unreadable without some separation.
        setShadowLayer(px * 0.25f, 0f, px * 0.06f, android.graphics.Color.argb(200, 0, 0, 0))
    }

    drawContext.canvas.nativeCanvas.drawText(
        text, head.x, head.y - width * 0.75f - px * 0.4f, paint)
}

/**
 * Per-snake body polylines, rebuilt on the client from interpolated head motion.
 *
 * WHY NOT JUST DRAW THE SERVER'S PATH: the server prepends a head point every tick and
 * decimates the tail of long snakes, so the same array index is a different piece of snake
 * from one frame to the next. Interpolating those against each other made the whole body crawl
 * and twitch — the single worst part of how the first version looked.
 *
 * A trail is appended at RENDER rate from the smoothly interpolated head, so the body is built
 * out of 60 fps of motion. The server's path only seeds a new snake, re-seeds after a respawn,
 * and re-syncs if the two drift apart.
 */
private class TrailStore {
    private val trails = HashMap<String, MutableList<Offset>>()
    private val wasAlive = HashMap<String, Boolean>()

    fun points(id: String): List<Offset> = trails[id] ?: emptyList()

    fun update(state: GamesEngine.SnakeState, heads: Map<String, Offset>) {
        val seen = HashSet<String>(state.snakes.size)

        state.snakes.forEach { sn ->
            seen.add(sn.id)
            val respawned = sn.alive && wasAlive[sn.id] != true
            wasAlive[sn.id] = sn.alive

            if (!sn.alive) { trails.remove(sn.id); return@forEach }
            val head = heads[sn.id] ?: return@forEach

            var trail = trails[sn.id]

            // Seed from the server path on first sight or after a respawn — a trail has to
            // start as a whole body, not grow from a dot over the first second.
            if (trail == null || trail.isEmpty() || respawned) {
                trails[sn.id] = seedFrom(sn, head)
                return@forEach
            }

            // Re-sync if the local trail has drifted from where the server says the head is.
            // Happens after a stall or a big correction; without it a wrong trail persists for
            // the rest of the match.
            val first = trail.first()
            if (hypot(head.x - first.x, head.y - first.y) > RESYNC_DISTANCE) {
                trails[sn.id] = seedFrom(sn, head)
                return@forEach
            }

            if (hypot(head.x - first.x, head.y - first.y) >= MIN_STEP) {
                trail.add(0, head)
            } else {
                // Keep the drawn head exactly on the interpolated position even when it has
                // not moved far enough to earn its own point.
                trail[0] = head
            }

            trim(trail, sn.mass * SEGMENT_SPACING)
        }

        trails.keys.retainAll(seen)
        wasAlive.keys.retainAll(seen)
    }

    private fun seedFrom(
        sn: GamesEngine.SnakeState.Snake,
        head: Offset,
    ): MutableList<Offset> =
        if (sn.path.isEmpty()) mutableListOf(head)
        else sn.path.mapTo(ArrayList(sn.path.size)) { Offset(it.x.toFloat(), it.y.toFloat()) }

    /**
     * Trim to an exact arc length, cutting THROUGH the final segment.
     *
     * Same maths as the server's `trimPath`. Dropping whole segments instead makes the tail
     * quantise: it holds still while the head travels a segment's worth, then jumps back by a
     * whole segment — a visible twitch on every snake, every frame.
     */
    private fun trim(points: MutableList<Offset>, maxLength: Double) {
        if (points.size < 2 || maxLength <= 0) return

        var total = 0.0
        for (i in 0 until points.size - 1) {
            val seg = hypot(points[i + 1].x - points[i].x, points[i + 1].y - points[i].y).toDouble()
            if (total + seg >= maxLength) {
                val t = if (seg > 1e-9) ((maxLength - total) / seg).toFloat() else 0f
                points[i + 1] = Offset(
                    points[i].x + (points[i + 1].x - points[i].x) * t,
                    points[i].y + (points[i + 1].y - points[i].y) * t,
                )
                while (points.size > i + 2) points.removeAt(points.size - 1)
                return
            }
            total += seg
        }
    }

    private companion object {
        /** Matches the server's SEGMENT_SPACING. Body length in world units is mass x this. */
        const val SEGMENT_SPACING = 14.0
        /** Minimum head movement before a new point is recorded, to bound polyline length. */
        const val MIN_STEP = 1.5f
        /** Head-vs-trail divergence beyond which the local trail is wrong and gets re-seeded. */
        const val RESYNC_DISTANCE = 60f
    }
}

@Composable
private fun Overlay(
    state: GamesEngine.SnakeState?,
    me: String?,
    boosting: Boolean,
    onClose: () -> Unit,
    onStick: (Offset) -> Unit,
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
                // Top ten, live. Rank is the point of the board, so it is shown explicitly
                // rather than implied by row order.
                state.snakes.sortedByDescending { it.mass }.take(10)
                    .forEachIndexed { index, snake ->
                        val isMe = snake.id == me
                        Row(
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text("#${index + 1}",
                                color = Color.White.copy(alpha = 0.4f),
                                fontSize = 10.sp, fontWeight = FontWeight.Bold,
                                fontFamily = FontFamily.Monospace)
                            Box(Modifier.size(7.dp)
                                .background(paletteColor(snake.colorIndex), CircleShape))
                            Text(
                                // Bots are named plausibly and never labelled as bots — a
                                // "BOT" tag would change how players treat them, and practice
                                // is more useful when the arena feels real.
                                labelFor(snake, me),
                                color = Color.White.copy(alpha = if (isMe) 1f else 0.78f),
                                fontSize = 11.sp,
                                fontWeight = if (isMe) FontWeight.ExtraBold else FontWeight.SemiBold)
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

        VirtualJoystick(
            onVector = onStick,
            modifier = Modifier
                .align(Alignment.BottomStart)
                .padding(start = 12.dp, bottom = 20.dp),
        )

        // Press-and-hold, not a toggle: boost is a held commitment, and a toggle costs a tap
        // to release at exactly the moment a player is busy steering.
        Box(
            Modifier
                .align(Alignment.BottomEnd)
                .padding(end = 12.dp, bottom = 20.dp)
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

/**
 * A fixed-ring virtual joystick.
 *
 * The knob follows the finger, clamped inside the ring: past the edge it pins to the rim in
 * that direction rather than escaping. Release springs it back to centre. Output is a
 * normalized vector in [-1, 1] per axis, relative to the ring radius.
 *
 * FIXED RATHER THAN FLOATING, deliberately: a fixed ring gives the thumb a constant physical
 * reference it can find without looking, which is exactly what was missing when steering was
 * "toward my finger relative to screen centre".
 *
 * TWO BUGS ARE FIXED HERE, and they are why steering died:
 *
 *  1. `detectDragGestures` only reports a drag AFTER the finger crosses touch slop, so a
 *     thumb that pressed and held perfectly still produced NOTHING. A raw
 *     `awaitPointerEventScope` loop responds on touch-down with zero slop.
 *
 *  2. The knob was animated through `rememberCoroutineScope()`, which is CANCELLED when the
 *     composable leaves. Coming back for a second match left a dead scope, so the animation
 *     never ran again — the reason steering worked once and then stopped. The spring-back is
 *     now plain state driven by the caller's frame loop, with no scope to die.
 */
@Composable
private fun VirtualJoystick(
    onVector: (Offset) -> Unit,
    modifier: Modifier = Modifier,
) {
    // Plain state, not Animatable: nothing here outlives the composable, so nothing can be
    // left cancelled between matches.
    var knob by remember { mutableStateOf(Offset.Zero) }
    var held by remember { mutableStateOf(false) }

    // Spring-back, driven by the frame clock rather than a coroutine. Critically damped
    // enough to settle without wobbling, which on a control (as opposed to decoration) reads
    // as slop rather than as life.
    LaunchedEffect(Unit) {
        var lastNanos = 0L
        while (true) {
            withFrameNanos { now ->
                val dt = if (lastNanos == 0L) 0f else ((now - lastNanos) / 1_000_000_000.0).toFloat()
                lastNanos = now
                if (!held && knob != Offset.Zero) {
                    val decay = kotlin.math.exp(-14.0 * dt).toFloat()
                    val next = knob * decay
                    knob = if (hypot(next.x, next.y) < 0.5f) Offset.Zero else next
                }
            }
        }
    }

    // Measured from the layout itself rather than passed in. The ring radius, the hit test
    // and the drawing must all agree on one number; deriving it from the actual box size
    // means they cannot drift apart, and the gesture no longer restarts if a density-derived
    // parameter changes identity.
    Box(
        modifier
            // A hit area larger than the ring: a thumb reaching for a joystick lands near it
            // as often as on it, and demanding a precise hit is what makes an on-screen stick
            // feel unresponsive.
            .size((JOY_RADIUS_DP * 2.8f).dp)
            // Keyed on Unit, NOT on a parameter: a pointerInput restarts its coroutine
            // whenever its key changes, and a key that changes identity between recompositions
            // silently kills the in-flight gesture. That is the class of bug that made
            // steering stop working.
            .pointerInput(Unit) {
                awaitEachGesture {
                    // requireUnconsumed = false so this still wins the touch even if an
                    // ancestor looked at it first. awaitEachGesture handles the outer loop
                    // and, critically, cleans up correctly if the composable goes away
                    // mid-gesture — which a hand-rolled while(true) does not.
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val r = size.width / 2f / 1.4f
                    held = true
                    knob = clampToRing(down.position, size.width, r)
                    onVector(knob / r)
                    down.consume()

                    // Track until the finger lifts. Reading the event stream directly means
                    // the knob moves on the very first move event, with no touch slop.
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.id == down.id } ?: break
                        if (!change.pressed) break
                        knob = clampToRing(change.position, size.width, r)
                        onVector(knob / r)
                        change.consume()
                    }

                    held = false
                    // No steer on release: the snake keeps its heading, matching the server
                    // model and the genre. Only the knob returns home.
                    onVector(Offset.Zero)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Canvas(Modifier.fillMaxSize()) {
            val centre = Offset(size.width / 2f, size.height / 2f)
            val r = size.width / 2f / 1.4f
            drawCircle(Color.White.copy(alpha = 0.10f), radius = r, center = centre)
            drawCircle(Color.White.copy(alpha = 0.24f), radius = r,
                center = centre, style = Stroke(width = 4f))
            // A faint centre mark, so the rest position is visible before the thumb lands.
            drawCircle(Color.White.copy(alpha = 0.12f), radius = 7f, center = centre)
            drawCircle(Color.White.copy(alpha = 0.92f),
                radius = r * 0.42f, center = centre + knob)
        }
    }
}

/** Clamp a touch to the ring: normalize and scale by R once the finger passes the rim. */
private fun clampToRing(position: Offset, boxSize: Int, radiusPx: Float): Offset {
    val centre = boxSize / 2f
    val dx = position.x - centre
    val dy = position.y - centre
    val dist = hypot(dx, dy)
    return if (dist > radiusPx && dist > 0f) {
        Offset(dx / dist * radiusPx, dy / dist * radiusPx)
    } else Offset(dx, dy)
}
