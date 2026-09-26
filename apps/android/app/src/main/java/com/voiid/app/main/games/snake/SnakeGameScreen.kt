package com.voiid.app.main.games.snake

import android.app.Activity
import android.graphics.Paint
import android.graphics.Typeface
import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.awaitEachGesture
import androidx.compose.foundation.gestures.awaitFirstDown
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.nativeCanvas
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import androidx.lifecycle.compose.LocalLifecycleOwner
import androidx.lifecycle.repeatOnLifecycle
import com.voiid.app.main.games.GameSettingsSheet
import com.voiid.app.main.games.SnakeChoiceStore
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDialog
import com.voiid.app.ui.theme.VoiidFont
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.roundToInt
import kotlin.math.sqrt

/*
 * Port of iOS `Games/Snake/SnakeGameView.swift` + `SnakeScene.swift`: the offline Snake Arena.
 * The SpriteKit scene becomes one Canvas driven by a frame loop; the SwiftUI HUD, joystick,
 * boost button, pause card and death recap are copied layout for layout.
 */

private val Amber = Color(0xFFE8A62E)          // iOS (0.91, 0.65, 0.18)
private val Arena = Color(0xFF0B1016)          // iOS (0.043, 0.063, 0.086)
private val CardFill = Color(0xFF141C26)       // iOS (0.08, 0.11, 0.15)
private val RimRed = Color(0xFFE04F40)         // iOS (0.88, 0.31, 0.25)

private val Palette = listOf(
    Color(0xFFE04F40), Color(0xFF2EA36B), Color(0xFFE8A62E), Color(0xFF3B7DD9),
    Color(0xFFA35CD9), Color(0xFF26B8B8), Color(0xFFED709E), Color(0xFFBFC94D),
)

private fun colour(i: Int) = Palette[Math.floorMod(i, Palette.size)]

/** iOS `SnakeSession`: the HUD's published readouts. */
private class SnakeSession(val botCount: Int) {
    var score by mutableIntStateOf(0)
    var length by mutableIntStateOf(0)
    var rank by mutableIntStateOf(1)
    var mass by mutableFloatStateOf(Cfg.START_MASS)
    var alive by mutableStateOf(true)
    var best by mutableIntStateOf(0)
    var kills by mutableIntStateOf(0)
    var leaderboard by mutableStateOf<List<LeaderRow>>(emptyList())
    var boosting = false

    fun reset() {
        score = 0; length = 0; rank = 1; kills = 0
        mass = Cfg.START_MASS; alive = true; boosting = false
    }
}

/** iOS `SnakeScene`: the world, its camera, and the per-frame bookkeeping. */
private class SnakeScene(val session: SnakeSession, val onKill: () -> Unit, val onDeath: () -> Unit) {
    val world = SnakeWorld().also { it.reset(session.botCount) }
    var camX = world.player?.head?.x ?: 0f
    var camY = world.player?.head?.y ?: 0f
    var camScale = 1f
    var acceptsDirectTouches = true
    private var lastNanos = 0L
    private var hudClock = 0f
    private var prevKills = 0

    fun frame(nanos: Long) {
        val dt = if (lastNanos == 0L) 1f / 60 else min((nanos - lastNanos) / 1e9f, 0.1f)
        lastNanos = nanos
        world.playerBoosting = session.boosting
        world.step(dt)
        followCamera(dt)
        publish(dt)
    }

    /** The clock restarts after any gap, so a resume never replays the time spent away. */
    fun resetClock() { lastNanos = 0L }

    private fun followCamera(dt: Float) {
        val p = world.player ?: return
        if (!p.alive) return
        val t = min(1f, dt * 9)
        camX += (p.head.x - camX) * t
        camY += (p.head.y - camY) * t
        val target = 1f + min((p.mass / Cfg.START_MASS).pow(0.30f) - 1, 1.6f)
        camScale += (target - camScale) * min(1f, dt * 2)
    }

