package com.voiid.app.main.games.carrom

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.voiid.app.ui.components.VoiidHaptics
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

sealed interface CarromPhase {
    data object Placement : CarromPhase
    data object Aiming : CarromPhase
    data object InMotion : CarromPhase
    data object Evaluating : CarromPhase
    data class GameOver(val winner: String) : CarromPhase
}

enum class CarromBannerType { INFO, SUCCESS, FOUL }
data class CarromBanner(val text: String, val type: CarromBannerType)

sealed interface QueenState {
    data object OnBoard : QueenState
    data class PendingCover(val by: CarromTurn) : QueenState
    data class Covered(val by: CarromTurn) : QueenState
}

/**
 * Port of iOS `CarromGame.swift`: the turn lifecycle, queen cover rules, fouls and the bot.
 * State is Compose state so the board and HUD recompose; the physics world is plain objects
 * stepped by [stepFrame] and read through [tick].
 */
class CarromGame(private val haptics: VoiidHaptics?, private val botDifficulty: Int = 2) {
    val isBot = true
    var turn by mutableStateOf(CarromTurn.PLAYER1); private set
    var phase by mutableStateOf<CarromPhase>(CarromPhase.Placement); private set
    var player1Score by mutableIntStateOf(0); private set
    var player2Score by mutableIntStateOf(0); private set
    var baselineNormX by mutableStateOf(0.5f); private set
    var aimDirection by mutableStateOf(Vec(0f, -1f)); private set
    var shotPower by mutableStateOf(0f); private set
    var isPlacementValid by mutableStateOf(true); private set
    var aimResult by mutableStateOf<CarromAimResult?>(null); private set
    var banner by mutableStateOf<CarromBanner?>(null); private set
    var queenState by mutableStateOf<QueenState>(QueenState.OnBoard); private set
    /** Bumped every simulated frame so the board redraws while pieces move. */
    var tick by mutableIntStateOf(0); private set

    val targetScore = 9
    val world = CarromPhysicsWorld()
    private val pocketedThisTurn = mutableListOf<CarromPiece>()
    private var lastFrameNanos = 0L
    private var pending: Pair<Float, () -> Unit>? = null

    val canControl: Boolean
        get() = (phase == CarromPhase.Placement || phase == CarromPhase.Aiming) && (turn == CarromTurn.PLAYER1 || !isBot)

    init {
        world.onPieceCollision = { impulse -> if (impulse > 18) haptics?.rigid() else haptics?.soft() }
        world.onCushionBounce = { haptics?.soft() }
        world.onPiecePocketed = { piece, _ ->
            pocketedThisTurn += piece
            when (piece.type) {
                CarromPieceType.STRIKER -> haptics?.error()
                CarromPieceType.QUEEN -> haptics?.boundary()
                else -> haptics?.success()
            }
        }
        resetBoard()
    }

    private fun schedule(delay: Float, action: () -> Unit) { pending = delay to action }
    fun pauseClock() { lastFrameNanos = 0L }

    fun resetBoard() {
        pending = null; lastFrameNanos = 0L
        shotPower = 0.70f
        aimResult = null
        world.pieces = CarromEngine.generateStartingPieces()
        player1Score = 0; player2Score = 0
        turn = CarromTurn.PLAYER1
        queenState = QueenState.OnBoard
        baselineNormX = 0.5f
        phase = CarromPhase.Placement
        pocketedThisTurn.clear()
        banner = null
        updateStrikerPlacement()
        tick++
    }

    private val striker get() = world.pieces.first { it.type == CarromPieceType.STRIKER }

    fun updateBaselineSlider(value: Float) {
        if (!canControl) return
        baselineNormX = min(max(value, 0f), 1f)
        updateStrikerPlacement()
    }

    fun nudgeBaseline(delta: Float) {
        if (!canControl) return
        baselineNormX = min(max(baselineNormX + delta, 0f), 1f)
        updateStrikerPlacement()
        haptics?.soft()
    }

    private fun updateStrikerPlacement() {
        val pos = CarromEngine.baselinePosition(turn, baselineNormX)
        striker.apply { position = pos; velocity = Vec.ZERO; isPocketed = false; sinkProgress = 0f; pocketIndex = null }
        isPlacementValid = CarromEngine.isStrikerPlacementValid(pos, world.pieces)
        aimDirection = Vec(0f, if (turn == CarromTurn.PLAYER1) -1f else 1f)
        updateAimGuide()
        tick++
    }

