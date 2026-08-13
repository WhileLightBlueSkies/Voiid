package com.voiid.app

import com.voiid.app.main.games.Ludo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import kotlin.math.abs

/**
 * The board geometry table.
 *
 * WHY THIS TEST EXISTS. The table is duplicated across iOS and Android by design — LUDO.md §6.2
 * requires a shared lookup table rather than drawing code, precisely because two hand-drawn
 * layouts that disagree by a few points is the parity drift ANDROID_IOS_PARITY.md exists to
 * prevent. Duplication is only safe if the properties are pinned, and these are the properties:
 * a bad centre puts a token off the board, and the only way that surfaces at runtime is a player
 * reporting "my token vanished".
 *
 * The first hand-written version of this table had four corner steps that jumped two cells,
 * which would have walked tokens through walls. It was not visible by reading.
 */
class LudoBoardTest {

    @Test
    fun `the track is 52 distinct cells`() {
        assertEquals(52, Ludo.TRACK_CELLS.size)
        assertEquals(52, Ludo.TRACK_CELLS.toSet().size)
    }

    @Test
    fun `every track cell is on the 15x15 grid`() {
        assertTrue(Ludo.TRACK_CELLS.all {
            it.first in 0 until Ludo.GRID && it.second in 0 until Ludo.GRID
        })
    }

    /**
     * ENTRY SQUARES MUST MATCH THE SERVER'S `seat * 13`. If they do not, a player's tokens come
     * out of the wrong arm and their home column is somewhere else entirely — the board would
     * look plausible and play wrongly.
     */
    @Test
    fun `entry squares land on four distinct arm mouths`() {
        val entries = (0 until Ludo.MAX_SEATS).map { Ludo.TRACK_CELLS[Ludo.entrySquare(it)] }
        assertEquals(4, entries.toSet().size)
        assertEquals(0, Ludo.entrySquare(0))
        assertEquals(13, Ludo.entrySquare(1))
        assertEquals(26, Ludo.entrySquare(2))
        assertEquals(39, Ludo.entrySquare(3))
    }

    /**
     * 48 orthogonal steps and 4 diagonal, and the diagonals are INHERENT rather than a defect:
     * the orthogonal perimeter of this cross is 56, so a 52-cell ring has to cut the four arm
     * corners. Pinned as exact counts so an edit that breaks the ring shows up here rather than
     * as a token sliding across the board.
     */
    @Test
    fun `the ring is closed with exactly four corner cuts`() {
        var orthogonal = 0
        var diagonal = 0
        for (i in 0 until 52) {
            val a = Ludo.TRACK_CELLS[i]
            val b = Ludo.TRACK_CELLS[(i + 1) % 52]
            when (abs(a.first - b.first) + abs(a.second - b.second)) {
                1 -> orthogonal++
                2 -> diagonal++
                else -> throw AssertionError("jump between $i and ${(i + 1) % 52}: $a -> $b")
            }
        }
        assertEquals(48, orthogonal)
        assertEquals(4, diagonal)
    }

    @Test
    fun `home columns are five cells and never overlap the track`() {
        assertEquals(4, Ludo.COLUMN_CELLS.size)
        assertTrue(Ludo.COLUMN_CELLS.all { it.size == Ludo.COLUMN })
        val columns = Ludo.COLUMN_CELLS.flatten()
        assertEquals(20, columns.toSet().size)
        assertTrue(columns.none { it in Ludo.TRACK_CELLS })
    }

    @Test
    fun `the eight safe squares are the entries and the plus-eights`() {
        assertEquals(setOf(0, 8, 13, 21, 26, 34, 39, 47), Ludo.SAFE_SQUARES)
        assertTrue((0 until Ludo.MAX_SEATS).all { Ludo.isSafe(Ludo.entrySquare(it)) })
        assertTrue(!Ludo.isSafe(5))
        // A home-column position is not "safe" in the track sense — it is private, which is a
        // different rule, and conflating them would let isSafe() gate a capture check wrongly.
        assertTrue(!Ludo.isSafe(Ludo.COLUMN_BASE))
    }

    /**
     * EVERY POSITION A TOKEN CAN HOLD MAPS ON-BOARD. 4 seats x 4 tokens x 59 positions — the
     * yard, home, all 52 track squares and all 5 column steps.
     */
    @Test
    fun `every possible token placement is inside the board`() {
        val positions = buildList {
            add(Ludo.YARD)
            add(Ludo.HOME)
            addAll(0 until Ludo.TRACK)
            addAll((0 until Ludo.COLUMN).map { Ludo.COLUMN_BASE + it })
        }
        for (seat in 0 until Ludo.MAX_SEATS) {
            for (token in 0 until 4) {
                for (p in positions) {
                    val (x, y) = Ludo.squareCentre(p, seat, token)
                    assertTrue("seat=$seat token=$token pos=$p -> ($x,$y)",
                        x > 0f && x < 1f && y > 0f && y < 1f)
                }
            }
        }
    }

    /** Four tokens in a yard need four distinct slots, or they stack invisibly in the pocket. */
    @Test
    fun `yard slots are distinct per token`() {
        for (seat in 0 until Ludo.MAX_SEATS) {
            val slots = (0 until 4).map { Ludo.squareCentre(Ludo.YARD, seat, it) }
            assertEquals(4, slots.toSet().size)
        }
    }

    /** The centre is where every finished token sits, whichever seat owns it. */
    @Test
    fun `home is the centre for every seat`() {
        val centres = (0 until Ludo.MAX_SEATS).map { Ludo.squareCentre(Ludo.HOME, it) }
        assertEquals(1, centres.toSet().size)
    }
}