    private fun publish(dt: Float) {
        hudClock += dt
        if (hudClock <= 0.12f) return
        hudClock = 0f
        world.player?.let { p ->
            if (p.alive) {
                session.score = p.score
                session.length = p.body.size
                session.rank = world.rank(p)
                session.mass = p.mass
                session.kills = world.playerKills
                if (world.playerKills > prevKills) { prevKills = world.playerKills; onKill() }
            } else if (session.alive) {
                session.alive = false
                session.best = max(session.best, p.score)
                session.boosting = false
                onDeath()
            }
        }
        session.leaderboard = world.leaderboard()
    }

    fun aimAt(worldX: Float, worldY: Float) {
        val p = world.player ?: return
        val v = P(worldX, worldY) - p.head
        if (v.length <= 4) return
        world.playerAim = v.angle
    }

    fun aimDirection(dx: Float, dy: Float) {
        val v = P(dx, dy)
        if (v.length <= 0.001f) return
        world.playerAim = v.angle
    }

    fun restart() {
        camScale = 1f
        prevKills = 0
        world.reset(session.botCount)
        world.player?.let { camX = it.head.x; camY = it.head.y }
        session.reset()
        resetClock()
    }

    fun pause() { world.isPaused = true }
    fun resume() { world.isPaused = false; resetClock() }
}

@Composable
fun SnakeGameScreen(mode: String = "easy", onClose: () -> Unit) {
    val context = LocalContext.current
    val haptics = LocalVoiidHaptics.current
    val botCount = when (mode) { "easy", "calm", "practice" -> 4; "hard" -> 14; else -> 8 }
    val session = remember { SnakeSession(botCount) }
    val scene = remember { SnakeScene(session, onKill = { haptics.soft() }, onDeath = { haptics.rigid() }) }
    val choices = remember(context) { SnakeChoiceStore(context) }

    var boostHeld by remember { mutableStateOf(false) }
    var confirmQuit by remember { mutableStateOf(false) }
    var isManuallyPaused by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }
    // Read once on appear and refreshed when the settings sheet closes: changing the scheme
    // mid-match would move the controls under the player's thumb.
    var scheme by remember { mutableStateOf(choices.controlScheme) }
    var knob by remember { mutableStateOf(Offset.Zero) }
    var frameTick by remember { mutableIntStateOf(0) }

    LaunchedEffect(scheme) { scene.acceptsDirectTouches = scheme == SnakeChoiceStore.ControlScheme.SWIPE }

    // .statusBarHidden() + .persistentSystemOverlays(.hidden)
    val activity = context as? Activity
    DisposableEffect(activity) {
        val window = activity?.window
        val controller = window?.let { WindowCompat.getInsetsController(it, it.decorView) }
        controller?.systemBarsBehavior = WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller?.hide(WindowInsetsCompat.Type.systemBars())
        onDispose { controller?.show(WindowInsetsCompat.Type.systemBars()) }
    }

    // scenePhase → background: pause behind the pause card, never silently keep running.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val obs = LifecycleEventObserver { _, e ->
            if (e == Lifecycle.Event.ON_PAUSE && session.alive) { scene.pause(); isManuallyPaused = true }
        }
        lifecycleOwner.lifecycle.addObserver(obs)
        onDispose { lifecycleOwner.lifecycle.removeObserver(obs); scene.pause() }
    }

    LaunchedEffect(confirmQuit) {
        if (confirmQuit) scene.pause() else if (!isManuallyPaused) scene.resume()
    }

    LaunchedEffect(Unit) {
        lifecycleOwner.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            scene.resetClock()
            while (true) withFrameNanos { scene.frame(it); frameTick++ }
        }
    }

    BackHandler { if (session.alive) confirmQuit = true else onClose() }

    Box(Modifier.fillMaxSize().background(Arena)) {
        val density = LocalDensity.current.density
        val labelPaint = remember {
            Paint(Paint.ANTI_ALIAS_FLAG).apply {
                color = android.graphics.Color.argb(140, 255, 255, 255)
                textAlign = Paint.Align.CENTER
                typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            }
        }
        Canvas(
            Modifier.fillMaxSize().pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown(requireUnconsumed = false)
                    fun steer(o: Offset) {
                        if (!scene.acceptsDirectTouches) return
                        val s = scene.camScale / density
                        scene.aimAt(scene.camX + (o.x - size.width / 2f) * s, scene.camY + (o.y - size.height / 2f) * s)
                    }
                    steer(down.position)
                    while (true) {
                        val ev = awaitPointerEvent()
                        val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                        if (!c.pressed) break
                        steer(c.position)
                    }
                }
            },
        ) {
            @Suppress("UNUSED_EXPRESSION") frameTick
            drawArena(scene, density, labelPaint)
        }

        Column(Modifier.fillMaxSize().safeDrawingPadding().padding(horizontal = 16.dp, vertical = 10.dp)) {
            TopBar(
                session = session,
                paused = isManuallyPaused,
                onBack = { if (session.alive) confirmQuit = true else onClose() },
                onPauseToggle = {
                    haptics.soft()
                    if (isManuallyPaused) { isManuallyPaused = false; scene.resume() }
                    else { scene.pause(); isManuallyPaused = true }
                },
                onSettings = { haptics.soft(); scene.pause(); isManuallyPaused = true; showSettings = true },
            )
            Spacer(Modifier.weight(1f))
            Row(verticalAlignment = Alignment.Bottom) {
                if (scheme == SnakeChoiceStore.ControlScheme.JOYSTICK) {
                    Joystick(knob, onKnob = { v ->
                        if (session.alive) {
                            knob = v
                            if (v != Offset.Zero) scene.aimDirection(v.x, v.y)
                        } else knob = Offset.Zero
                    })
                } else {
                    Text("Drag anywhere to steer", style = VoiidFont.rounded(11, FontWeight.Medium),
                        color = Color.White.copy(alpha = 0.3f))
                }
                Spacer(Modifier.weight(1f))
                BoostButton(
                    held = boostHeld,
                    enabled = session.mass > Cfg.MIN_MASS + 4,
                    onPress = {
                        if (session.alive && !boostHeld) { boostHeld = true; session.boosting = true; haptics.tap() }
                    },
                    onRelease = { boostHeld = false; session.boosting = false },
                )
            }
        }

        AnimatedVisibility(isManuallyPaused && session.alive, enter = fadeIn(), exit = fadeOut()) {
            PauseOverlay(
                session,
                onResume = { haptics.soft(); isManuallyPaused = false; scene.resume() },
                onRestart = { haptics.soft(); isManuallyPaused = false; scene.restart() },
                onSettings = { haptics.soft(); showSettings = true },
                onQuit = { confirmQuit = true },
            )
        }
        AnimatedVisibility(!session.alive, enter = fadeIn(), exit = fadeOut()) {
            DeathScreen(session, onPlayAgain = { scene.restart() }, onLeave = onClose)
        }
    }

    if (confirmQuit) VoiidDialog(
        onDismissRequest = { confirmQuit = false },
        title = "Leave the arena?",
        body = "Your run ends here.",
        confirmLabel = "Leave",
        onConfirm = { confirmQuit = false; scene.pause(); onClose() },
        confirmDestructive = true,
        cancelLabel = "Keep playing",
    )

    if (showSettings) GameSettingsSheet(onDismiss = {
        showSettings = false
        // Picking a scheme in the sheet has to reach the running match.
        scheme = choices.controlScheme
        knob = Offset.Zero
    })
}

