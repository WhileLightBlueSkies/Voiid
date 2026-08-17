package com.voiid.app.main.games

import android.content.Intent
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.DragHandle
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.zIndex
import com.voiid.app.net.ApiClient
import com.voiid.app.net.GamesService
import com.voiid.app.net.TokenStore
import com.voiid.app.ui.components.VoiidHaptics
import com.voiid.app.ui.components.rememberVoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.math.sin
import kotlin.math.withSign

/**
 * The win / defeat / tie screen, shared by every game
 * (docs/games/VISUALS_AUDIO_AND_PARITY.md §9).
 *
 * WHAT THIS REPLACES. Five of six games ended with a line of text next to a Rematch button;
 * Snake had a panel reading "You finished with 47". The match is where the story is, and it was
 * discarded at the moment it was most interesting (CROSS_CUTTING.md §2).
 *
 * THE RULE THE WHOLE THING IS BUILT ON (§9.2):
 *
 *     The board finishes its sentence before the verdict speaks.
 *
 * Tic Tac Toe already did this — the win stroke draws, THEN the verdict appears — and it was the
 * only game that did. Everywhere else the result overwrote its own cause: a ship sank and "You
 * win" appeared in the same frame, so the player never saw the ship go down. Hence
 * [HOLD_BEFORE_SCRIM]: 450 ms in which nothing moves and the player reads the board.
 *
 * AND THE BOARD IS NEVER CLEARED. The scrim dims it and sits on top. Being able to see the final
 * board while reading the verdict is the difference between a result and a receipt.
 *
 * Ported from iOS `MatchEndOverlay.swift`. The timings below are a parity surface.
 */
private const val HOLD_BEFORE_SCRIM = 450L
private const val VERDICT_AT = 560L
private const val STATS_AT = 760L
private const val STAT_STAGGER = 60L
private const val ACTIONS_AT = 1100L
private const val FLOURISH_AT = 1250L

