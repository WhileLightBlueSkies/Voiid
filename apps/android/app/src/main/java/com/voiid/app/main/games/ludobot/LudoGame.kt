package com.voiid.app.main.games.ludobot

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlin.random.Random

/**
 * Turn flow and animation timing for Ludo.
 *
 * Port of iOS `Games/Ludo/LudoGame.swift`, including its timings — the two platforms should
 * feel like the same game, and the pauses are most of what that feeling is.
 */
class LudoGame : ViewModel() {

    data class TokenRef(val seat: Int, val token: Int)

    var state by mutableStateOf(LudoState())
        private set
    var pendingMoves by mutableStateOf<List<Move>>(emptyList())
        private set
    var die by mutableIntStateOf(0)
        private set
    var message by mutableStateOf("Red to roll.")
        private set
    var canRoll by mutableStateOf(false)
        private set
    var winner by mutableStateOf<Int?>(null)
        private set
    var banner by mutableStateOf<String?>(null)
        private set
    var rolling by mutableStateOf(false)
        private set

    var hopping by mutableStateOf<TokenRef?>(null)
        private set
    var popping by mutableStateOf<TokenRef?>(null)
        private set

    private var humanSeats = 1
    private var difficulty = "easy"
    var reduceMotion = false

    private var busy = false
    private var turnJob: Job? = null
    private var bannerJob: Job? = null

    /// Supplied by the screen, which owns the Context the haptics setting is read through.
    /// Null until then, so the ViewModel stays constructible without one.
    var haptics: LudoBotHaptics? = null

    fun start(humans: Int = 1, difficulty: String = "easy") {
        turnJob?.cancel()
        humanSeats = humans
        this.difficulty = difficulty
        state = LudoState()
        pendingMoves = emptyList()
        winner = null
        die = 0
        busy = false
        canRoll = true
        message = "${LudoEngine.seats[0].name} to roll."
    }

    fun restart() {
        turnJob?.cancel()
        start(humans = humanSeats, difficulty = difficulty)
    }

    fun isBot(seat: Int): Boolean = seat >= humanSeats

    fun isLive(seat: Int, token: Int): Boolean {
        if (seat != state.turn) return false
        if (pendingMoves.any { it.token == token }) return true
        if (pendingMoves.any { it.leavesYard } && state.positions[seat][token] == LudoPos.YARD) return true
        return false
    }

    fun roll() {
        if (busy || winner != null) return
        viewModelScope.launch { performRoll() }
    }

    private suspend fun performRoll() {
        busy = true
        canRoll = false
        pendingMoves = emptyList()

        val seat = state.turn
        val rolled = Random.nextInt(1, 7)
        die = rolled

        // Smooth 520ms continuous 3D tumble matching iOS SceneKit roll
        rolling = true
        delay(if (reduceMotion) 120 else 520)
        rolling = false
        haptics?.impact()

        state.consecutiveSixes = if (rolled == 6) state.consecutiveSixes + 1 else 0

        if (state.consecutiveSixes == 3) {
            show("Three sixes")
            message = "${name(seat)} rolled a third six — turn forfeited."
            state.consecutiveSixes = 0
            delay(900)
            endTurn(again = false)
            return
        }

        val moves = LudoEngine.legalMoves(state, seat, rolled)

        if (moves.isEmpty()) {
            message = "${name(seat)} rolled $rolled — no legal move."
            delay(850)
            endTurn(again = rolled == 6)
            return
        }

        if (moves.size == 1) {
            message = "${name(seat)} rolled $rolled."
            play(moves[0], seat, rolled)
            return
        }

        if (isBot(seat)) {
            message = "${name(seat)} rolled $rolled…"
            delay(520)
            val choice = LudoEngine.botChoice(state, seat, moves, difficulty)
            play(choice, seat, rolled)
            return
        }

        pendingMoves = moves
        message = "You rolled $rolled. Tap a glowing token."
        busy = false
    }

    fun tap(seat: Int, token: Int) {
        if (busy || seat != state.turn || winner != null) return
        val move = pendingMoves.firstOrNull { it.token == token }
            ?: (if (state.positions[seat][token] == LudoPos.YARD) pendingMoves.firstOrNull { it.leavesYard } else null)
            ?: return

        val rolled = die
        pendingMoves = emptyList()
        busy = true
        viewModelScope.launch { play(move, seat, rolled) }
    }

    private suspend fun play(move: Move, seat: Int, rolled: Int) {
        busy = true
        canRoll = false

        val step = if (reduceMotion) 10L else 150L

        if (move.leavesYard) {
            state = state.copyState().also { it.positions[seat][move.token] = 0 }
            haptics?.tick()
            delay(step * 2)
        } else {
            for (square in (move.from + 1)..move.to) {
                hopping = TokenRef(seat, move.token)
                state = state.copyState().also { it.positions[seat][move.token] = square }
                haptics?.tick()
                delay(step / 2)
                hopping = null
                delay(step / 2)
            }
        }

        var captured = false
        val hits = LudoEngine.captures(state, seat, move.to)
        if (hits.isNotEmpty()) {
            captured = true
            show("Captured")
            haptics?.thud()
            popping = TokenRef(seat, move.token)
            state = state.copyState().also { s ->
                for ((hitSeat, hitToken) in hits) s.positions[hitSeat][hitToken] = LudoPos.YARD
            }
            delay(520)
            popping = null
        }

        var home = false
        if (state.positions[seat][move.token] == LudoPos.GOAL) {
            home = true
            show("Home")
            haptics?.success()
            popping = TokenRef(seat, move.token)
            delay(420)
            popping = null
        }

        if (state.hasWon(seat)) return declareWin(seat)

        endTurn(LudoEngine.earnsAnotherRoll(rolled, captured, home))
    }

    private fun endTurn(again: Boolean) {
        busy = false
        pendingMoves = emptyList()

        if (!again) {
            state = state.copyState().also {
                it.turn = (state.turn + 1) % 4
                it.consecutiveSixes = 0
            }
        }

        val seat = state.turn
        if (isBot(seat)) {
            message = "${name(seat)} is thinking…"
            canRoll = false
            turnJob?.cancel()
            turnJob = viewModelScope.launch {
                delay(if (reduceMotion) 120 else 620)
                performRoll()
            }
        } else {
            canRoll = true
            message = if (again) "${name(seat)} again — roll." else "${name(seat)} to roll."
        }
    }

    fun stop() {
        turnJob?.cancel()
        turnJob = null
        busy = true
        canRoll = false
    }

    private fun declareWin(seat: Int) {
        busy = true
        canRoll = false
        winner = seat
        show("${LudoEngine.seats[seat].name} wins")
        message = "${name(seat)} brought all four tokens home."
    }

    private fun name(seat: Int): String = LudoEngine.seats[seat].name

    private fun show(text: String) {
        banner = text
        bannerJob?.cancel()
        bannerJob = viewModelScope.launch {
            delay(1150)
            if (banner == text) banner = null
        }
    }
}