// MARK: - Arena drawing (SnakeScene)

private fun DrawScope.drawArena(scene: SnakeScene, density: Float, labelPaint: Paint) {
    val world = scene.world
    val k = density / scene.camScale                  // world units → px
    val cx = size.width / 2f; val cy = size.height / 2f
    fun sx(x: Float) = cx + (x - scene.camX) * k
    fun sy(y: Float) = cy + (y - scene.camY) * k
    val halfW = size.width / 2f / k; val halfH = size.height / 2f / k
    val left = scene.camX - halfW; val right = scene.camX + halfW
    val top = scene.camY - halfH; val bottom = scene.camY + halfH

    // Grid, clipped to the arena circle, 140 apart.
    val r = Cfg.ARENA_RADIUS
    val gridColour = Color.White.copy(alpha = 0.045f)
    val stroke = max(1f, density / scene.camScale)
    var x = -r
    while (x <= r) {
        if (x in left..right) {
            val h = sqrt(max(r * r - x * x, 0f))
            drawLine(gridColour, Offset(sx(x), sy(max(-h, top))), Offset(sx(x), sy(min(h, bottom))), stroke)
        }
        x += 140f
    }
    var y = -r
    while (y <= r) {
        if (y in top..bottom) {
            val w = sqrt(max(r * r - y * y, 0f))
            drawLine(gridColour, Offset(sx(max(-w, left)), sy(y)), Offset(sx(min(w, right)), sy(y)), stroke)
        }
        y += 140f
    }
    // Rim with its glow.
    val centre = Offset(sx(0f), sy(0f))
    drawCircle(RimRed.copy(alpha = 0.12f), r * k, centre, style = Stroke(26f * k))
    drawCircle(RimRed.copy(alpha = 0.5f), r * k, centre, style = Stroke(6f * k))

    // Food.
    for (f in world.food) {
        val p = f.position
        if (p.x < left - 40 || p.x > right + 40 || p.y < top - 40 || p.y > bottom + 40) continue
        drawCircle(colour(f.skin).copy(alpha = 0.92f), f.radius * k, Offset(sx(p.x), sy(p.y)))
    }

    // Snakes.
    for (s in world.snakes) {
        if (!s.alive) continue
        val c = colour(s.skin)
        val rad = s.radius
        val pad = rad * 2
        val n = s.body.size
        for (i in n - 1 downTo 0) {
            val p = s.body[i]
            if (p.x < left - pad || p.x > right + pad || p.y < top - pad || p.y > bottom + pad) continue
            val t = i.toFloat() / max(n - 1, 1)
            drawCircle(c.copy(alpha = 1f - t * 0.18f), rad * k, Offset(sx(p.x), sy(p.y)))
        }
        val fwd = P.fromAngle(s.heading, rad * 0.42f)
        val side = P.fromAngle(s.heading + (Math.PI / 2).toFloat(), rad * 0.46f)
        val gaze = P.fromAngle(s.desiredHeading, rad * 0.16f)
        for (eye in listOf(s.head + fwd + side, s.head + fwd - side)) {
            drawCircle(Color.White, rad * 0.36f * k, Offset(sx(eye.x), sy(eye.y)))
            drawCircle(Color(0xFF171717), rad * 0.18f * k, Offset(sx(eye.x + gaze.x), sy(eye.y + gaze.y)))
        }
        if (!s.isPlayer && s.mass > 40) {
            labelPaint.textSize = 13f * k
            val ly = s.head.y - (rad + 14f)
            drawContext.canvas.nativeCanvas.drawText(s.name, sx(s.head.x), sy(ly) - (labelPaint.ascent() + labelPaint.descent()) / 2, labelPaint)
        }
    }
}

