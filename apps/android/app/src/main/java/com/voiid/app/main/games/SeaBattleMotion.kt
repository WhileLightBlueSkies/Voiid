package com.voiid.app.main.games

import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.launch

/**
 * Shell travel, sunk reveal and hit shake (docs/games/future/SEA_BATTLE.md §9).
 *
 * THE 380 ms SHELL TRAVEL IS LOAD-BEARING, NOT DECORATION.
 *
 * It is the window the server's answer arrives in, which is what lets the game feel instant
 * while being fully round-tripped. It is also the suspense: the beat between committing and
 * knowing is the emotional content of a turn.
 *
 * AND IT RUNS ITS FULL LENGTH EVEN WHEN THE FRAME ARRIVES IN 40 ms. The result is revealed at
 * the END of the travel either way, so the game feels identical on a fast and a slow
 * connection. That is a deliberate trade of 340 ms of latency for consistency — and it is the
 * opposite of the choice Snake makes, correctly, for a game where reaction time is the skill.
 *
 * Ported from iOS `SeaBattleMotion.swift`. Android had NONE of this: the board drew a static dot
 * on the firing cell and cleared it the instant the frame arrived, so a shot on a fast
 * connection was over in under 50 ms and the whole beat was missing. Keep [TRAVEL], [SINK_HOLD]
 * and [PER_CELL] identical to the Swift constants or the two platforms play at different speeds.
 */
class SeaBattleMotion(private val scope: CoroutineScope) {

    companion object {
        const val TRAVEL_MS = 380L
        /**
         * A sink is a hit PLUS a consequence, and the consequence has to land second or the two
         * read as one event — the same 120 ms trick as the crowd behind a cricket wicket.
         */
        const val SINK_HOLD_MS = 120L
        const val PER_CELL_MS = 60L
        private const val STEPS = 24
    }

    /** 0..1 through the shell's fall. The grid eases this itself. */
    var shellProgress by mutableStateOf(0f)
        private set

    /** Cells of the ship currently being revealed, added one at a time. */
    val sunkReveal = mutableStateListOf<Int>()

    /**
     * A 2 px nudge on a hit. Two pixels, hit only, and off under reduce-motion (§9) —
     * CROSS_CUTTING.md §13 records that Snake shipped hitstop and shake with no opt-out, and
     * this is the game deliberately not repeating it.
     */
    var shake by mutableStateOf(0f)
        private set

    private var shellJob: Job? = null
    private var revealJob: Job? = null
    private var shakeJob: Job? = null

    /** Run the shell. [onLand] fires at the end, which is when the result is revealed. */
    fun fire(reduceMotion: Boolean, onLand: () -> Unit) {
        shellJob?.cancel()
        if (reduceMotion) {
            shellProgress = 0f
            onLand()
            return
        }
        shellJob = scope.launch {
            for (i in 0..STEPS) {
                shellProgress = i.toFloat() / STEPS
                delay(TRAVEL_MS / STEPS)
                if (!isActive) return@launch
            }
            shellProgress = 0f
            onLand()
        }
    }

    /** Draw a sunk ship's outline in along its hull, after a hold. */
    fun revealSunk(cells: List<Int>, reduceMotion: Boolean) {
        revealJob?.cancel()
        if (reduceMotion || cells.isEmpty()) return
        revealJob = scope.launch {
            delay(SINK_HOLD_MS)
            for (cell in cells) {
                if (!isActive) return@launch
                sunkReveal.add(cell)
                delay(PER_CELL_MS)
            }
            delay(400)
            sunkReveal.clear()
        }
    }

    /** 2 px, hit only. */
    fun hitShake(reduceMotion: Boolean) {
        if (reduceMotion) return
        shakeJob?.cancel()
        shakeJob = scope.launch {
            for (offset in listOf(2f, -2f, 1.2f, -0.8f, 0f)) {
                shake = offset
                delay(40)
            }
            shake = 0f
        }
    }

    fun cancel() {
        shellJob?.cancel()
        revealJob?.cancel()
        shakeJob?.cancel()
        shellProgress = 0f
        sunkReveal.clear()
        shake = 0f
    }
}

/** Scoped to the composable that owns the board, so a shell can never outlive its screen. */
@Composable
fun rememberSeaBattleMotion(scope: CoroutineScope): SeaBattleMotion =
    remember(scope) { SeaBattleMotion(scope) }
