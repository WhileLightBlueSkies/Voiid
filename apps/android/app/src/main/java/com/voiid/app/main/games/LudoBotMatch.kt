package com.voiid.app.main.games

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.voiid.app.net.GamesEngine
import kotlin.random.Random

/**
 * The local match state machine for a Ludo practice game — the offline counterpart to
 * GamesEngine's server-fed state.
 *
 * IT PRODUCES THE SAME SHAPE THE RENDERER CONSUMES. `LudoBoardView` draws from a [LudoState], so
 * this builds one: the board, the die and the strips are the same code in practice and online,
 * and a fix to one is a fix to both.
 *
 * THIS IS THE ONE PLACE THE LUDO RULES ARE DUPLICATED, and it is worth being blunt about that.
 * The engine in `backend/games/src/engine/ludo/` is the authority for every online match; this is
 * a second implementation so practice can run with no server. They must agree, so the rules here
 * are written against that file line for line — the same entry-on-six, the same exact-roll home,
 * the same block semantics, the same three-sixes forfeit, the same composing extra turns. Where
 * the two ever disagree, the SERVER is right and this file is the bug.
 *
 * Ported from iOS `LudoBotMatch.swift`.
 */
private typealias LudoState = GamesEngine.LudoState

class LudoBotMatch(
    level: BotDifficulty = BotDifficulty.MODERATE,
    skill: Float? = null,
    seats: Int = 4,
    tokens: Int = 2,
    private val scores: BotScoreStore? = null,
) {
    companion object {
        const val HUMAN_SEAT = 0

        private fun freshState(seats: Int, tokens: Int): LudoState = LudoState(
            players = (0 until seats).map { if (it == HUMAN_SEAT) "you" else "bot$it" },
            tokensPerPlayer = tokens,
            tokens = (0 until seats).map { List(tokens) { Ludo.YARD } },
            turn = 0,
            turnUserId = "you",
            phase = "awaitingRoll",
            die = null,
            legal = emptyList(),
            sixStreak = 0,
            extraTurn = false,
            finishedOrder = emptyList(),
            deadlineAt = null,
            lastMove = null,
            finished = false,
            winnerUserId = null,
        )
    }

    /** Seats after the human are bots. Four seats is the doc's default shape for a group game. */
    private val seatCount: Int = seats.coerceIn(2, Ludo.MAX_SEATS)

    /**
     * 2 tokens at 3-4 players, 4 at two — the same default the engine clamps to, and the reason
     * is the same: no default configuration should run past ~20 minutes.
     */
    private val tokensPerPlayer: Int = tokens

    var state by mutableStateOf(freshState(seatCount, tokensPerPlayer))
        private set

    /** True while a bot seat is "thinking" — the die is locked so a fast tapper cannot roll for it. */
    var botThinking by mutableStateOf(false)
        private set

    var paused by mutableStateOf(false)

    var level: BotDifficulty = level
        private set
    var skill: Float = skill ?: level.skill
        private set

    private var bot = LudoBot((skill ?: level.skill).toDouble())
    private var recorded = false

    fun configure(level: BotDifficulty, skill: Float) {
        this.level = level
        this.skill = skill
        this.bot = LudoBot(skill.toDouble())
    }

    val canRoll: Boolean
        get() = !state.finished && !botThinking && !paused &&
            state.phase == "awaitingRoll" && state.turn == HUMAN_SEAT

    val canMove: Boolean
        get() = !state.finished && !botThinking && !paused &&
            state.phase == "awaitingMove" && state.turn == HUMAN_SEAT

    fun restart() {
        botThinking = false
        paused = false
        recorded = false
        state = freshState(seatCount, tokensPerPlayer)
    }

    // ---- the human's turn -------------------------------------------------------------------

    /** Returns true if a bot seat now owes a turn, so the screen can start its own delay loop. */
    fun roll(): Boolean {
        if (!canRoll) return false
        performRoll()
        // Zero legal moves auto-passes inside performRoll, which may hand the turn to a bot.
        return botsOwedTurn()
    }

    fun move(token: Int): Boolean {
        if (!canMove || token !in state.legal) return false
        performMove(token)
        return botsOwedTurn()
    }

    fun botsOwedTurn(): Boolean = !state.finished && state.turn != HUMAN_SEAT

    // ---- bot seats --------------------------------------------------------------------------

    /**
     * Advance ONE bot beat — a roll or a move. Returns true if another beat is owed.
     *
     * THE CALLER OWNS THE DELAY between beats, not this class, for the same reason
     * [SeaBattleBotMatch.fire] does: a coroutine started here would outlive the screen and a bot
     * move landing after the player has left is exactly the class of bug that produces. The
     * screen runs a `LaunchedEffect` loop scoped to its own lifecycle.
     */
    fun stepBot(): Boolean {
        botThinking = true
        if (state.finished || state.turn == HUMAN_SEAT || paused) {
            botThinking = false
            return false
        }
        when (state.phase) {
            "awaitingRoll" -> performRoll()
            "awaitingMove" -> {
                val pick = bot.chooseMove(
                    legal = state.legal,
                    tokens = state.tokens,
                    seat = state.turn,
                    die = state.die ?: 0,
                )
                performMove(pick)
            }
            else -> {
                botThinking = false
                return false
            }
        }
        val more = botsOwedTurn()
        if (!more) botThinking = false
        return more
    }

    // ---- rules ------------------------------------------------------------------------------
    //
    // Written against backend/games/src/engine/ludo/. Every rule below has a counterpart there.

    private fun performRoll() {
        val seat = state.turn
        // A UNIFORM DRAW, AT EVERY DIFFICULTY. The bot's skill never touches this line — see
        // LudoBot's header for why that is the most important property in the file.
        val die = Random.nextInt(1, 7)
        var sixStreak = state.sixStreak

        if (die == 6) {
            sixStreak += 1
            // Three consecutive sixes forfeits the turn AND the third six is not used.
            if (sixStreak >= 3) {
                state = passTurn(state.copy(die = null, legal = emptyList(), sixStreak = 0))
                return
            }
        } else {
            sixStreak = 0
        }

        val legal = legalMoves(seat, die, state.tokens)

        if (legal.isEmpty()) {
            // Zero legal moves passes automatically, in the same beat as the roll — a "you have
            // no moves, tap to continue" prompt is a tap that changes nothing.
            state = passTurn(state.copy(die = die, legal = emptyList(), sixStreak = sixStreak))
            return
        }

        state = state.copy(
            turn = seat,
            turnUserId = state.players[seat],
            phase = "awaitingMove",
            die = die,
            legal = legal,
            sixStreak = sixStreak,
            deadlineAt = null,
            finished = false,
            winnerUserId = null,
        )
    }

    private fun performMove(token: Int) {
        val seat = state.turn
        val die = state.die ?: return
        val tokens = state.tokens.map { it.toMutableList() }
        val from = tokens[seat][token]
        val to = destination(from, die, seat) ?: return

        tokens[seat][token] = to

        // Capture: exactly one opponent token on a non-safe track square goes home. Two or more
        // is a block, which was already excluded from the legal set — so multi-capture is
        // impossible by construction rather than by a check.
        var captured: List<Int>? = null
        if (Ludo.onTrack(to) && !Ludo.isSafe(to)) {
            for (other in tokens.indices) {
                if (other == seat) continue
                val idx = tokens[other].indexOf(to)
                if (idx >= 0) {
                    tokens[other][idx] = Ludo.YARD
                    captured = listOf(other, idx)
                    break
                }
            }
        }

        val last = GamesEngine.LudoState.LastMove(seat, token, from, to, captured)

        // A player finishes when all their tokens are home, and the MATCH ends on the first
        // finisher — not "play on for second place".
        if (tokens[seat].all { it == Ludo.HOME }) {
            if (!recorded) {
                scores?.add(level, if (seat == HUMAN_SEAT) 1 else -1)
                recorded = true
            }
            state = state.copy(
                tokens = tokens,
                turn = seat,
                turnUserId = null,
                phase = "done",
                die = null,
                legal = emptyList(),
                sixStreak = 0,
                extraTurn = false,
                finishedOrder = state.finishedOrder + seat,
                deadlineAt = null,
                lastMove = last,
                finished = true,
                winnerUserId = state.players[seat],
            )
            return
        }

        // EXTRA TURNS COMPOSE TO ONE, NOT TWO: the flag is boolean, not a counter, so capturing
        // with a six grants one extra turn rather than spiralling.
        val grantsExtra = die == 6 || captured != null || to == Ludo.HOME

        val base = state.copy(
            tokens = tokens,
            turn = seat,
            turnUserId = state.players[seat],
            phase = "awaitingRoll",
            die = null,
            legal = emptyList(),
            sixStreak = if (grantsExtra) state.sixStreak else 0,
            extraTurn = grantsExtra,
            deadlineAt = null,
            lastMove = last,
            finished = false,
            winnerUserId = null,
        )

        state = if (grantsExtra) base else passTurn(base)
    }

    /** Hand the turn to the next seat that has not already finished. */
    private fun passTurn(s: LudoState): LudoState {
        val n = s.players.size
        var next = s.turn
        for (i in 1..n) {
            val candidate = (s.turn + i) % n
            if (candidate !in s.finishedOrder) {
                next = candidate
                break
            }
        }
        return s.copy(
            turn = next,
            turnUserId = s.players[next],
            phase = "awaitingRoll",
            die = null,
            legal = emptyList(),
            sixStreak = 0,
            extraTurn = false,
            deadlineAt = null,
            finished = false,
            winnerUserId = null,
        )
    }

    // ---- movement, mirroring backend/games/src/engine/ludo/board.ts --------------------------

    fun legalMoves(seat: Int, die: Int, tokens: List<List<Int>>): List<Int> {
        val blocked = blockedSquares(seat, tokens)
        val legal = ArrayList<Int>()

        for (t in tokens[seat].indices) {
            val from = tokens[seat][t]
            val to = destination(from, die, seat) ?: continue

            // An opponent's block can neither be landed on NOR passed, so the whole path is
            // checked rather than just the destination.
            if (path(from, die, seat).any { it in blocked }) continue

            // A token may not land on a square holding two or more of its own colour.
            if (Ludo.onTrack(to)) {
                val own = tokens[seat].withIndex().count { it.index != t && it.value == to }
                if (own >= 2) continue
            }

            legal.add(t)
        }
        return legal
    }

    /**
     * Squares an opponent has blocked: two or more of one other colour.
     *
     * BLOCKS CANNOT FORM ON SAFE SQUARES. Tokens may stack there — they are already safe — but
     * such a stack does not block passage, which is what stops a permanent block on an entry
     * square locking a player out of the game entirely.
     */
    private fun blockedSquares(seat: Int, tokens: List<List<Int>>): Set<Int> {
        val blocked = HashSet<Int>()
        for (other in tokens.indices) {
            if (other == seat) continue
            val counts = HashMap<Int, Int>()
            for (p in tokens[other]) {
                if (Ludo.onTrack(p) && !Ludo.isSafe(p)) counts[p] = (counts[p] ?: 0) + 1
            }
            for ((square, n) in counts) if (n >= 2) blocked.add(square)
        }
        return blocked
    }

    fun destination(pos: Int, die: Int, seat: Int): Int? {
        if (Ludo.isHome(pos)) return null
        // A 6 is required to leave the yard, and it PLACES the token on the entry square — it
        // does not then move six more.
        if (Ludo.inYard(pos)) return if (die == 6) Ludo.entrySquare(seat) else null
        if (Ludo.inColumn(pos)) {
            val step = pos - Ludo.COLUMN_BASE + die
            if (step == Ludo.COLUMN) return Ludo.HOME
            // EXACT ROLL REQUIRED TO REACH HOME — overshooting is illegal, not clamped.
            if (step > Ludo.COLUMN) return null
            return Ludo.COLUMN_BASE + step
        }
        val travelled = (pos - Ludo.entrySquare(seat) + Ludo.TRACK) % Ludo.TRACK
        val next = travelled + die
        if (next == Ludo.TRACK + Ludo.COLUMN) return Ludo.HOME
        if (next > Ludo.TRACK + Ludo.COLUMN) return null
        if (next >= Ludo.TRACK) return Ludo.COLUMN_BASE + (next - Ludo.TRACK)
        return (Ludo.entrySquare(seat) + next) % Ludo.TRACK
    }

    /** The squares a token passes through, for the block check. */
    fun path(pos: Int, die: Int, seat: Int): List<Int> {
        if (Ludo.inYard(pos)) {
            return destination(pos, die, seat)?.let { listOf(it) } ?: emptyList()
        }
        val squares = ArrayList<Int>()
        for (step in 1..maxOf(die, 1)) {
            val at = destination(pos, step, seat) ?: return squares
            squares.add(at)
        }
        return squares
    }
}