// MARK: - HUD

@Composable
private fun HudCircle(icon: ImageVector, label: String, alpha: Float, size: Int, onClick: () -> Unit) {
    Box(
        Modifier.size(34.dp).clip(CircleShape).background(Color.Black.copy(alpha = 0.32f))
            .clickable(onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = Color.White.copy(alpha = alpha), modifier = Modifier.size(size.dp)) }
}

@Composable
private fun TopBar(session: SnakeSession, paused: Boolean, onBack: () -> Unit, onPauseToggle: () -> Unit, onSettings: () -> Unit) {
    Row(verticalAlignment = Alignment.Top, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
        HudCircle(Icons.Default.ChevronLeft, "Leave game", 0.75f, 22, onBack)
        if (session.alive) {
            HudCircle(if (paused) Icons.Default.PlayArrow else Icons.Default.Pause,
                if (paused) "Resume game" else "Pause game", 0.85f, 18, onPauseToggle)
            HudCircle(Icons.Default.Settings, "Game settings", 0.85f, 18, onSettings)
        }
        Column(verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text("${session.score}", style = VoiidFont.rounded(34, FontWeight.ExtraBold), color = Color.White)
            Text(
                "LENGTH ${session.length}   ·   RANK ${session.rank}" +
                    if (session.kills > 0) "   ·   KILLS ${session.kills}" else "",
                style = VoiidFont.rounded(10, FontWeight.SemiBold).copy(letterSpacing = 1.2.sp),
                color = Color.White.copy(alpha = 0.45f),
            )
        }
        Spacer(Modifier.weight(1f))
        Column(
            Modifier.clip(RoundedCornerShape(12.dp)).background(Color.Black.copy(alpha = 0.32f))
                .padding(horizontal = 10.dp, vertical = 8.dp),
            verticalArrangement = Arrangement.spacedBy(4.dp),
            horizontalAlignment = Alignment.End,
        ) {
            session.leaderboard.forEachIndexed { i, row ->
                Row(horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
                    Text("${i + 1}", style = VoiidFont.rounded(10, FontWeight.Bold), color = Color.White.copy(alpha = 0.3f),
                        textAlign = TextAlign.End, modifier = Modifier.width(12.dp))
                    Text(row.name, style = VoiidFont.rounded(12, if (row.isPlayer) FontWeight.Bold else FontWeight.Medium),
                        color = if (row.isPlayer) Color.White else Color.White.copy(alpha = 0.62f))
                    Text("${row.score}", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.42f),
                        textAlign = TextAlign.End, modifier = Modifier.width(42.dp))
                }
            }
        }
    }
}

