package com.voiid.app.main.games

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The hop chain (docs/games/future/LUDO.md §9).
 *
 * THE HOP IS THE MOST IMPORTANT ANIMATION IN THE GAME AND IT MUST NOT BE OPTIMISED AWAY.
 *
 * A token that slides or teleports to its destination discards the one piece of information the
 * movement carries: HOW FAR. Hopping square by square shows the count, which is what makes a 6
 * feel different from a 2 — and in a 4-player game, where you spend three quarters of your time
 * watching, it is what makes other people's turns worth watching at all.
 *
 * WHY THIS IS A DRIVER RATHER THAN AN ANIMATION SPEC. `animateFloatAsState` animates a value from
 * A to B; it has no notion of "visit these seven squares in order". So this walks the server's
 * own path and republishes an intermediate position per step, and the board animates between
 * consecutive steps as it already does.
 *
 * Mirrors iOS `LudoHop.swift`. Keep the timings identical.
 */
class LudoHop(private val scope: CoroutineScope) {
    /** Position overrides while a hop is in flight, keyed "seat-token". */
    var overrides by mutableStateOf<Map<String, Int>>(emptyMap())
        private set

    private var job: Job? = null

    companion object {
        /** ~110 ms per square. Fast enough not to be a wait, slow enough to be countable. */
        const val PER_SQUARE_MS = 110L

        /**
         * TOTAL TRAVEL IS CAPPED AT 900 ms. Six squares is ~660 ms, so this only bites on a long
         * home-column run. Watching is good; waiting is not.
         */
        const val MAX_TOTAL_MS = 900L

        fun key(seat: Int, token: Int) = "$seat-$token"

        /**
         * The squares a move crosses, excluding the origin and including the destination.
         *
         * A mirror of `backend/games/src/engine/ludo/board.ts`, used only to decide what to DRAW
         * — the destination itself always comes from the server.
         */
        fun path(from: Int, die: Int, seat: Int, to: Int): List<Int> {
            if (Ludo.inYard(from)) return listOf(to)
            val squares = mutableListOf<Int>()
            for (step in 1..maxOf(die, 1)) {
                val at = destination(from, step, seat) ?: break
                squares.add(at)
            }
            // Trust the server's destination over the mirror's: if the two ever disagree, the
            // token must still finish where the rules say it did.
            if (squares.lastOrNull() != to) squares.add(to)
            return squares
        }

        private fun destination(pos: Int, die: Int, seat: Int): Int? {
            if (Ludo.isHome(pos)) return null
            if (Ludo.inYard(pos)) return if (die == 6) Ludo.entrySquare(seat) else null
            if (Ludo.inColumn(pos)) {
                val step = pos - Ludo.COLUMN_BASE + die
                if (step == Ludo.COLUMN) return Ludo.HOME
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
    }

    /**
     * Animate one move across every square it crosses.
     *
     * [reduceMotion] collapses the chain to nothing. Note what §9 asks for there: the reduced
     * version must STILL COMMUNICATE DISTANCE, so the caller shows a readout instead — this
     * simply does not run.
     */
    fun play(
        seat: Int,
        token: Int,
        from: Int,
        to: Int,
        die: Int,
        reduceMotion: Boolean,
        onStep: () -> Unit,
        onFinish: () -> Unit,
    ) {
        job?.cancel()
        val squares = path(from, die, seat, to)
        // A yard entry crosses nothing and a single-square move is already its destination.
        if (reduceMotion || squares.size <= 1) {
            onFinish()
            return
        }
        val k = key(seat, token)
        val step = minOf(PER_SQUARE_MS, MAX_TOTAL_MS / squares.size)

        job = scope.launch {
            for (square in squares.dropLast(1)) {
                overrides = overrides + (k to square)
                onStep()
                delay(step)
            }
            // Clear rather than set the final square: the authoritative state already holds it,
            // and a leftover override would freeze the token if the next frame moved it.
            overrides = overrides - k
            onFinish()
        }
    }

    /** A tap skips to the end (§9) — a player who has seen the count needn't watch the rest. */
    fun skip() {
        job?.cancel()
        overrides = emptyMap()
    }
}
