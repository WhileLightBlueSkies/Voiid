package com.voiid.app.main.games

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxScope
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.graphics.BlendMode
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
fun SnakeArenaScreen(
    matchId: String,
    onClose: () -> Unit,
    /** Start a fresh practice match. Null hides the Restart action. */
    onRestart: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val engine = remember { GamesEngine.get(context) }

    // NOT collectAsState().
    //
    // Collecting the frame buffer as composable state recomposed this ENTIRE screen 10 times
    // a second — every server tick dragged the leaderboard, the joystick and the boost pedal
    // through recomposition, which is the "whole screen refreshing" flicker. The Canvas reads
    // the buffer directly inside its draw lambda instead, so a new frame invalidates the draw
    // and nothing else.
    val framesRef = remember { mutableStateOf<List<GamesEngine.SnakeFrame>>(emptyList()) }
    // The HUD is a SEPARATE, slow state: a leaderboard does not need 10 Hz.
    val hudState = remember { mutableStateOf<GamesEngine.SnakeState?>(null) }

    LaunchedEffect(Unit) {
        engine.snakeFrames.collect { framesRef.value = it }
    }
    LaunchedEffect(Unit) {
        // ~6 Hz is plenty for names, ranks and a clock, and it keeps the HUD off the render
        // path entirely.
        while (true) {
            hudState.value = engine.snake
            kotlinx.coroutines.delay(160)
        }
    }

    var boosting by remember { mutableStateOf(false) }
    var lastHeading by remember { mutableDoubleStateOf(0.0) }
    /** Live joystick vector, normalized to the ring radius; (0,0) at rest. */
    var stick by remember { mutableStateOf(Offset.Zero) }
    // Ticks every display frame purely to drive redraws.
    //
    // A plain `var by mutableStateOf` here invalidated the WHOLE composable 60x/s, dragging
    // the leaderboard, the joystick and every other child through recomposition on every
    // frame. Only the Canvas needs to repaint, so the clock lives in a state object that
    // just the draw lambda reads — Compose then invalidates the draw and nothing else.
    val frameClock = remember { mutableDoubleStateOf(0.0) }
    val trails = remember { TrailStore() }
    val camera = remember { CameraMemory() }
    val particles = remember { ParticleSystem() }
    val impact = remember { ImpactTimeline() }
    val haptics = remember { GameHaptics(context) }
    val boostAudio = remember { BoostAudioState() }

    val me = engine.myUserId

    DisposableEffect(Unit) {
        GameAudio.preload(context, "snake")
        onDispose { GameAudio.release("snake") }
    }

    LaunchedEffect(matchId) { engine.open(matchId) }

    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { frameClock.doubleValue = it / 1_000_000_000.0 }
            engine.flushSteering(context)
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(Color.Black),
    ) {
        Canvas(Modifier.fillMaxSize()) {
            // Reading the clock inside the DRAW scope subscribes only this draw to it.
            @Suppress("UNUSED_EXPRESSION") frameClock.doubleValue
            drawArena(framesRef.value, me, trails, stick, camera, particles, impact, haptics, boostAudio)
        }

        // Death / game-over panel.
        //
        // Death is not the end of a match here — Largest Snake respawns you — so the panel
        // reports the death and gets out of the way, while the END of the match is the one
        // that actually blocks with Restart / Quit.
        val hud = hudState.value
        val mine = hud?.snakes?.firstOrNull { it.id == me }
        val matchOver = hud?.finished == true

        Overlay(
            state = hudState.value,
            me = me,
            boosting = boosting,
            onClose = onClose,
            onStick = { v ->
                stick = v
                // A zero vector means the thumb lifted: stop the resend loop rather than
                // steering toward atan2(0,0).
                if (v == Offset.Zero) engine.releaseSteering()
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

        if (matchOver) {
            GameOverPanel(
                title = "Match over",
                detail = mine?.let { "You finished with ${it.mass.toInt()}" } ?: "",
                onRestart = onRestart,
                onQuit = onClose,
            )
        } else if (mine != null && !mine.alive) {
            DeathPanel(
                mass = mine.mass.toInt(),
                deaths = mine.deaths,
                canRespawn = mine.canRespawn,
                onRespawn = { engine.requestRespawn(context) },
                onQuit = onClose,
            )
        }
    }
}

/**
 * Shown when the player is dead.
 *
 * BLOCKING, and the player stays dead until they choose. The server used to auto-respawn
 * humans after 2.5 s, which meant this panel appeared and vanished before it could be read
 * and being teleported back into play unprompted felt like the match had restarted itself.
 * Bots still respawn on a timer; a human decides.
 */
@Composable
private fun BoxScope.DeathPanel(
    mass: Int,
    deaths: Int,
    canRespawn: Boolean,
    onRespawn: () -> Unit,
    onQuit: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xCC07060F))
            // Swallow taps so the arena underneath cannot be steered while this is up.
            .pointerInput(Unit) { detectTapGestures { } },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text("You died", color = Color.White, fontSize = 30.sp,
                fontWeight = FontWeight.Black)
            Text("Length $mass  ·  Deaths $deaths",
                color = Color.White.copy(alpha = 0.6f), fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                modifier = Modifier.padding(top = 6.dp))

            Box(
                Modifier
                    .padding(top = 26.dp)
                    .background(
                        if (canRespawn) Color(0xFF22E0F0) else Color.White.copy(alpha = 0.15f),
                        RoundedCornerShape(14.dp))
                    .pointerInput(canRespawn) {
                        detectTapGestures { if (canRespawn) onRespawn() }
                    }
                    .padding(horizontal = 42.dp, vertical = 14.dp),
            ) {
                Text(
                    if (canRespawn) "Respawn" else "Respawning…",
                    color = if (canRespawn) Color(0xFF07060F) else Color.White.copy(alpha = 0.5f),
                    fontSize = 15.sp, fontWeight = FontWeight.Black)
            }

            Box(
                Modifier
                    .padding(top = 12.dp)
                    .background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                    .pointerInput(Unit) { detectTapGestures { onQuit() } }
                    .padding(horizontal = 50.dp, vertical = 13.dp),
            ) {
                Text("Quit", color = Color.White.copy(alpha = 0.9f),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
        }
    }
}