/** A fixed ring whose knob follows the thumb; letting go re-centres the knob but keeps the heading. */
@Composable
private fun Joystick(knob: Offset, onKnob: (Offset) -> Unit) {
    val radius = 42f
    val density = LocalDensity.current.density
    val knobAlpha by animateFloatAsState(if (knob == Offset.Zero) 0.35f else 0.85f, tween(120), label = "knob")
    Box(
        Modifier.size((radius * 2).dp).semantics { contentDescription = "Steering joystick" }
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    val start = down.position
                    while (true) {
                        val ev = awaitPointerEvent()
                        val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                        if (!c.pressed) break
                        c.consume()
                        val v = (c.position - start) / density
                        val len = v.getDistance()
                        onKnob(if (len > radius) v / len * radius else v)
                    }
                    onKnob(Offset.Zero)
                }
            },
        contentAlignment = Alignment.Center,
    ) {
        Box(Modifier.fillMaxSize().clip(CircleShape).background(Color.White.copy(alpha = 0.10f))
            .border(1.5.dp, Color.White.copy(alpha = 0.28f), CircleShape))
        Box(
            Modifier.offset { IntOffset((knob.x * density).roundToInt(), (knob.y * density).roundToInt()) }
                .size(34.dp).clip(CircleShape).background(Color.White.copy(alpha = knobAlpha)),
        )
    }
}

@Composable
private fun BoostButton(held: Boolean, enabled: Boolean, onPress: () -> Unit, onRelease: () -> Unit) {
    val scale by animateFloatAsState(if (held) 0.93f else 1f, tween(120), label = "boost")
    Box(
        Modifier.alpha(if (enabled) 1f else 0.35f).scale(scale).size(84.dp).clip(CircleShape)
            .background(if (held) Amber else Color.White.copy(alpha = 0.14f))
            .border(1.5.dp, Color.White.copy(alpha = 0.35f), CircleShape)
            .pointerInput(Unit) {
                awaitEachGesture {
                    val down = awaitFirstDown()
                    down.consume()
                    onPress()
                    while (true) {
                        val ev = awaitPointerEvent()
                        val c = ev.changes.firstOrNull { it.id == down.id } ?: break
                        c.consume()
                        if (!c.pressed) break
                    }
                    onRelease()
                }
            }
            .semantics { contentDescription = "Boost" },
        contentAlignment = Alignment.Center,
    ) {
        Text("BOOST", style = VoiidFont.rounded(12, FontWeight.ExtraBold).copy(letterSpacing = 1.sp),
            color = if (held) Color.Black else Color.White.copy(alpha = 0.7f))
    }
}

// MARK: - Death / pause

@Composable
private fun Scrim(alpha: Float, content: @Composable () -> Unit) {
    Box(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = alpha))
            .clickable(interactionSource = remember { MutableInteractionSource() }, indication = null) {},
        contentAlignment = Alignment.Center,
    ) { content() }
}

@Composable
private fun Card(pad: Int, outer: Int, strokeAlpha: Float, content: @Composable () -> Unit) {
    Box(
        Modifier.padding(outer.dp).clip(RoundedCornerShape(22.dp)).background(CardFill)
            .border(1.dp, Color.White.copy(alpha = strokeAlpha), RoundedCornerShape(22.dp)).padding(pad.dp),
    ) { content() }
}

