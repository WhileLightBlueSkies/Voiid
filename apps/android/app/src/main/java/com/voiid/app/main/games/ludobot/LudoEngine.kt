package com.voiid.app.main.games.ludobot

/**
 * Pure rules + board topology. Deterministic and unit-testable.
 *
 * Port of iOS `Games/Ludo/LudoEngine.swift`. The two must agree square for square: the
 * board art, the safe squares and the home-column entry are all derived from these
 * indices, so a divergence here is a divergence a player can see.
 */

object LudoPos {
    const val YARD = -1
    const val GOAL = 56
    const val COLUMN_START = 51
    const val RING_COUNT = 52
}

data class GridPoint(val x: Int, val y: Int)

data class Seat(
    val name: String,
    /** index into [LudoEngine.ring] */
    val start: Int,
    /** top-left cell of the 6x6 yard */
    val yardOrigin: GridPoint,
    /** five home-column cells, outermost first */
    val column: List<GridPoint>,
)

data class Move(val token: Int, val from: Int, val to: Int) {
    val leavesYard: Boolean get() = from == LudoPos.YARD
    val reachesHome: Boolean get() = to == LudoPos.GOAL
}

data class LudoState(
    /** positions[seat][token] */
    val positions: List<MutableList<Int>> =
        List(4) { MutableList(4) { LudoPos.YARD } },
    var turn: Int = 0,
    var consecutiveSixes: Int = 0,
) {
    fun homeCount(seat: Int): Int = positions[seat].count { it == LudoPos.GOAL }
    fun hasWon(seat: Int): Boolean = homeCount(seat) == 4

    fun copyState(): LudoState = LudoState(
        positions = positions.map { it.toMutableList() },
        turn = turn,
        consecutiveSixes = consecutiveSixes,
    )
}

object LudoEngine {

    /** The 52-square ring, clockwise, in 15x15 grid coordinates. */
    val ring: List<GridPoint> = listOf(
        GridPoint(1, 6), GridPoint(2, 6), GridPoint(3, 6), GridPoint(4, 6), GridPoint(5, 6),
        GridPoint(6, 5), GridPoint(6, 4), GridPoint(6, 3), GridPoint(6, 2), GridPoint(6, 1),
        GridPoint(6, 0),
        GridPoint(7, 0),
        GridPoint(8, 0), GridPoint(8, 1), GridPoint(8, 2), GridPoint(8, 3), GridPoint(8, 4),
        GridPoint(8, 5),
        GridPoint(9, 6), GridPoint(10, 6), GridPoint(11, 6), GridPoint(12, 6), GridPoint(13, 6),
        GridPoint(14, 6),
        GridPoint(14, 7),
        GridPoint(14, 8),
        GridPoint(13, 8), GridPoint(12, 8), GridPoint(11, 8), GridPoint(10, 8), GridPoint(9, 8),
        GridPoint(8, 9), GridPoint(8, 10), GridPoint(8, 11), GridPoint(8, 12), GridPoint(8, 13),
        GridPoint(8, 14),
        GridPoint(7, 14),
        GridPoint(6, 14), GridPoint(6, 13), GridPoint(6, 12), GridPoint(6, 11), GridPoint(6, 10),
        GridPoint(6, 9),
        GridPoint(5, 8), GridPoint(4, 8), GridPoint(3, 8), GridPoint(2, 8), GridPoint(1, 8),
        GridPoint(0, 8),
        GridPoint(0, 7),
        GridPoint(0, 6),
    )

    /**
     * Squares where a token cannot be captured: the four start squares and the four stars
     * sitting eight ahead of each.
     */
    val safeSquares: Set<Int> = setOf(0, 8, 13, 21, 26, 34, 39, 47)

    val seats: List<Seat> = listOf(
        Seat(
            "Red", 0, GridPoint(0, 0),
            listOf(GridPoint(1, 7), GridPoint(2, 7), GridPoint(3, 7), GridPoint(4, 7), GridPoint(5, 7)),
        ),
        Seat(
            "Green", 13, GridPoint(9, 0),
            listOf(GridPoint(7, 1), GridPoint(7, 2), GridPoint(7, 3), GridPoint(7, 4), GridPoint(7, 5)),
        ),
        Seat(
            "Amber", 26, GridPoint(9, 9),
            listOf(GridPoint(13, 7), GridPoint(12, 7), GridPoint(11, 7), GridPoint(10, 7), GridPoint(9, 7)),
        ),
        Seat(
            "Blue", 39, GridPoint(0, 9),
            listOf(GridPoint(7, 13), GridPoint(7, 12), GridPoint(7, 11), GridPoint(7, 10), GridPoint(7, 9)),
        ),
    )

