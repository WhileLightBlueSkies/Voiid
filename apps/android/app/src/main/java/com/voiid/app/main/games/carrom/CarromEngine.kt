package com.voiid.app.main.games.carrom

import androidx.compose.ui.graphics.Color
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/** Port of iOS `CarromTheme.swift`: geometry on the virtual 360 surface, and the palette. */
object CarromTheme {
    const val SURFACE = 360f
    const val FRAME = 24f
    const val TOTAL = SURFACE + FRAME * 2   // 408
    const val POCKET_RADIUS = 17.5f
    const val POCKET_INSET = 20f
    const val PIECE_RADIUS = 11.5f
    const val STRIKER_RADIUS = 16.5f
    const val PIECE_MASS = 1f
    const val STRIKER_MASS = 3.2f
    const val BASELINE_INSET = 52f
    const val BASELINE_WIDTH = 26f
    const val BASELINE_CIRCLE_RADIUS = 10.5f
    const val CENTER_OUTER = 36f
    const val CENTER_INNER = 14f

    val woodLight = Color(0xFFF4E7D3); val woodMid = Color(0xFFEAD8BC); val woodDark = Color(0xFFDFCAAB)
    val boardLine = Color(0xFF563721).copy(alpha = 0.85f)
    val boardLineLo = Color(0xFF563721).copy(alpha = 0.35f)
    val baseCircleRed = Color(0xFFC62828)
    val frameWoodLight = Color(0xFF361E13); val frameWoodDark = Color(0xFF140A06)
    val cushionRubber = Color(0xFF2E180E)
    val pocketWell = Color(0xFF09090B)
    val brassHighlight = Color(0xFFF5D77F); val brassBase = Color(0xFFC9A227); val brassShadow = Color(0xFF785E0E)
    val whiteMain = Color(0xFFFBF7EF); val whiteRing = Color(0xFFE2D3BA); val whiteCore = Color(0xFFC8B494)
    val blackMain = Color(0xFF221F1C); val blackRing = Color(0xFF3B3733); val blackCore = Color(0xFF151312)
    val queenMain = Color(0xFFC62828); val queenRing = Color(0xFFE53935); val queenStar = Color(0xFFFFD54F)
    val strikerBody = Color(0xFF0F172A); val strikerGlow = Color(0xFF00E5FF)
    val strikerRing = Color(0xFF38BDF8); val strikerCore = Color(0xFFE0F2FE)
    val aimLaser = Color(0xFF00F0FF)
    val aimBounceLaser = Color(0xFF38BDF8).copy(alpha = 0.65f)
    val aimGhostDisc = Color(0xFF00F0FF).copy(alpha = 0.3f)
}

enum class CarromTurn { PLAYER1, PLAYER2;
    val opposite get() = if (this == PLAYER1) PLAYER2 else PLAYER1
}

/** Port of iOS `CarromEngine`: the rosette, baseline geometry, and the raycasting bot. */
object CarromEngine {

    /** The 19-piece hexagonal close-packed rosette (queen, 9 white, 9 black) plus the striker. */
    fun generateStartingPieces(): MutableList<CarromPiece> {
        val pieces = mutableListOf<CarromPiece>()
        val c = Vec(CarromTheme.SURFACE / 2, CarromTheme.SURFACE / 2)
        val r = CarromTheme.PIECE_RADIUS
        var id = 1
        fun add(type: CarromPieceType, pos: Vec) {
            pieces += CarromPiece(id++, type, pos, radius = r, mass = CarromTheme.PIECE_MASS)
        }
        add(CarromPieceType.QUEEN, c)
        for (i in 0 until 6) {
            val a = (i * PI / 3).toFloat()
            add(if (i % 2 == 0) CarromPieceType.WHITE else CarromPieceType.BLACK, c + Vec.fromAngle(a, r * 2))
        }
        val edge = 2f * sqrt(3f) * r
        for (i in 0 until 6) {
            val a = (i * PI / 3).toFloat()
            add(if (i % 2 == 0) CarromPieceType.BLACK else CarromPieceType.WHITE, c + Vec.fromAngle(a, r * 4))
            add(if (i % 2 == 0) CarromPieceType.WHITE else CarromPieceType.BLACK, c + Vec.fromAngle(a + (PI / 6).toFloat(), edge))
        }
        pieces += CarromPiece(0, CarromPieceType.STRIKER, baselinePosition(CarromTurn.PLAYER1, 0.5f),
            radius = CarromTheme.STRIKER_RADIUS, mass = CarromTheme.STRIKER_MASS)
        return pieces
    }