    fun setAimPoint(target: Vec) {
        if (!canControl || !isPlacementValid) return
        val to = target - striker.position
        if (to.length > 12f) {
            val forward = if (turn == CarromTurn.PLAYER1) to.y < 10f else to.y > -10f
            if (forward) {
                aimDirection = to.normalized()
                if (shotPower <= 0.05f) shotPower = 0.70f
                phase = CarromPhase.Aiming
                updateAimGuide()
            }
        }
    }

    fun changeShotPower(power: Float) {
        if (!canControl) return
        shotPower = min(max(power, 0.1f), 1f)
        if (phase == CarromPhase.Placement && isPlacementValid) { phase = CarromPhase.Aiming; updateAimGuide() }
    }

    /** Slingshot: dragging behind the striker aims the opposite way; distance is power. */
    fun updateAimGesture(dragX: Float, dragY: Float) {
        if (!canControl || !isPlacementValid) return
        phase = CarromPhase.Aiming
        val pull = Vec(-dragX, -dragY)
        if (pull.length > 10f) {
            aimDirection = pull.normalized()
            shotPower = min(max(pull.length / 110f, 0.20f), 1f)
        }
        updateAimGuide()
    }

    private fun launch(power: Float) {
        val speed = 420f + power * (1050f - 420f)
        striker.velocity = aimDirection.normalized() * speed
        lastFrameNanos = 0L
        haptics?.boundary()
        phase = CarromPhase.InMotion
        pocketedThisTurn.clear()
        aimResult = null
        shotPower = 0f
    }

    fun fireStrike() {
        if (!canControl || !isPlacementValid) return
        launch(if (shotPower > 0.08f) shotPower else 0.70f)
    }

    fun releaseStrike() {
        if (phase != CarromPhase.Aiming && phase != CarromPhase.Placement) return
        if (!isPlacementValid || shotPower <= 0.12f) {
            phase = CarromPhase.Placement; shotPower = 0f; aimResult = null; return
        }
        launch(shotPower)
    }

    fun updateAimGuide() { aimResult = world.predictAim(striker.position, aimDirection) }

    /** Advance one frame. Called from the screen's frame loop with the frame time. */
    fun stepFrame(frameNanos: Long) {
        val dt = if (lastFrameNanos == 0L) 1f / 60f
        else ((frameNanos - lastFrameNanos) / 1e9f).coerceIn(0.001f, 0.033f)
        lastFrameNanos = frameNanos
        pending?.let { (delay, action) ->
            if (delay <= dt) { pending = null; action() } else pending = (delay - dt) to action
        }
        if (phase != CarromPhase.InMotion) return
        world.step(dt)
        tick++
        if (world.isSettled) { lastFrameNanos = 0L; evaluateTurn() }
    }

