package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.LudoMotion
import com.voiid.app.ui.theme.LudoPalette
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch
import kotlin.math.sin

/**
 * Ordered animation timeline (§15, §18.2). Beats are queued NAMED SEQUENCE STEPS instead of
 * independent onChange animations, so the required §12.3 order never overlaps: border sweep
 * finishes before die relocation; hops finish before capture return; the next border sweep
 * begins only after the last mandatory beat of the previous action.
 *
 * GAME STATE NEVER WAITS FOR A CLIENT ANIMATION (§1): authoritative frames replace state
 * immediately; this coordinator schedules only what is SEEN. `cancelAll()` on reconnect means
 * no stale motion ever replays (§9).
 */
class LudoPresentationCoordinator {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    /** One frame of border-sweep visual state for the board renderer. */
    data class BorderSweep(
        val fromSeat: Int,
        val toSeat: Int,
        val fromColor: Color,
        val toColor: Color,
        val progress: Float,
    )

    /** One frame of die-roll visual state (§14.3 choreography). */
    data class RollVisual(
        val rotationX: Float,
        val rotationY: Float,
        val liftPx: Float,
        val scaleX: Float,
        val scaleY: Float,
    )

    private val _sweep = MutableStateFlow<BorderSweep?>(null)
    val sweep: StateFlow<BorderSweep?> = _sweep.asStateFlow()

    private val _roll = MutableStateFlow<RollVisual?>(null)
    val roll: StateFlow<RollVisual?> = _roll.asStateFlow()

    /** The single display pawn mid-hop; authoritative state is untouched. */
    private val _hopCenter = MutableStateFlow<Pair<Int, Offset>?>(null)   // pawnIndex → center
    val hopCenter: StateFlow<Pair<Int, Offset>?> = _hopCenter.asStateFlow()

    private var beatJob: Job? = null
    private val beatQueue = ArrayDeque<suspend () -> Unit>()
    private var reduceMotion = false
    private var matchId: String? = null
    /** Resolved once per theme from the composable layer; animations never read composition. */
    private var colors: com.voiid.app.ui.theme.LudoThemeColors =
        com.voiid.app.ui.theme.LudoThemeColors.light()

    fun setColors(c: com.voiid.app.ui.theme.LudoThemeColors) { colors = c }

    fun setMatchId(id: String?) {
        if (matchId != id) {
            cancelAll()
            matchId = id
        }
    }

    fun setReduceMotion(enabled: Boolean) { reduceMotion = enabled }

    fun cancelAll() {
        beatJob?.cancel()
        beatJob = null
        beatQueue.clear()
        _sweep.value = null
        _roll.value = null
        _hopCenter.value = null
    }

    // ── Public beat entry points (called by the screen on new actions) ────────────────────

    /**
     * §12.3 serialized turn-change sequence: sweep 0–360 ms → die relocate + pip cross-fade
     * 360–480 ms → rest. A six that keeps the same seat performs NO sweep or relocation.
     */
    fun enqueueTurnChange(fromSeat: Int, toSeat: Int) {
        if (fromSeat == toSeat) return   // extra roll from a six keeps everything steady
        runSerialized {
            animateBorder(fromSeat, toSeat)
            delay(LudoMotion.DIE_RELOCATE_MS.toLong())
            delay(LudoMotion.PIP_CROSS_FADE_MS.toLong())
        }
    }

    /** §14.3 roll choreography. Turn counts derive from hash(matchId+rollId), never the value. */
    fun enqueueRoll(rollId: String, value: Int) {
        runSerialized { animateRoll(rollId, value) }
    }

    /** §15 hops + optional capture return, serialized after any running beats. */
    fun enqueueMove(pathSize: Int, captured: LudoMovePayload.CapturedPawn?, onFrame: (Int) -> Unit) {
        runSerialized {
            for (i in 0 until pathSize) {
                onFrame(i)
                delay(LudoRules.HOP_MS.toLong())
                if (i < pathSize - 1) delay(LudoRules.HOP_STAGGER_MS.toLong() - LudoRules.HOP_MS.toLong() + LudoRules.HOP_MS.toLong())
                else Unit
            }
            if (captured != null) {
                delay(70)                                   // hold after the mover lands
                delay(LudoMotion.CAPTURE_SCALE_MS.toLong()) // victim squash
                delay(LudoMotion.CAPTURE_RETURN_MS.toLong())// quadratic arc home
            }
        }
    }

