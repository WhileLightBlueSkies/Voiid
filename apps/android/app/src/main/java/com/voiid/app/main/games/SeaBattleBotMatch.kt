package com.voiid.app.main.games

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.voiid.app.net.GamesEngine

/**
 * The local match state machine for a Sea Battle practice game — the offline counterpart to
 * GamesEngine's server-fed state.
 *
 * IT PRODUCES THE SAME SHAPE THE RENDERER CONSUMES. The board draws from a [SeaBattleState], so
 * this builds one rather than exposing a different model: one board component draws both a bot
 * game and an online game, and if this had its own shape every screen would grow a branch and
 * the two would drift.
 *
 * THE RULES ARE THE CLIENT MIRROR ([SeaBattleRules]), not a third copy. Hit resolution here is
 * trivial — is this cell in a ship — and everything a player could argue about (placement
 * legality) goes through the same `validate` the online game uses.
 *
 * WHY A CLASS WITH COMPOSE STATE rather than the loose `remember { mutableStateOf(...) }` set
 * the Tic Tac Toe and RPS practice screens use: those games hold three or four values, this one
 * holds two fleets, four parallel per-seat arrays and a turn clock. Threading that through a
 * composable as a dozen separate `var`s is how the two seats' arrays end up updated out of step.
 * `state` is a single `mutableStateOf`, so every rebuild is atomic and the screen can never
 * observe half a turn.
 *
 * Ported from iOS `SeaBattleBotMatch.swift`.
 */
private typealias SeaBattleState = GamesEngine.SeaBattleState

