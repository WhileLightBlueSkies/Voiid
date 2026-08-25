package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size

/**
 * Wire/state model for Ludo schema v3 (LUDO_GAME_SPEC.md §5–§6).
 *
 * Type names mirror backend/games/src/engine/ludo/types.ts normatively; only casing differs.
 * THE CLIENT IS A RENDERER: it never decides legality — the frame's `turn.legalTokenIds`
 * is the one answer to "what can this seat do", computed by the server for validation,
 * auto-play, timeout and this highlight alike.
 *
 * NOTE WHAT IS ABSENT AND WHY: no raw user ids anywhere. `seatId` is match-scoped and opaque;
 * `displayName` is a per-recipient projection decided server-side (§11.2) — a client must
 * never receive an unauthorized real username and then hide it locally.
 */
object LudoRules {
    const val SCHEMA_VERSION = 3
    const val RULES_VERSION = "ludo-classic-2"

    const val TRACK_COUNT = 52
    const val HOME_LANE_COUNT = 5
    const val TOKENS_PER_SEAT = 4

    const val YARD = -1
    const val HOME_LANE_BASE = 100
    const val FINISHED = 200

    /** §13: the per-decision server clock. The ring is display-only; a paused app extends nothing. */
    const val TURN_WINDOW_MS = 30_000
    /** §12.3 serialized sequence: border sweep 0–360 ms, die relocation + pips 360–480 ms. */
    const val TRANSITION_MS = 480
    /** Die roll choreography total (§14.3). */
    const val ROLL_TOTAL_MS = 940

    /** Hop chain duration for n cells, and the universal presentation windows (§15). */
    fun hopMs(n: Int): Int = if (n == 0) 0 else HOP_MS + HOP_STAGGER_MS * (n - 1)
    const val HOP_MS = 120
    /** Whole capture retrace, split across however many cells the pawn has to walk back. */
    const val CAPTURE_RETURN_TOTAL_MS = 520
    const val CAPTURE_LEG_MIN_MS = 26
    const val HOP_STAGGER_MS = 92
    const val CAPTURE_EXTRA_MS = 480
    const val FINISH_EXTRA_MS = 550

    val SAFE_INDICES = setOf(0, 8, 13, 21, 26, 34, 39, 47)
    val ENTRY_INDICES = listOf(0, 13, 26, 39)
    val STAR_INDICES = listOf(8, 21, 34, 47)
    val APPROACH_INDICES = listOf(50, 11, 24, 37)

    fun startIndex(seat: Int): Int = START_INDICES[seat]
    val START_INDICES = intArrayOf(0, 13, 26, 39)

    fun progressOf(absolute: Int, seat: Int): Int =
        (absolute - startIndex(seat) + TRACK_COUNT) % TRACK_COUNT
}

enum class LudoSeatColor(val seat: Int) { RED(0), GREEN(1), YELLOW(2), BLUE(3) }

data class LudoTurnView(
    val seat: Int,
    val serial: Int,
    val phase: String,
    val opensAt: Long,
    val deadlineAt: Long?,
    val botActionAt: Long?,
    val sixStreak: Int,
    val rollId: String?,
    val value: Int?,
    val legalMoves: List<LudoLegalMove>,
    val automated: Boolean,
) { val legalTokenIds: List<Int> get() = legalMoves.map { it.tokenId } }

data class LudoLegalMove(
    val tokenId: Int, val to: Int, val path: List<Int>,
    val capture: Capture?, val isSafe: Boolean,
) { data class Capture(val seat: Int, val tokenId: Int) }

data class LudoMovePayload(
    val tokenId: Int,
    val from: Int,
    val to: Int,
    val path: List<Int>,
    val captured: CapturedPawn?,
) {
    data class CapturedPawn(val seat: Int, val tokenId: Int, val from: Int, val to: Int)
}

data class LudoAction(
    val id: String,
    val type: String,
    val committedAt: Long,
    val presentationEndsAt: Long,
    val actorSeat: Int,
    val fromSeat: Int? = null,
    val roll: RollInfo? = null,
    val move: LudoMovePayload? = null,
) {
    data class RollInfo(val rollId: String, val value: Int, val auto: Boolean)
}

data class LudoSeatView(
    val seat: Int,
    val seatId: String,
    val color: LudoSeatColor,
    val displayName: String,
    val controller: String,
    val botMarker: String?,
    val botDifficulty: String?,
    val participation: String,
    val connection: String,
    val timeoutStreak: Int,
    val finishedPawns: Int,
    val captures: Int,
) {
    val isBot: Boolean get() = controller == "bot"
    val isWaiting: Boolean get() = participation == "waiting"
}

/**
 * One authoritative frame. Applied in ONE transaction (never clearing tokens into an empty
 * intermediate model) so a refresh cannot flash an empty board (§9).
 */
data class LudoGameState(
    val schemaVersion: Int,
    val rulesVersion: String,
    val mode: String,
    val status: String,
    val serverNow: Long,
    val viewerSeat: Int?,
    val viewerRole: String,
    val seats: List<LudoSeatView>,
    val tokensPerSeat: Int,
    val tokens: List<List<Int>>,
    val turn: LudoTurnView?,
    val lastAction: LudoAction?,
    val winnerSeat: Int?,
    val endReason: String?,
    val seedCommitment: String?,
    val seq: Int,
) {
    val isFinished: Boolean get() = status == "finished" || status == "abandoned"
    val isActive: Boolean get() = status == "active"
    fun seatByColor(seat: Int): LudoSeatView? = seats.firstOrNull { it.seat == seat }
    fun tokenAt(seat: Int, pawn: Int): Int = tokens.getOrNull(seat)?.getOrNull(pawn) ?: LudoRules.YARD
}