    /** Where each token parks inside its yard, in cell units from the yard origin. */
    val yardSlots: List<Pair<Float, Float>> = listOf(
        2f to 2f, 4f to 2f,
        2f to 4f, 4f to 4f,
    )

    /** Converts a seat-relative ring position into an absolute ring index. */
    fun absoluteRing(seat: Int, rel: Int): Int = (seats[seat].start + rel) % LudoPos.RING_COUNT

    /** The centre of a token, in cell units (0..15 on both axes). */
    fun centre(seat: Int, token: Int, rel: Int): Pair<Float, Float> {
        if (rel == LudoPos.YARD) {
            val o = seats[seat].yardOrigin
            val (sx, sy) = yardSlots[token]
            return (o.x + sx) to (o.y + sy)
        }
        if (rel == LudoPos.GOAL) {
            val fan = listOf(
                -0.44f to -0.44f, 0.44f to -0.44f,
                -0.44f to 0.44f, 0.44f to 0.44f,
            )
            val (fx, fy) = fan[token]
            return (7.5f + fx) to (7.5f + fy)
        }
        if (rel >= LudoPos.COLUMN_START) {
            val p = seats[seat].column[rel - LudoPos.COLUMN_START]
            return (p.x + 0.5f) to (p.y + 0.5f)
        }
        val p = ring[absoluteRing(seat, rel)]
        return (p.x + 0.5f) to (p.y + 0.5f)
    }

    /** Every move this seat may legally make with this die. */
    fun legalMoves(state: LudoState, seat: Int, die: Int): List<Move> {
        val out = mutableListOf<Move>()
        var yardAdded = false
        for (token in 0 until 4) {
            val rel = state.positions[seat][token]
            if (rel == LudoPos.GOAL) continue

            if (rel == LudoPos.YARD) {
                if (die == 6 && !yardAdded) {
                    out.add(Move(token, LudoPos.YARD, 0))
                    yardAdded = true
                }
                continue
            }

            val dest = rel + die
            if (dest <= LudoPos.GOAL) out.add(Move(token, rel, dest))
        }
        return out
    }

    /** Opponent tokens sent back to the yard by landing on [dest]. */
    fun captures(state: LudoState, seat: Int, dest: Int): List<Pair<Int, Int>> {
        if (dest > 50) return emptyList()
        val square = absoluteRing(seat, dest)
        if (safeSquares.contains(square)) return emptyList()

        val hits = mutableListOf<Pair<Int, Int>>()
        for (other in 0 until 4) {
            if (other == seat) continue
            for (token in 0 until 4) {
                val rel = state.positions[other][token]
                if (rel < 0 || rel > 50) continue
                if (absoluteRing(other, rel) == square) hits.add(other to token)
            }
        }
        return hits
    }

    /** How many tokens share the square this one is on, and which of them it is. */
    fun stack(state: LudoState, seat: Int, token: Int): Pair<Int, Int> {
        val rel = state.positions[seat][token]
        if (rel < 0 || rel > 50) return 1 to 0
        val square = absoluteRing(seat, rel)

        var count = 0
        var index = 0
        for (s in 0 until 4) {
            for (t in 0 until 4) {
                val r = state.positions[s][t]
                if (r < 0 || r > 50) continue
                if (absoluteRing(s, r) == square) {
                    if (s == seat && t == token) index = count
                    count++
                }
            }
        }
        return count to index
    }

    fun earnsAnotherRoll(die: Int, captured: Boolean, reachedHome: Boolean): Boolean =
        die == 6 || captured || reachedHome

    fun botChoice(
        state: LudoState,
        seat: Int,
        moves: List<Move>,
        difficulty: String = "easy",
    ): Move {
        if (difficulty == "easy") {
            // Relaxed bot: gentle random moves, rarely aggressive.
            return moves.random()
        }
        fun score(m: Move): Double {
            var v = 0.0
            if (captures(state, seat, m.to).isNotEmpty()) v += if (difficulty == "hard") 160.0 else 100.0
            if (m.reachesHome) v += 80.0
            if (m.leavesYard) v += 45.0
            if (m.to > 50) v += 30.0
            if (m.to <= 50 && safeSquares.contains(absoluteRing(seat, m.to))) v += 18.0
            return v + m.to * 0.3
        }
        return moves.maxByOrNull { score(it) } ?: moves.first()
    }
}