@Composable
fun MatchEndOverlay(
    result: MatchEndResult,
    onExit: () -> Unit,
    modifier: Modifier = Modifier,
    /** Online: mint a rematch. Null hides the button. */
    matchId: String? = null,
    onRematch: ((String) -> Unit)? = null,
    /** Practice: a local reset, which needs no server. Null hides it. */
    onPlayAgain: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val haptics = rememberVoiidHaptics()
    val reduceMotion = remember { ReduceMotion.isEnabled(context) }
    val scope = androidx.compose.runtime.rememberCoroutineScope()
    val service = remember(context) { GamesService(ApiClient(TokenStore.get(context))) }

    // 0 hidden, 1 scrim, 2 verdict, 3 stats, 4 actions
    var phase by remember { mutableIntStateOf(0) }
    var confetti by remember { mutableStateOf(false) }
    var requestingRematch by remember { mutableStateOf(false) }
    var rematchFailure by remember { mutableStateOf<String?>(null) }

    val scale = result.outcome.sequenceScale
    // Resolved HERE because VoiidColor.primary is a @Composable getter — see MatchEndResult.accent.
    val accent = result.accent ?: VoiidColor.primary

    LaunchedEffect(Unit) {
        // Under reduce-motion the overlay is simply THERE, fully formed. Not the animation
        // played faster — the animation not happening (§9.10). Sound still plays: reduce-motion
        // is about motion, not audio, and the stinger is often how the result is perceived.
        if (reduceMotion) {
            phase = 4
            playResult(result, haptics)
            return@LaunchedEffect
        }

        delay(HOLD_BEFORE_SCRIM)
        phase = 1
        delay(((VERDICT_AT - HOLD_BEFORE_SCRIM) * scale).toLong())
        // Verdict, sound and haptic land on the SAME frame.
        phase = 2
        playResult(result, haptics)
        delay(((STATS_AT - VERDICT_AT) * scale).toLong())
        phase = 3
        delay(((ACTIONS_AT - STATS_AT) * scale).toLong())
        phase = 4
        // A win, and only a genuine one, gets the flourish.
        if (result.outcome == MatchEndResult.Outcome.WIN && !result.hollow) {
            delay(((FLOURISH_AT - ACTIONS_AT) * scale).toLong())
            confetti = true
        }
    }

    Box(
        modifier
            .fillMaxSize()
            .zIndex(10f)
            // TAPPING SKIPS TO THE END STATE. Never trap a player in a celebration.
            .clickable(
                interactionSource = remember { MutableInteractionSource() },
                indication = null,
            ) { if (phase < 4) phase = 4 },
    ) {
        // THE BOARD STAYS VISIBLE BEHIND THIS. Never a black screen — a dim, not a curtain.
        val scrimAlpha by animateFloatAsState(
            targetValue = if (phase >= 1) 1f else 0f,
            animationSpec = tween(if (reduceMotion) 0 else 260),
            label = "scrim",
        )
        Box(
            Modifier
                .fillMaxSize()
                .alpha(scrimAlpha)
                .background(scrimBrush(result, accent)),
        )

        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = VoiidSpacing.xl, vertical = VoiidSpacing.xl),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            Verdict(result, accent, phase, reduceMotion)

            if (result.stats.isNotEmpty()) {
                Spacer(Modifier.height(VoiidSpacing.lg))
                StatsPanel(result, accent, phase, scale, reduceMotion)
            }

            Spacer(Modifier.height(VoiidSpacing.xl))

            Actions(
                result = result,
                accent = accent,
                phase = phase,
                requesting = requestingRematch,
                failure = rematchFailure,
                onPlayAgain = onPlayAgain,
                onRematch = if (matchId != null && onRematch != null) {
                    {
                        if (!requestingRematch) {
                            requestingRematch = true
                            rematchFailure = null
                            scope.launch {
                                // Mints a NEW match rather than reopening the finished one — the
                                // old row holds a result the leaderboard already counted.
                                val newId = runCatching { service.rematch(matchId) }.getOrNull()
                                requestingRematch = false
                                if (newId != null) {
                                    onRematch(newId)
                                } else {
                                    // DELIBERATELY VAGUE, and deliberately not the server's
                                    // message: the route returns 403 without naming which player
                                    // failed so it cannot be used to probe whether a user id
                                    // exists. This covers blocked, deleted and offline alike.
                                    rematchFailure =
                                        "Couldn't start a rematch. They may have left."
                                }
                            }
                        }
                    }
                } else null,
                onExit = onExit,
                onShare = {
                    val text = result.shareText ?: return@Actions
                    val send = Intent(Intent.ACTION_SEND).apply {
                        type = "text/plain"
                        putExtra(Intent.EXTRA_TEXT, text)
                    }
                    context.startActivity(Intent.createChooser(send, null))
                },
            )
        }

        if (confetti && !reduceMotion) ConfettiBurst(accent)
    }
}

private fun playResult(result: MatchEndResult, haptics: VoiidHaptics) {
    // A hollow win — one taken by resignation or timeout — gets the stinger at half gain.
    // Winning because somebody left is not a victory (§9.7).
    GameAudio.play(result.outcome.sound, gain = if (result.hollow) 0.5f else 0.85f)
    when (result.outcome) {
        MatchEndResult.Outcome.WIN -> if (result.hollow) haptics.tap() else haptics.success()
        // One thud. Not a sequence — a defeat gets less (§9.5).
        MatchEndResult.Outcome.LOSE -> haptics.rigid()
        MatchEndResult.Outcome.TIE -> haptics.soft()
    }
}

@Composable
@androidx.compose.runtime.ReadOnlyComposable
private fun scrimBrush(result: MatchEndResult, accent: Color): Brush = when (result.outcome) {
    // Tinted with the game's accent, so the overlay belongs to the board behind it.
    MatchEndResult.Outcome.WIN -> Brush.verticalGradient(
        listOf(accent.copy(alpha = 0.34f), VoiidColor.background.copy(alpha = 0.86f)),
    )
    MatchEndResult.Outcome.LOSE -> Brush.verticalGradient(
        listOf(Color(0xFF0F0F17).copy(alpha = 0.80f), Color(0xFF0F0F17).copy(alpha = 0.88f)),
    )
    MatchEndResult.Outcome.TIE -> Brush.verticalGradient(
        listOf(VoiidColor.background.copy(alpha = 0.76f), VoiidColor.background.copy(alpha = 0.82f)),
    )
}