    private fun evaluateTurn() {
        phase = CarromPhase.Evaluating
        val own = if (turn == CarromTurn.PLAYER1) CarromPieceType.WHITE else CarromPieceType.BLACK
        val strikerPocketed = pocketedThisTurn.any { it.type == CarromPieceType.STRIKER }
        val ownMen = pocketedThisTurn.filter { it.type == own }
        val hasQueen = pocketedThisTurn.any { it.type == CarromPieceType.QUEEN }
        var extraTurn = ownMen.isNotEmpty() && !strikerPocketed

        val qs = queenState
        if (hasQueen && !strikerPocketed) {
            if (ownMen.isNotEmpty()) {
                queenState = QueenState.Covered(turn)
                banner = CarromBanner("Queen covered!", CarromBannerType.SUCCESS)
            } else {
                queenState = QueenState.PendingCover(turn)
                banner = CarromBanner("Pocket your colour next to cover the queen", CarromBannerType.INFO)
            }
            extraTurn = true
        } else if (qs is QueenState.PendingCover && qs.by == turn) {
            if (!strikerPocketed && ownMen.isNotEmpty()) {
                queenState = QueenState.Covered(turn)
                banner = CarromBanner("Queen covered!", CarromBannerType.SUCCESS)
            } else {
                returnQueenToCenter()
                queenState = QueenState.OnBoard
                banner = CarromBanner("Cover missed — queen returned", CarromBannerType.FOUL)
            }
        }

        if (strikerPocketed) {
            if (hasQueen) { returnQueenToCenter(); queenState = QueenState.OnBoard }
            world.pieces.indexOfFirst { it.type == own && it.isPocketed }.takeIf { it >= 0 }?.let { returnPieceToCenter(it) }
            extraTurn = false
            banner = CarromBanner("Striker foul — turn lost", CarromBannerType.FOUL)
        }

        // The queen must be covered before either colour can clear the board.
        if (queenState !is QueenState.Covered) {
            for (colour in listOf(CarromPieceType.WHITE, CarromPieceType.BLACK)) {
                val last = world.pieces.indexOfFirst { it.type == colour && it.isPocketed }
                if (world.pieces.none { it.type == colour && !it.isPocketed } && last >= 0) {
                    returnPieceToCenter(last)
                    if (colour == own) extraTurn = false
                    banner = CarromBanner("Cover the queen before your last piece", CarromBannerType.INFO)
                }
            }
        }

        player1Score = world.pieces.count { it.type == CarromPieceType.WHITE && it.isPocketed }
        player2Score = world.pieces.count { it.type == CarromPieceType.BLACK && it.isPocketed }
        val opponentCleared = if (turn == CarromTurn.PLAYER1) player2Score == targetScore else player1Score == targetScore
        val ownCleared = if (turn == CarromTurn.PLAYER1) player1Score == targetScore else player2Score == targetScore
        if (opponentCleared || ownCleared) {
            val winner = if (opponentCleared) turn.opposite else turn
            phase = CarromPhase.GameOver(if (winner == CarromTurn.PLAYER1) "You" else "Carrom Bot")
            tick++
            return
        }

        schedule(1.2f) {
            if (!extraTurn) turn = turn.opposite
            phase = CarromPhase.Placement
            banner = null
            shotPower = 0.70f
            updateStrikerPlacement()
            if (turn == CarromTurn.PLAYER2 && isBot) scheduleBotShot()
        }
        tick++
    }

    private fun returnQueenToCenter() {
        world.pieces.indexOfFirst { it.type == CarromPieceType.QUEEN }.takeIf { it >= 0 }?.let { returnPieceToCenter(it) }
    }

    private fun returnPieceToCenter(idx: Int) {
        val c = Vec(CarromTheme.SURFACE / 2, CarromTheme.SURFACE / 2)
        val others = world.pieces.filter { !it.isPocketed && it.id != world.pieces[idx].id }
        var pos = c
        search@ for (ring in 0..12) for (slot in 0 until 36) {
            val a = (slot * PI / 18).toFloat()
            val cand = c + Vec(cos(a), sin(a)) * (ring * 12f)
            if (others.all { cand.distance(it.position) >= it.radius + CarromTheme.PIECE_RADIUS + 1f }) { pos = cand; break@search }
        }
        world.pieces[idx].apply { position = pos; velocity = Vec.ZERO; isPocketed = false; sinkProgress = 0f; pocketIndex = null }
    }

    private fun scheduleBotShot() {
        if (phase != CarromPhase.Placement || turn != CarromTurn.PLAYER2) return
        schedule(0.8f) {
            if (turn != CarromTurn.PLAYER2 || phase != CarromPhase.Placement) return@schedule
            val shot = CarromEngine.calculateBotShot(world.pieces, botDifficulty)
            baselineNormX = shot.baselineX
            updateStrikerPlacement()
            if (!isPlacementValid) {
                banner = CarromBanner("Baseline blocked — turn passed", CarromBannerType.INFO)
                turn = CarromTurn.PLAYER1
                updateStrikerPlacement()
                return@schedule
            }
            schedule(0.6f) {
                if (turn != CarromTurn.PLAYER2) return@schedule
                aimDirection = shot.aimDirection
                shotPower = min(max((shot.power - 420f) / 630f, 0.20f), 1f)
                phase = CarromPhase.Aiming
                updateAimGuide()
                schedule(0.5f) { if (turn == CarromTurn.PLAYER2) releaseStrike() }
            }
        }
    }
}