@Composable
private fun DeathScreen(session: SnakeSession, onPlayAgain: () -> Unit, onLeave: () -> Unit) {
    Scrim(0.72f) {
        Card(34, 24, 0.1f) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(6.dp)) {
                Text("Eaten", style = VoiidFont.rounded(30, FontWeight.ExtraBold), color = Color.White)
                Text("${session.score}", style = VoiidFont.rounded(52, FontWeight.ExtraBold), color = Amber)
                Row(Modifier.padding(bottom = 22.dp), horizontalArrangement = Arrangement.spacedBy(14.dp)) {
                    val st = VoiidFont.rounded(11, FontWeight.SemiBold).copy(letterSpacing = 1.4.sp)
                    val c = Color.White.copy(alpha = 0.4f)
                    Text("BEST ${session.best}", style = st, color = c)
                    if (session.kills > 0) { Text("·", style = st, color = c); Text("${session.kills} KILLS", style = st, color = c) }
                }
                Box(
                    Modifier.clip(CircleShape).background(Amber).clickable(onClick = onPlayAgain)
                        .padding(horizontal = 30.dp, vertical = 15.dp),
                ) {
                    Text("PLAY AGAIN", style = VoiidFont.rounded(13, FontWeight.ExtraBold).copy(letterSpacing = 1.6.sp), color = Color.Black)
                }
                Text("Leave arena", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.45f),
                    modifier = Modifier.padding(top = 10.dp).clickable(onClick = onLeave))
            }
        }
    }
}

@Composable
private fun PauseOverlay(session: SnakeSession, onResume: () -> Unit, onRestart: () -> Unit, onSettings: () -> Unit, onQuit: () -> Unit) {
    Scrim(0.65f) {
        Card(28, 32, 0.12f) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Text("GAME PAUSED", style = VoiidFont.rounded(15, FontWeight.ExtraBold).copy(letterSpacing = 2.5.sp), color = Amber)
                Row(Modifier.padding(vertical = 8.dp), horizontalArrangement = Arrangement.spacedBy(20.dp)) {
                    StatCell("SCORE", "${session.score}")
                    StatCell("RANK", "${session.rank}")
                    StatCell("KILLS", "${session.kills}")
                }
                Row(
                    Modifier.fillMaxWidth().clip(CircleShape).background(Amber).clickable(onClick = onResume).padding(vertical = 14.dp),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.PlayArrow, null, tint = Color.Black, modifier = Modifier.size(17.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("RESUME", style = VoiidFont.rounded(14, FontWeight.ExtraBold).copy(letterSpacing = 1.4.sp), color = Color.Black)
                }
                Box(
                    Modifier.fillMaxWidth().clip(CircleShape).background(Color.White.copy(alpha = 0.1f)).clickable(onClick = onRestart)
                        .padding(vertical = 11.dp),
                    contentAlignment = Alignment.Center,
                ) { Text("Restart Arena", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.8f)) }
                Row(
                    Modifier.fillMaxWidth().clip(CircleShape).background(Color.White.copy(alpha = 0.08f)).clickable(onClick = onSettings)
                        .padding(vertical = 11.dp),
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    Icon(Icons.Default.Settings, null, tint = Color.White.copy(alpha = 0.85f), modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(8.dp))
                    Text("Game Settings", style = VoiidFont.rounded(13, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.85f))
                }
                Text("Quit match", style = VoiidFont.rounded(12, FontWeight.SemiBold), color = Color.White.copy(alpha = 0.45f),
                    modifier = Modifier.padding(top = 4.dp).clickable(onClick = onQuit))
            }
        }
    }
}

@Composable
private fun StatCell(label: String, value: String) {
    Column(Modifier.widthIn(min = 64.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Text(value, style = VoiidFont.rounded(24, FontWeight.Bold), color = Color.White)
        Text(label, style = VoiidFont.rounded(10, FontWeight.Bold).copy(letterSpacing = 1.2.sp), color = Color.White.copy(alpha = 0.4f))
    }
}