    private fun runSerialized(block: suspend () -> Unit) {
        if (reduceMotion) return                // authoritative final state is already rendered
        beatQueue.addLast(block)
        if (beatJob?.isActive == true) return   // retain, but never overlap, the §12.3 sequence
        beatJob = scope.launch {
            while (beatQueue.isNotEmpty()) {
                beatQueue.removeFirst().invoke()
            }
        }
    }

    // ── Animations ────────────────────────────────────────────────────────────────────────

    /** 360 ms clockwise trim, cubic-bezier(.22,0,0,1); rounded cap traveling, butt at end. */
    private suspend fun animateBorder(fromSeat: Int, toSeat: Int) {
        val easing = LudoMotion.BorderSweepEasing
        val startAt = System.nanoTime()
        while (true) {
            val t = (System.nanoTime() - startAt) / 1_000_000f / LudoMotion.BORDER_SWEEP_MS
            if (t >= 1f) break
            _sweep.value = BorderSweep(
                fromSeat, toSeat,
                colors.hue(fromSeat), colors.hue(toSeat),
                easing.transform(t.coerceIn(0f, 1f)),
            )
            delay(16)
        }
        _sweep.value = null
    }

    private suspend fun animateRoll(rollId: String, value: Int) {
        val seed = stableHash("${matchId ?: ""}:$rollId")
        val xTurns = 2.5f + ((seed ushr 8) % 1000) / 1000f       // 2.5–3.5 turns
        val yTurns = 2f + ((seed ushr 20) % 1000) / 1000f        // 2–3 turns
        val zDir = if (seed and 1L == 0L) -1f else 1f
        val (restX, restY) = LudoDie.restAngles(value)

        fun frame(rx: Float, ry: Float, lift: Float, sx: Float, sy: Float) {
            _roll.value = RollVisual(rx, ry, lift, sx, sy)
        }

        // Anticipation 0–120 ms.
        tween(120, cubicEasing(0.32f, 0f, 0.67f, 0f)) { t ->
            frame(zDir * -8f * t, 10f * t, 3f * t, 1f + 0.05f * t, 1f - 0.09f * t)
        }
        if (reduceMotion) return
        // Tumble/release 120–760 ms.
        val posEasing = cubicEasing(0.12f, 0.68f, 0.22f, 1f)
        val angEasing = cubicEasing(0.20f, 0f, 0.38f, 1f)
        tween(640, posEasing) { t ->
            frame(
                restX + xTurns * 360f * zDir * (1f - angEasing.transform(t)),
                restY + yTurns * 360f * (1f - angEasing.transform(t)),
                3f - 21f * sin((Math.PI * t).toFloat()),
                1f + 0.05f * (1f - t),
                1f - 0.09f * (1f - t),
            )
        }
        // Impact 760–820 ms: squash; shadow collapse reads through lift=0.
        tween(60, cubicEasing(0.33f, 1f, 0.68f, 1f)) { t ->
            frame(restX, restY, 0f, 1f + 0.08f * t, 1f - 0.10f * t)
        }
        // Rebound/settle 820–940 ms back to the exact result orientation.
        tween(120, cubicEasing(0.20f, 0f, 0f, 1f)) { t ->
            frame(restX, restY, 0f, 1f + 0.08f * (1f - t), 1f - 0.10f * (1f - t))
        }
        _roll.value = null
    }

    private suspend fun tween(durationMs: Long, easing: LudoMotion.CubicEasing, frame: (Float) -> Unit) {
        val startAt = System.nanoTime()
        while (true) {
            val t = (System.nanoTime() - startAt) / 1_000_000f / durationMs
            if (t >= 1f) { frame(1f); break }
            frame(easing.transform(t))
            delay(16)   // ~60 fps only while an explicit beat runs; idle consumes no loop (§19)
        }
    }

    private fun cubicEasing(x1: Float, y1: Float, x2: Float, y2: Float): LudoMotion.CubicEasing =
        LudoMotion.CubicEasing(x1, y1, x2, y2)

    internal fun stableHash(input: String): Long {
        var h = 1125899906842597L
        for (c in input) h = 31 * h + c.code
        return h
    }

    /** Hops start every 92 ms so adjacent arcs overlap by 28 ms — a six lasts 580 ms, not 720. */
    object HopTimeline {
        fun starts(cells: Int): List<Long> =
            (0 until cells).map { i -> i * LudoRules.HOP_STAGGER_MS.toLong() }

        fun totalMs(cells: Int): Long =
            if (cells == 0) 0 else LudoRules.HOP_MS.toLong() + starts(cells).last()
    }
}