/** The match itself is over. This one blocks — there is nothing left to play. */
@Composable
private fun BoxScope.GameOverPanel(
    title: String,
    detail: String,
    onRestart: (() -> Unit)?,
    onQuit: () -> Unit,
) {
    Box(
        Modifier
            .fillMaxSize()
            .background(Color(0xCC07060F))
            // Swallow taps so the arena underneath cannot be steered while this is up.
            .pointerInput(Unit) { detectTapGestures { } },
        contentAlignment = Alignment.Center,
    ) {
        Column(horizontalAlignment = Alignment.CenterHorizontally) {
            Text(title, color = Color.White, fontSize = 30.sp, fontWeight = FontWeight.Black)
            if (detail.isNotEmpty()) {
                Text(detail, color = Color.White.copy(alpha = 0.65f),
                    fontSize = 14.sp, fontWeight = FontWeight.Medium,
                    modifier = Modifier.padding(top = 6.dp))
            }

            if (onRestart != null) {
                Box(
                    Modifier
                        .padding(top = 26.dp)
                        .background(Color(0xFF22E0F0), RoundedCornerShape(14.dp))
                        .pointerInput(Unit) { detectTapGestures { onRestart() } }
                        .padding(horizontal = 46.dp, vertical = 14.dp),
                ) {
                    Text("Restart", color = Color(0xFF07060F),
                        fontSize = 15.sp, fontWeight = FontWeight.Black)
                }
            }

            Box(
                Modifier
                    .padding(top = 12.dp)
                    .background(Color.White.copy(alpha = 0.12f), RoundedCornerShape(14.dp))
                    .pointerInput(Unit) { detectTapGestures { onQuit() } }
                    .padding(horizontal = 50.dp, vertical = 13.dp),
            ) {
                Text("Quit", color = Color.White.copy(alpha = 0.9f),
                    fontSize = 15.sp, fontWeight = FontWeight.Bold)
            }
        }
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
 * TWO AND A HALF ticks, not one and a half.
 *
 * At 1.5 ticks the buffer ran dry on any frame that arrived even slightly late — and on a
 * mobile network that is most of them — so the render clock repeatedly caught up with the
 * newest frame, held, and jumped. That hold-jump cycle IS the jitter. Buying an extra tick of
 * delay costs 100 ms of visual lag and removes the stall almost entirely, which is a trade
 * strongly worth making for a game steered by a stick rather than aimed.
 */
private const val INTERP_DELAY = 0.25

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

/** Tracks the local player's boost state frame-to-frame so boost_start/boost_loop/boost_end
 * fire once on the TRANSITION rather than every frame boost happens to be held/released.
 * There is no server EVENT for this — boost is continuous per-tick state, not a discrete
 * occurrence like eat/kill/death/spawn — so the edge has to be detected client-side. Mirrors
 * iOS SnakeMetalView's `wasBoosting` property. */
private class BoostAudioState { var wasBoosting = false }

/**
 * Turns a `kill`/`death` event into a brief FREEZE followed by a SLOW recovery
 * (GAMES_ANIMATION.md §5.4, mirrors iOS `ImpactTimeline` in SnakeMetalView.swift).
 *
 * PRESENTATION-CLOCK ONLY. [dilate] is applied to the wall-clock dt fed to the camera spring
 * and the particle system, never to the interpolation math that reads the server's own
 * clock — that boundary is what keeps this a renderer and not a referee (see this file's own
 * top-of-file doc comment). A bug here can make the game feel wrong for a fraction of a
 * second; it cannot make a match wrong.
 *
 * Kept as a separate class from [CameraMemory] even though they are always used together,
 * because [ParticleSystem] needs it too and a shared dependency belongs in its own object
 * rather than reached through the camera.
 */
private class ImpactTimeline {
    private enum class Kind { KILL, DEATH }
    private var kind: Kind? = null
    private var startedAtNanos = 0L

    companion object {
        // All Float: `elapsed` below is computed as Float, and Kotlin does not implicitly
        // widen/narrow between Float and Double in a comparison — an un-suffixed literal here
        // infers as Double and fails to compile against it.
        private const val KILL_FREEZE = 0.12f          // "120ms hitstop" — doc's exact number
        private const val DEATH_FREEZE = 0.10f
        private const val DEATH_SLOW_DURATION = 0.5f    // matches GAMES_AUDIO §8.7's death envelope
        private const val DEATH_SLOW_FACTOR = 0.3f       // "slow-mo to 0.3x" — doc's exact number
        private const val DEATH_DESATURATE_DURATION = 0.4f
    }

    fun triggerKill() { kind = Kind.KILL; startedAtNanos = System.nanoTime() }
    fun triggerDeath() { kind = Kind.DEATH; startedAtNanos = System.nanoTime() }

    /** How much of [rawDt] should actually reach the presentation clock this frame. 0 during a
     * freeze, `DEATH_SLOW_FACTOR * rawDt` during the slow-mo tail, [rawDt] otherwise. */
    fun dilate(rawDt: Float): Float {
        val k = kind ?: return rawDt
        if (rawDt <= 0f) return rawDt
        val elapsed = (System.nanoTime() - startedAtNanos) / 1_000_000_000f

        return when (k) {
            Kind.KILL -> {
                if (elapsed < KILL_FREEZE) return 0f
                kind = null
                rawDt
            }
            Kind.DEATH -> {
                if (elapsed < DEATH_FREEZE) return 0f
                val sinceSlowStart = elapsed - DEATH_FREEZE
                if (sinceSlowStart < DEATH_SLOW_DURATION) return rawDt * DEATH_SLOW_FACTOR
                kind = null
                rawDt
            }
        }
    }

    /** 0 (no effect) to 1 (fully tinted), for the death flash only — a kill is too brief and
     * too frequent to carry a screen-space tint without a busy match feeling like it strobes. */
    fun desaturation(): Float {
        if (kind != Kind.DEATH) return 0f
        val elapsed = (System.nanoTime() - startedAtNanos) / 1_000_000_000f
        if (elapsed >= DEATH_DESATURATE_DURATION) return 0f
        // Snaps up, eases out — an impact arrives instantly and fades, it does not fade in.
        return 1f - elapsed / DEATH_DESATURATE_DURATION
    }
}

/**
 * Camera state: follow spring + look-ahead + shake (GAMES_ANIMATION.md §5.2, mirrors iOS
 * `stepCamera`/`computeLookAhead`/`currentShake` in SnakeMetalView.swift).
 *
 * THE SPRING IS THE PART THAT WAS MISSING HERE. Before this, [focus] in `drawArena` was the
 * raw interpolated head position with no smoothing at all — every bit of positional error
 * (and there is always some: the render clock derives from network arrival time) became a
 * full-screen camera movement at 1:1, which is the arena-wide flicker documented in
 * docs/GAMES_SNAKE_BUGS.md Part B. iOS got a follow spring in 22b8680; this class is the
 * Android port that commit never received, folded into the same change as look-ahead and
 * shake since all three live in the same "where does the camera actually point" concern.
 */
private class CameraMemory {
    /** Last known head position, so a frame missing one (mid-respawn) cannot pin the camera
     * to the arena origin — the bug this class already guarded against. */
    var last: Offset? = null

    private var centre: Offset? = null
    private var lastStepAtNanos = 0L

    /** ~80ms settle, matching iOS's cameraTau exactly — divergent constants between platforms
     * is how two ports of the same fix end up feeling like different games. */
    private val tau = 0.08f
    /** A respawn puts you anywhere in the arena; springing across that gap sends the camera
     * flying over the whole map, so a jump this large cuts instead. Matches iOS's
     * cameraTeleport. */
    private val teleportDistance = 300f

    /** Advance the spring toward [target] (nil = hold last known) and return where the camera
     * now is, BEFORE shake is added — see [shakeOffset]. [impact] dilates this step's dt so a
     * hitstop freeze correctly HOLDS the camera instead of continuing to chase a moving target
     * while the rest of the world is frozen (see ImpactTimeline's class doc). */
    fun step(target: Offset?, impact: ImpactTimeline): Offset {
        target?.let { last = it }
        val goal = target ?: last ?: return centre ?: Offset.Zero

        val now = System.nanoTime()
        val rawDt = if (lastStepAtNanos > 0L) {
            minOf((now - lastStepAtNanos) / 1_000_000_000f, 0.1f)
        } else 0f
        lastStepAtNanos = now
        val dt = impact.dilate(rawDt)

        val current = centre
        if (current == null) {
            centre = goal      // first frame: start on the player, do not spring in
            return goal
        }

        if (hypot((goal.x - current.x).toDouble(), (goal.y - current.y).toDouble()) > teleportDistance) {
            centre = goal
            return goal
        }

        val a = if (dt > 0f) 1f - kotlin.math.exp(-dt / tau) else 1f
        val next = Offset(current.x + (goal.x - current.x) * a, current.y + (goal.y - current.y) * a)
        centre = next
        return next
    }

    // --- Screen shake: "3-6 px, 200 ms, decaying" (§5.2/§3.1) --------------------------------
    //
    // Kept separate from `centre` for the same reason as iOS: shake must never feed back into
    // the spring's own state (a big shake could otherwise trip the teleport-cut check above).

    private var shakeStartedAtNanos = 0L
    private var shakeMagnitude = 0f
    private var shakeSeed = 0f
    private val shakeDurationSeconds = 0.2f

    /** Trigger a shake. A later call while one is decaying restarts at the new magnitude
     * rather than summing — a rapid double-kill should feel like one strong hit, not an
     * accelerating wobble. */
    fun triggerShake(magnitude: Float) {
        shakeStartedAtNanos = System.nanoTime()
        shakeMagnitude = magnitude
        shakeSeed = (Math.random() * 1000).toFloat()
    }

    /** Shake offset in WORLD units (divided by scale so it reads as a constant number of
     * on-screen pixels regardless of zoom). Call once per frame AFTER [step]. */
    fun shakeOffset(scale: Float): Offset {
        if (shakeMagnitude <= 0f) return Offset.Zero
        val elapsed = (System.nanoTime() - shakeStartedAtNanos) / 1_000_000_000f
        if (elapsed >= shakeDurationSeconds) { shakeMagnitude = 0f; return Offset.Zero }

        // Decaying sine, not per-frame random noise — a sine reads as an impact recoiling,
        // where random jitter reads as the RENDERER being unstable, the wrong association for
        // a kill (a good thing) to carry.
        val decay = 1f - elapsed / shakeDurationSeconds
        val phase = (elapsed + shakeSeed) * 40f
        val px = kotlin.math.sin(phase) * shakeMagnitude * decay
        val py = kotlin.math.cos(phase * 1.3f) * shakeMagnitude * decay
        val worldScale = scale.coerceAtLeast(0.0001f)
        return Offset(px / worldScale, py / worldScale)
    }
}

/**
 * Offset the camera toward where the local player is HEADED, scaled by speed — "the player
 * sees where they are going instead of where they are" (GAMES_ANIMATION.md §5.2). Returns
 * Offset.Zero for a dead/absent player.
 *
 * Speed constants (240/420) are the server's BASE_SPEED/BOOST_SPEED from
 * backend/games/src/engine/snake/index.ts TUNING, duplicated here as a presentation-only
 * value — look-ahead distance affects nothing about the simulation, so a guess that is
 * slightly stale after a tuning change only makes the offset a little short or long.
 */
private fun computeLookAhead(mine: GamesEngine.SnakeState.Snake?, heading: Double?): Offset {
    if (mine == null || !mine.alive || heading == null) return Offset.Zero
    val speed = if (mine.boosting) 420.0 else 240.0
    val distance = minOf(speed * 0.35, 140.0)   // 0.35s of travel, capped at 140 world units
    return Offset((cos(heading) * distance).toFloat(), (sin(heading) * distance).toFloat())
}

/**
 * Presentation-only VFX driven by the server's `death`/`kill`/`eat`/`spawn` events
 * (GAMES_ANIMATION.md §5.3, mirrors iOS `ParticleSystem` in SnakeMetalView.swift).
 *
 * FIXED POOL, NOT A GROWING LIST — a death converts a whole body into food and can fire a
 * burst at the same instant several other snakes eat; without a cap a chaotic scrum could
 * allocate thousands of particles in one frame. A full pool just stops accepting new spawns
 * until old ones expire, which reads as "the newest burst is a little sparser" rather than a
 * frame-rate cliff.
 *
 * EVERYTHING HERE IS CLIENT-ONLY. `step`/`spawn` only read events the server already
 * committed to; nothing here can desync a match, only under- or over-decorate one — same
 * guarantee the renderer as a whole makes (SnakeArenaScreen.kt's own top-of-file doc comment).
 */
private class ParticleSystem {
    private data class Particle(
        var x: Float, var y: Float,
        var vx: Float, var vy: Float,
        var life: Float, val maxLife: Float,
        val size: Float, val color: Color,
    )

    companion object { private const val CAPACITY = 512 }

    private val particles = ArrayList<Particle>(CAPACITY)
    /** De-dupe key: only spawn for a server tick this instance hasn't seen. `t` only
     * increases within a match, so "newer than last seen" is sufficient — matches the
     * de-dupe strategy in the iOS ParticleSystem's caller. */
    private var lastEventTime = -1.0

    fun spawn(kind: String, x: Float, y: Float, color: Color) {
        when (kind) {
            // "6-10 sparks converging into the head" (doc) — approximated as an outward burst
            // from the food's position, the simplest readable equivalent at this scale.
            "eat" -> emit((6..10).random(), x, y, speed = 40f..90f, life = 0.28f..0.4f,
                size = 2.5f..4f, color = color)
            "kill" -> emit(22, x, y, speed = 90f..220f, life = 0.4f..0.65f, size = 3f..6f,
                color = color)
            "spawn" -> emit(16, x, y, speed = 60f..140f, life = 0.35f..0.5f, size = 2f..4f,
                color = color)
            // Your own death is handled as a screen-space effect elsewhere (hitstop/slow-mo/
            // desaturate, §5.4, not yet built) — a world-space burst there too would double up.
            // Other snakes' deaths still burst so a scrum reads as violent from every
            // perspective but your own.
            "death" -> emit(18, x, y, speed = 70f..160f, life = 0.4f..0.6f, size = 3f..5f,
                color = color)
        }
    }

    private fun emit(
        count: Int, x: Float, y: Float,
        speed: ClosedFloatingPointRange<Float>, life: ClosedFloatingPointRange<Float>,
        size: ClosedFloatingPointRange<Float>, color: Color,
    ) {
        val budget = minOf(count, CAPACITY - particles.size)
        repeat(budget) {
            val angle = Math.random().toFloat() * (2f * Math.PI.toFloat())
            val s = speed.start + Math.random().toFloat() * (speed.endInclusive - speed.start)
            val l = life.start + Math.random().toFloat() * (life.endInclusive - life.start)
            val sz = size.start + Math.random().toFloat() * (size.endInclusive - size.start)
            particles.add(Particle(
                x = x, y = y,
                vx = cos(angle) * s, vy = sin(angle) * s,
                life = l, maxLife = l, size = sz, color = color,
            ))
        }
    }

    /** Called with events already de-duped against [lastEventTime] by the caller. Exposed
     * separately from [spawn] so the caller can look up each event's snake colour itself. */
    fun shouldSpawnFor(serverTime: Double): Boolean = serverTime > lastEventTime
    fun markSpawned(serverTime: Double) { lastEventTime = serverTime }

    /** nanoTime of the previous [stepWallClock] call; 0 means "not yet called". Owned here
     * rather than threaded through as a caller-managed parameter, since this system already
     * IS the one `remember`ed object the screen holds for this purpose — see the class doc. */
    private var lastStepAtNanos = 0L

    /** Advances on WALL-CLOCK time, not the render/interpolation clock's — a spark's decay is
     * not gameplay and must keep animating through a network stall rather than freeze
     * alongside it. [impact] dilates this call's dt so particles correctly hitstop/slow-mo
     * alongside the camera (ImpactTimeline's class doc). Safe to call once per draw; a no-op
     * on the very first call, which only establishes the baseline. */
    fun stepWallClock(impact: ImpactTimeline) {
        val now = System.nanoTime()
        if (lastStepAtNanos > 0L) step(impact.dilate((now - lastStepAtNanos) / 1_000_000_000f))
        lastStepAtNanos = now
    }

    private fun step(dtSeconds: Float) {
        if (dtSeconds <= 0f || particles.isEmpty()) return
        val drag = 1f - minOf(dtSeconds * 2.2f, 1f)
        var i = particles.size - 1
        while (i >= 0) {
            val p = particles[i]
            p.life -= dtSeconds
            if (p.life <= 0f) {
                particles.removeAt(i)
            } else {
                p.x += p.vx * dtSeconds
                p.y += p.vy * dtSeconds
                p.vx *= drag
                p.vy *= drag
            }
            i--
        }
    }

    /** Draw every live particle additively — a spark IS the light, unlike food/heads there is
     * no opaque core underneath to protect from softening, so this uses the same
     * [DrawScope.drawGlowDot] primitive as the rest of the bloom approximation. */
    fun DrawScope.draw() {
        particles.forEach { p ->
            val fade = (p.life / p.maxLife).coerceIn(0f, 1f)
            drawCircle(p.color.copy(alpha = 0.5f * fade), radius = p.size * 1.6f,
                center = Offset(p.x, p.y), blendMode = BlendMode.Plus)
        }
    }
}

private fun DrawScope.drawArena(
    frames: List<GamesEngine.SnakeFrame>,
    me: String?,
    trails: TrailStore,
    stick: Offset,
    camera: CameraMemory,
    particles: ParticleSystem,
    impact: ImpactTimeline,
    haptics: GameHaptics,
    boostAudio: BoostAudioState,
) {
    val s = pickSample(frames) ?: return
    val state = s.to

    // NEW events only, de-duped by the server's own clock (see ParticleSystem's doc comment).
    // Trigger detection runs BEFORE camera.step()/particles.stepWallClock() below, in the
    // same pass as spawning — unlike iOS, which has to split trigger-detection out earlier
    // because its camera step runs before its particle spawn. Here both already run after
    // this block, so a fresh trigger is live for both in the same frame with no extra split.
    if (particles.shouldSpawnFor(state.time)) {
        state.events.forEach { e ->
            val color = state.snakes.firstOrNull { it.id == e.snakeId }
                ?.let { paletteColor(it.colorIndex) } ?: Color.White
            particles.spawn(e.kind, e.x.toFloat(), e.y.toFloat(), color)

            // `eat`'s id is the EATING snake (snake/index.ts `k: 'eat'` push). GameHaptics.eat()
            // throttles internally, so no rate-limiting needed at this call site;
            // GameAudio.play()'s own min-gap table (matching iOS) does the same for sound.
            if (e.kind == "eat" && e.snakeId == me) {
                haptics.eat()
                // §7.4 "bake variants": 4 pitch-spaced eat files, picked at random rather than
                // by mass bucket — the event carries no food value to bucket by (see
                // GameHaptics.eat()'s identical note).
                GameAudio.play("eat_${(1..4).random()}", gain = 0.6f)
            }

            // Screen shake, hitstop AND haptic on YOUR kills only. `e.snakeId` on a "kill"
            // event is the KILLER (backend/games/src/engine/snake/index.ts kill() pushes
            // `id: killerId`), so this fires for the player who just won a fight, not their
            // victim.
            if (e.kind == "kill" && e.snakeId == me) {
                camera.triggerShake(6f)
                impact.triggerKill()
                haptics.kill()
                GameAudio.play("kill", gain = 0.75f)
            }
            // "death" events push `id: sn.id` — the snake that died — so this is unambiguously
            // "did I just die", not a kill I made. Opposite field semantics from "kill" above,
            // confirmed against the backend before wiring either.
            if (e.kind == "death" && e.snakeId == me) {
                impact.triggerDeath()
                haptics.death()
                GameAudio.play("death", gain = 0.85f)
            }
            if (e.kind == "spawn" && e.snakeId == me) {
                GameAudio.play("spawn", gain = 0.6f)
            }
        }
        particles.markSpawned(state.time)
    }
    particles.stepWallClock(impact)

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

    val mine = state.snakes.firstOrNull { it.id == me }

    // boost_start/boost_loop/boost_end: no server EVENT for these (boost is per-tick
    // continuous state, not a discrete occurrence like eat/kill) — see BoostAudioState's doc.
    val isBoosting = mine?.alive == true && mine.boosting
    if (isBoosting && !boostAudio.wasBoosting) {
        GameAudio.play("boost_start", gain = 0.6f)
        GameAudio.startLoop("boost_loop", gain = 0.35f)
    } else if (!isBoosting && boostAudio.wasBoosting) {
        GameAudio.stopLoop("boost_loop")
        GameAudio.play("boost_end", gain = 0.55f)
    }
    boostAudio.wasBoosting = isBoosting

    val mass = mine?.mass ?: 10.0

    // Zoom out as the snake grows so it stays framed, easing off so growth is not nauseating.
    // Already a smooth function of mass (never a snapped tier), which is what satisfies
    // GAMES_ANIMATION.md §5.2's "mass zoom" on its own — look-ahead and shake below are what
    // the doc adds on top.
    val zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
    val scale = (min(size.width, size.height) / 900f) * zoom.toFloat()

    // LOOK-AHEAD, then the FOLLOW SPRING (camera.step), then SHAKE applied last and never fed
    // back into the spring's own state — see CameraMemory's class doc for why each of those
    // three is ordered the way it is. This replaces the raw `heads[me]` this screen used to
    // pass straight to the transform below, which was the arena-wide flicker bug
    // (docs/GAMES_SNAKE_BUGS.md Part B) — iOS already has this spring (22b8680); this is the
    // Android port.
    val lookAhead = computeLookAhead(mine, headings[me])
    val target = heads[me]?.let { Offset(it.x + lookAhead.x, it.y + lookAhead.y) }
    val sprung = camera.step(target, impact)
    val shake = camera.shakeOffset(scale)
    val focus = Offset(sprung.x + shake.x, sprung.y + shake.y)

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

        // On top of every snake, same as a spark being the brightest thing on screen for its
        // short life. Drawn inside the SAME withTransform as everything else so particle world
        // coordinates need no separate camera math of their own.
        with(particles) { draw() }
    }

    // Death tint (GAMES_ANIMATION.md §5.4's "desaturate over 400ms"), drawn AFTER the
    // withTransform block closes rather than inside it — a screen-space rect needs no camera
    // math at all, unlike iOS's Metal version which draws a giant world-space circle because
    // that pipeline has no concept of "outside the current transform". Simpler here, same
    // result. A TRUE desaturate would need RenderEffect (API 31+) or a RuntimeShader (33+)
    // sampling the already-drawn frame; this darkens and cools instead, same tradeoff iOS
    // made and noted for the same reason — real cost for an effect one player sees for 400ms.
    val tint = impact.desaturation()
    if (tint > 0f) {
        // Capped at 0.6 alpha, not 1.0 — the point is a punch, not a blackout, and the death
        // panel that appears a beat later must stay legible against it.
        drawRect(Color(0xFF050810).copy(alpha = tint * 0.6f), size = size)
    }
}

private fun DrawScope.drawBoundary(radius: Float) {
    drawCircle(Color(0xFF120E28), radius = radius, center = Offset.Zero)

    // Drawn EXACTLY at the lethal line, not inside or outside it. A wall whose visible edge
    // disagrees with the killing surface makes every border death feel unfair, and players
    // cannot learn a boundary they cannot see precisely.
    //
    // GAMES_ANIMATION.md §4 tier C ("no shader access, three layered strokes at decreasing
    // width and increasing alpha with BlendMode.Plus"): this arena edge is exactly the shape
    // the doc calls out as the clearest place to prove the effect is doing something, since it
    // is both lethal and constantly on screen. iOS gets a real Gaussian-blurred bloom target
    // for the same ring (SnakeMetalView.buildArena); this is the minSdk-24 approximation of
    // the same intent — a rim of light, not a flat stroke — reachable on every device this app
    // supports, not just API 33+.
    drawGlowRing(radius = radius, center = Offset.Zero, color = Color(0xFF5AD8FF))

    drawCircle(
        Color(0xFF5AD8FF).copy(alpha = 0.16f), radius = radius - 20f,
        center = Offset.Zero, style = Stroke(width = 40f))
    drawCircle(Color(0xFF5AD8FF), radius = radius, center = Offset.Zero, style = Stroke(width = 6f))
}

/**
 * Additive layered-stroke glow: three strokes at decreasing width and increasing alpha,
 * `BlendMode.Plus` so overlapping glow brightens rather than occludes — the same behaviour
 * iOS gets from a real Gaussian blur in an offscreen bloom texture, approximated here with
 * geometry instead of a blur kernel. See GAMES_ANIMATION.md §4/§5.1.
 *
 * `BlendMode.Plus` is API 24+ (it is a Skia blend mode exposed since Compose's first release
 * on this minSdk), so this works everywhere the app runs — unlike RenderEffect blur (31+) or
 * a RuntimeShader (33+), which is why bloom is layered strokes here and a real blur on iOS.
 */
private fun DrawScope.drawGlowRing(radius: Float, center: Offset, color: Color) {
    drawCircle(color.copy(alpha = 0.10f), radius = radius + 26f, center = center,
        style = Stroke(width = 52f), blendMode = BlendMode.Plus)
    drawCircle(color.copy(alpha = 0.18f), radius = radius + 12f, center = center,
        style = Stroke(width = 24f), blendMode = BlendMode.Plus)
    drawCircle(color.copy(alpha = 0.30f), radius = radius + 3f, center = center,
        style = Stroke(width = 8f), blendMode = BlendMode.Plus)
}

/** Same three-layer additive approach as [drawGlowRing], for a point light instead of a ring. */
private fun DrawScope.drawGlowDot(radius: Float, center: Offset, color: Color) {
    drawCircle(color.copy(alpha = 0.10f), radius = radius * 3.2f, center = center,
        blendMode = BlendMode.Plus)
    drawCircle(color.copy(alpha = 0.18f), radius = radius * 2.2f, center = center,
        blendMode = BlendMode.Plus)
    drawCircle(color.copy(alpha = 0.30f), radius = radius * 1.4f, center = center,
        blendMode = BlendMode.Plus)
}

private fun DrawScope.drawFood(state: GamesEngine.SnakeState) {
    // Food never moves, so it is drawn from the newest frame with no interpolation.
    state.food.forEach { item ->
        val r = if (item.value >= 2) 7f else if (item.value < 1) 4.5f else 5.5f
        val color = if (item.value >= 2) Color(0xFFFFB873) else Color(0xFFFFEE9E)
        val centre = Offset(item.x.toFloat(), item.y.toFloat())
        drawGlowDot(radius = r, center = centre, color = color)
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
    // The head halo is the single most-looked-at glow in the game — this is what makes
    // "every bright thing emits" (GAMES_ANIMATION.md §3.3) actually true of the thing the
    // player is steering. Additive so a boosting snake's own trail glow and the head halo
    // brighten together instead of the head simply occluding the trail.
    drawGlowDot(radius = r, center = head, color = color)
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

    // Spring-back. Keyed so the loop EXISTS ONLY WHILE THE KNOB IS AWAY FROM CENTRE.
    //
    // An unconditional `while (true) { withFrameNanos { ... } }` here was a permanent 60 Hz
    // wake-up that wrote state every frame, so Compose re-composed continuously and — on top
    // of the arena's own frame loop — starved the main thread badly enough that touch
    // dispatch stopped. That is what made the screen go black AND the joystick go dead.
    val springing = !held && knob != Offset.Zero
    LaunchedEffect(springing) {
        if (!springing) return@LaunchedEffect
        var lastNanos = 0L
        while (knob != Offset.Zero && !held) {
            withFrameNanos { now ->
                val dt = if (lastNanos == 0L) 0f else ((now - lastNanos) / 1_000_000_000.0).toFloat()
                lastNanos = now
                val decay = kotlin.math.exp(-14.0 * dt).toFloat()
                val next = knob * decay
                knob = if (hypot(next.x, next.y) < 0.5f) Offset.Zero else next
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
                    // ancestor looked at it first.
                    val down = awaitFirstDown(requireUnconsumed = false)
                    val r = size.width / 2f / 1.4f
                    held = true
                    knob = clampToRing(down.position, size.width, r)
                    onVector(knob / r)

                    // NOTHING IS CONSUMED HERE, and that is deliberate.
                    //
                    // Consuming told the rest of the pointer pipeline this gesture was
                    // handled, and after a while events stopped arriving at this handler at
                    // all — steering worked for a bit and then went dead for the rest of the
                    // match. This joystick sits in its own corner of the screen with nothing
                    // competing for the same touches, so it has nothing to claim them from.
                    //
                    // Tracking is also NOT bound to `down.id`: a pointer id can change during
                    // a gesture, and matching on it dropped the finger mid-drag. Any pressed
                    // pointer inside this handler is the one steering.
                    while (true) {
                        val event = awaitPointerEvent()
                        val change = event.changes.firstOrNull { it.pressed } ?: break
                        knob = clampToRing(change.position, size.width, r)
                        onVector(knob / r)
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