class SeaBattleBotMatch(
    level: BotDifficulty = BotDifficulty.MODERATE,
    skill: Float? = null,
    private val scores: BotScoreStore? = null,
) {
    companion object {
        const val HUMAN_SEAT = 0
        const val BOT_SEAT = 1

        private fun emptyState(): SeaBattleState = SeaBattleState(
            players = listOf("you", "bot"),
            phase = "placing",
            turn = null,
            turnUserId = null,
            shots = listOf(emptyList(), emptyList()),
            results = listOf(emptyList(), emptyList()),
            sunk = listOf(emptyList(), emptyList()),
            sunkCells = listOf(emptyList(), emptyList()),
            placed = listOf(false, false),
            fleetSpec = SeaBattle.FLEET_SPEC,
            deadlineAt = null,
            finished = false,
            winnerUserId = null,
            endedBy = null,
            lastShot = null,
            lastResult = null,
            seat = HUMAN_SEAT,
            myFleet = emptyList(),
            revealedFleets = null,
        )
    }

    /** The state the renderer draws, built to look exactly like a server frame. */
    var state by mutableStateOf(emptyState())
        private set

    /** True while the bot is "thinking" — the board is locked so a fast tapper cannot fire twice. */
    var botThinking by mutableStateOf(false)
        private set

    var paused by mutableStateOf(false)

    var level: BotDifficulty = level
        private set
    var skill: Float = skill ?: level.skill
        private set

    private var humanFleet: List<SeaBattleShip> = emptyList()
    private var botFleet: List<SeaBattleShip> = emptyList()
    private var bot = SeaBattleBot((skill ?: level.skill).toDouble())

    /** Guards against double-counting a result if the screen recomposes after the game ends. */
    private var recorded = false

    fun configure(level: BotDifficulty, skill: Float) {
        this.level = level
        this.skill = skill
        this.bot = SeaBattleBot(skill.toDouble())
    }

    val canFire: Boolean
        get() = !state.finished && !botThinking && !paused &&
            state.phase == "firing" && state.turn == HUMAN_SEAT

    // ---- lifecycle -----------------------------------------------------------------------

    fun restart() {
        humanFleet = emptyList()
        botFleet = emptyList()
        botThinking = false
        paused = false
        recorded = false
        state = emptyState()
    }

    /**
     * Commit the human's fleet and open firing.
     *
     * THE BOT PLACES HERE AND NEVER AGAIN (§11.2). It commits a fleet at match start and lives
     * with it — materialising ships away from incoming fire would be undetectable cheating.
     */
    fun place(fleet: List<SeaBattleShip>) {
        if (SeaBattleRules.validate(fleet) != null) return
        humanFleet = fleet
        botFleet = bot.placeFleet()

        // The human always fires first in practice. Fixed rather than drawn, because a practice
        // match is restartable at zero cost and losing the first shot to a coin flip is friction
        // with nothing behind it.
        state = state.copy(
            phase = "firing",
            turn = HUMAN_SEAT,
            turnUserId = "you",
            shots = listOf(emptyList(), emptyList()),
            results = listOf(emptyList(), emptyList()),
            sunk = listOf(emptyList(), emptyList()),
            sunkCells = listOf(emptyList(), emptyList()),
            placed = listOf(true, true),
            lastShot = null,
            lastResult = null,
            myFleet = fleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, 0) },
            revealedFleets = null,
        )
    }

    // ---- firing --------------------------------------------------------------------------

    /**
     * Fire at [cell]. Returns the bot's thinking delay in ms if it is now the bot's turn, or
     * null if the shot was rejected or the match just ended.
     *
     * THE CALLER OWNS THE DELAY, not this class: a coroutine started here would outlive the
     * screen that owns it, and a bot shot landing after the player left the match is exactly
     * the class of bug `GameAudio.stopAll`'s generation counter exists to prevent. The screen
     * has a `LaunchedEffect` scoped to its own lifecycle; it does the waiting and calls
     * [botTurn].
     */
    fun fire(cell: Int): Long? {
        if (!canFire) return null
        if (cell < 0 || cell >= SeaBattle.CELLS) return null
        if (cell in state.shots[HUMAN_SEAT]) return null

        apply(cell, HUMAN_SEAT)
        if (state.finished) return null

        botThinking = true
        return SeaBattleBot.thinkingDelayMs()
    }

    /** The bot picks and fires. Called by the screen once the thinking delay has elapsed. */
    fun botTurn() {
        if (paused || state.finished) {
            botThinking = false
            return
        }
        val mine = BOT_SEAT
        val target = bot.chooseShot(
            shots = state.shots[mine],
            results = state.results[mine],
            // The outlines of the HUMAN's sunk ships — public information, the same the human
            // sees on their own board.
            sunkCells = state.sunkCells[HUMAN_SEAT],
            fleetSpec = state.fleetSpec,
        )
        apply(target, mine)
        botThinking = false
    }

    /** Resolve one shot against the target's fleet and rebuild the state. */
    private fun apply(cell: Int, seat: Int) {
        val targetSeat = 1 - seat
        val fleet = (if (targetSeat == HUMAN_SEAT) humanFleet else botFleet).toMutableList()

        val shots = state.shots.map { it.toMutableList() }
        val results = state.results.map { it.toMutableList() }
        val sunk = state.sunk.map { it.toMutableList() }
        val sunkCells = state.sunkCells.map { it.toMutableList() }

        var result = 0
        val idx = fleet.indexOfFirst { cell in it.cells }
        if (idx >= 0) {
            val hitShip = fleet[idx].copy(hits = fleet[idx].hits + 1)
            fleet[idx] = hitShip
            if (hitShip.isSunk) {
                result = 2
                sunk[targetSeat].add(hitShip.type)
                // Once a ship is sunk its squares are public, exactly as the server promotes
                // them out of the secret at the moment of sinking.
                sunkCells[targetSeat].addAll(hitShip.cells)
            } else {
                result = 1
            }
        }

        if (targetSeat == HUMAN_SEAT) humanFleet = fleet else botFleet = fleet

        shots[seat].add(cell)
        results[seat].add(result)

        val hitTotal = fleet.sumOf { it.hits }
        val won = hitTotal >= SeaBattle.FLEET_CELLS
        // ONE SHOT PER TURN — a hit does not grant another, matching the engine (§2.3).
        val nextTurn = if (won) null else targetSeat

        if (won && !recorded) {
            scores?.add(level, if (seat == HUMAN_SEAT) 1 else -1)
            recorded = true
        }

        state = state.copy(
            phase = if (won) "done" else "firing",
            turn = nextTurn,
            turnUserId = nextTurn?.let { state.players[it] },
            shots = shots,
            results = results,
            sunk = sunk,
            sunkCells = sunkCells,
            placed = listOf(true, true),
            finished = won,
            winnerUserId = if (won) state.players[seat] else null,
            endedBy = if (won) "win" else null,
            lastShot = cell,
            lastResult = result,
            myFleet = humanFleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) },
            // Both fleets go out only once the match is over, exactly as the terminal server
            // frame does — the bot's ships are never in a frame before that.
            revealedFleets = if (won) listOf(
                humanFleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) },
                botFleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) },
            ) else null,
        )
    }

    /** Forfeit. A give-up that costs nothing is just a reset button with extra steps. */
    fun giveUp() {
        if (state.finished) return
        if (!recorded) {
            scores?.add(level, -1)
            recorded = true
        }
        botThinking = false
        state = state.copy(
            phase = "done",
            turn = null,
            turnUserId = null,
            deadlineAt = null,
            finished = true,
            winnerUserId = state.players[BOT_SEAT],
            endedBy = "resign",
            revealedFleets = listOf(
                humanFleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) },
                botFleet.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) },
            ),
        )
    }
}