@Composable
private fun Verdict(result: MatchEndResult, accent: Color, phase: Int, reduceMotion: Boolean) {
    val shown = phase >= 2
    // A win scales UP and overshoots; a defeat scales DOWN and settles like a weight, with no
    // overshoot at all; a tie meets in the middle. Direction is the whole design (§9.5).
    val target = if (shown) 1f else when (result.outcome) {
        MatchEndResult.Outcome.WIN -> 0.70f
        MatchEndResult.Outcome.LOSE -> 1.25f
        MatchEndResult.Outcome.TIE -> 0.94f
    }
    val scale by animateFloatAsState(
        targetValue = target,
        animationSpec = if (reduceMotion) tween(0) else when (result.outcome) {
            MatchEndResult.Outcome.WIN ->
                spring(dampingRatio = 0.55f, stiffness = Spring.StiffnessMediumLow)
            MatchEndResult.Outcome.LOSE -> tween(320)
            MatchEndResult.Outcome.TIE ->
                spring(dampingRatio = 0.85f, stiffness = Spring.StiffnessMediumLow)
        },
        label = "verdict",
    )
    val alpha by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = tween(if (reduceMotion) 0 else 220),
        label = "verdictAlpha",
    )

    val color = when (result.outcome) {
        MatchEndResult.Outcome.WIN ->
            if (result.hollow) VoiidColor.textPrimary else accent
        MatchEndResult.Outcome.LOSE -> VoiidColor.textSecondary
        MatchEndResult.Outcome.TIE -> VoiidColor.textPrimary
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.scale(scale).alpha(alpha),
    ) {
        // A GLYPH AS WELL AS A WORD. Colour is never the only channel (§9.10) — the same rule
        // SeaBattleGrid follows for hit-vs-miss and LudoBoard follows for seats.
        Icon(
            when (result.outcome) {
                MatchEndResult.Outcome.WIN -> Icons.Filled.EmojiEvents
                MatchEndResult.Outcome.LOSE -> Icons.Filled.KeyboardArrowDown
                MatchEndResult.Outcome.TIE -> Icons.Filled.DragHandle
            },
            contentDescription = null,
            tint = color,
            modifier = Modifier.size(34.dp),
        )
        Spacer(Modifier.height(VoiidSpacing.sm))
        Text(
            result.title,
            fontSize = 34.sp,
            fontWeight = FontWeight.Black,
            color = color,
            textAlign = TextAlign.Center,
        )
        result.detail?.let {
            Text(
                it,
                fontSize = 14.sp,
                fontWeight = FontWeight.Medium,
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
                modifier = Modifier.padding(top = 4.dp),
            )
        }
    }
}

@Composable
private fun StatsPanel(
    result: MatchEndResult,
    accent: Color,
    phase: Int,
    scale: Float,
    reduceMotion: Boolean,
) {
    Column(
        Modifier
            .fillMaxWidth()
            .background(
                VoiidColor.surfaceCard.copy(alpha = 0.92f),
                RoundedCornerShape(16.dp),
            )
            .padding(horizontal = VoiidSpacing.md),
    ) {
        result.stats.forEachIndexed { index, stat ->
            val shown = phase >= 3
            val alpha by animateFloatAsState(
                targetValue = if (shown) 1f else 0f,
                animationSpec = tween(
                    durationMillis = if (reduceMotion) 0 else 220,
                    delayMillis = if (reduceMotion) 0 else (index * STAT_STAGGER * scale).toInt(),
                ),
                label = "stat$index",
            )
            Row(
                Modifier
                    .fillMaxWidth()
                    .alpha(alpha)
                    .padding(vertical = VoiidSpacing.sm),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(stat.label, fontSize = 13.sp, color = VoiidColor.textSecondary)
                Spacer(Modifier.weight(1f))
                Text(
                    stat.value,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.Bold,
                    color = if (stat.highlight) accent else VoiidColor.textPrimary,
                )
            }
            if (index < result.stats.size - 1) {
                HorizontalDivider(color = VoiidColor.textSecondary.copy(alpha = 0.15f))
            }
        }
    }
}