    const val BASELINE_MIN_X = 74f
    const val BASELINE_MAX_X = CarromTheme.SURFACE - 74f

    fun baselineY(turn: CarromTurn) =
        if (turn == CarromTurn.PLAYER1) CarromTheme.SURFACE - CarromTheme.BASELINE_INSET else CarromTheme.BASELINE_INSET

    fun baselinePosition(turn: CarromTurn, normX: Float): Vec {
        val x = BASELINE_MIN_X + (BASELINE_MAX_X - BASELINE_MIN_X) * min(max(normX, 0f), 1f)
        return Vec(x, baselineY(turn))
    }

    fun isStrikerPlacementValid(pos: Vec, pieces: List<CarromPiece>): Boolean =
        pieces.none { it.type != CarromPieceType.STRIKER && !it.isPocketed &&
            pos.distance(it.position) < CarromTheme.STRIKER_RADIUS + it.radius + 1f }

    class BotShot(val baselineX: Float, val aimDirection: Vec, val power: Float)

    /** [difficulty] 1…3 sets the aim jitter, exactly as iOS (0.07 / 0.03 / 0.008 rad). */
    fun calculateBotShot(pieces: List<CarromPiece>, difficulty: Int = 2): BotShot {
        val pockets = listOf(
            Vec(CarromTheme.POCKET_INSET, CarromTheme.POCKET_INSET),
            Vec(CarromTheme.SURFACE - CarromTheme.POCKET_INSET, CarromTheme.POCKET_INSET),
            Vec(CarromTheme.SURFACE - CarromTheme.POCKET_INSET, CarromTheme.SURFACE - CarromTheme.POCKET_INSET),
            Vec(CarromTheme.POCKET_INSET, CarromTheme.SURFACE - CarromTheme.POCKET_INSET),
        )
        val targets = pieces.filter { (it.type == CarromPieceType.BLACK || it.type == CarromPieceType.QUEEN) && !it.isPocketed }
        if (targets.isEmpty()) return BotShot(0.5f, Vec(0f, 1f), 500f)

        var bestTarget: CarromPiece? = null
        var bestPocket = pockets[2]
        var bestX = 0.5f
        var bestScore = -1000f
        val xs = (1..9).map { it / 10f }
        for (t in targets) {
            val weight = if (t.type == CarromPieceType.QUEEN) 1.8f else 1f
            for (pocket in pockets) {
                val toPocket = (pocket - t.position).normalized()
                val ghost = t.position - toPocket * (CarromTheme.STRIKER_RADIUS + t.radius)
                for (nx in xs) {
                    val sp = baselinePosition(CarromTurn.PLAYER2, nx)
                    val shot = ghost - sp
                    if (shot.y < 20) continue   // the bot shoots DOWN the board
                    val score = shot.normalized().dot(toPocket) * 200f - shot.length * 0.4f -
                        t.position.distance(pocket) * 0.3f + weight * 60f
                    if (score > bestScore && isStrikerPlacementValid(sp, pieces)) {
                        bestScore = score; bestTarget = t; bestPocket = pocket; bestX = nx
                    }
                }
            }
        }
        val target = bestTarget ?: run {
            val freeX = (0..100).map { it / 100f }.firstOrNull {
                isStrikerPlacementValid(baselinePosition(CarromTurn.PLAYER2, it), pieces)
            } ?: 0.5f
            val sp = baselinePosition(CarromTurn.PLAYER2, freeX)
            return BotShot(freeX, (Vec(CarromTheme.SURFACE / 2, CarromTheme.SURFACE / 2) - sp).normalized(), 550f)
        }
        val sp = baselinePosition(CarromTurn.PLAYER2, bestX)
        val toPocket = (bestPocket - target.position).normalized()
        val ghost = target.position - toPocket * (CarromTheme.STRIKER_RADIUS + target.radius)
        var aim = (ghost - sp).normalized()
        val jitter = when (difficulty) { 1 -> 0.07f; 2 -> 0.03f; else -> 0.008f }
        val a = (Math.random().toFloat() * 2 - 1) * jitter
        aim = Vec(aim.x * cos(a) - aim.y * sin(a), aim.x * sin(a) + aim.y * cos(a))
        return BotShot(bestX, aim, 560f + Math.random().toFloat() * 160f)
    }

}