@Composable
private fun Actions(
    result: MatchEndResult,
    accent: Color,
    phase: Int,
    requesting: Boolean,
    failure: String?,
    onPlayAgain: (() -> Unit)?,
    onRematch: (() -> Unit)?,
    onExit: () -> Unit,
    onShare: () -> Unit,
) {
    val shown = phase >= 4
    val alpha by animateFloatAsState(
        targetValue = if (shown) 1f else 0f,
        animationSpec = tween(260),
        label = "actions",
    )

    Column(
        Modifier.fillMaxWidth().alpha(alpha),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
    ) {
        failure?.let {
            Text(
                it,
                fontSize = 13.sp,
                color = VoiidColor.textSecondary,
                textAlign = TextAlign.Center,
            )
        }

        Row(
            Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            when {
                onPlayAgain != null -> Pill("Play again", true, accent, Modifier.weight(1f)) {
                    if (shown) onPlayAgain()
                }
                onRematch != null -> Pill(
                    if (requesting) "…" else "Rematch", true, accent, Modifier.weight(1f),
                ) { if (shown) onRematch() }
            }
            Pill("Exit", false, accent, Modifier.weight(1f)) { if (shown) onExit() }
        }

        // SHARE, IN EVERY GAME — this app is a messenger and a result that can be dropped into
        // the chat it was arranged in is its one structural advantage over a standalone game
        // (CROSS_CUTTING.md §2). ON A LOSS THERE IS NO SHARE BUTTON: nobody shares a loss, and
        // offering it reads as a joke at the player's expense.
        if (result.shareText != null &&
            result.outcome != MatchEndResult.Outcome.LOSE &&
            !result.hollow
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier
                    .clickable { if (shown) onShare() }
                    .padding(VoiidSpacing.sm),
            ) {
                Icon(
                    Icons.Filled.Share,
                    contentDescription = null,
                    tint = VoiidColor.textSecondary,
                    modifier = Modifier.size(16.dp),
                )
                Spacer(Modifier.size(6.dp))
                Text(
                    "Challenge a friend",
                    fontSize = 14.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VoiidColor.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun Pill(
    text: String,
    filled: Boolean,
    accent: Color,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val haptics = rememberVoiidHaptics()
    Box(
        modifier
            .background(
                if (filled) accent else VoiidColor.fieldFill,
                RoundedCornerShape(50),
            )
            .clickable {
                haptics.tap()
                onClick()
            }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            fontSize = 15.sp,
            fontWeight = if (filled) FontWeight.Bold else FontWeight.SemiBold,
            color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
        )
    }
}

/**
 * 24 pieces of paper under gravity. Win only, never a defeat (§9.5).
 *
 * Hand-drawn rather than a particle system: this runs for 1.4 s once per match, and a Canvas
 * over 24 rects costs nothing next to pulling in a dependency.
 */
@Composable
private fun ConfettiBurst(color: Color) {
    val count = 24
    val life = 1.4f
    val gravity = 900f

    var t by remember { mutableStateOf(0f) }
    LaunchedEffect(Unit) {
        val start = System.nanoTime()
        while (t < life) {
            androidx.compose.runtime.withFrameNanos { now ->
                t = (now - start) / 1_000_000_000f
            }
        }
    }

    // Seeded per index so the burst is deterministic within a run and does not re-randomise on
    // every recomposition — a burst that reshuffles mid-flight reads as flicker.
    fun seed(i: Int, salt: Int): Float {
        val x = sin(i * 12.9898f + salt * 78.233f) * 43758.5453f
        return x - kotlin.math.floor(x)
    }

    Canvas(Modifier.fillMaxSize()) {
        if (t >= life) return@Canvas
        for (i in 0 until count) {
            val angle = (seed(i, 1) * 1.6f - 0.8f) - (Math.PI / 2).toFloat()
            val speed = 420f + seed(i, 2) * 380f
            val vx = kotlin.math.cos(angle) * speed
            val vy = sin(angle) * speed
            val x = size.width / 2 + vx * t
            val y = size.height * 0.42f + vy * t + 0.5f * gravity * t * t
            if (y > size.height + 20) continue

            val fade = (1f - t / life).coerceAtLeast(0f)
            val spin = t * (3f + seed(i, 3) * 6f)
            val w = 6f + seed(i, 4) * 5f
            val h = 9f + seed(i, 5) * 6f

            rotate(degrees = Math.toDegrees(spin.toDouble()).toFloat(), pivot = Offset(x, y)) {
                drawRect(
                    color = if (seed(i, 6) > 0.5f) color else color.copy(alpha = 0.62f),
                    topLeft = Offset(x - w / 2, y - h / 2),
                    size = Size(w, h),
                    alpha = fade,
                )
            }
        }
    }
}
