package com.voiid.app

import com.voiid.app.main.games.SeaBattle
import com.voiid.app.main.games.SeaBattleFailure
import com.voiid.app.main.games.SeaBattleRules
import com.voiid.app.main.games.SeaBattleShip
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The client's fleet rules against the server's.
 *
 * WHY THIS TEST EXISTS. There are three implementations of one rule set — TypeScript in
 * `backend/games/src/engine/seabattle/fleet.ts`, Swift in `SeaBattleBoard.swift`, Kotlin here —
 * and only the first is authoritative. The other two exist so placement can show a ship red
 * before the player drops it. A client that accepts a fleet the server rejects produces a Ready
 * button that silently does nothing, with no error surfaced anywhere; a client that rejects one
 * the server would accept blocks a legal placement for no stated reason.
 *
 * The case table below is the same one `seabattle.test.ts` asserts, verdict for verdict. When a
 * rule changes, all three change together or this fails.
 *
 * The row-wrap case is the one worth keeping honest: packed cells 9 and 10 are consecutive
 * integers on different rows, so a naive `next == prev + 1` contiguity check accepts a Destroyer
 * that runs off column J and reappears at column A.
 */
class SeaBattleRulesTest {

    /**
     * One ship per row from column 0. The longest ship is 5, so a fleet built this way never
     * touches columns 5–9 — which is what makes those columns guaranteed water elsewhere.
     */
    private fun rowFleet(startRow: Int): List<SeaBattleShip> =
        SeaBattle.FLEET_SPEC.mapIndexed { type, len ->
            SeaBattleShip(type, (0 until len).map { SeaBattle.packed(it, startRow + type) })
        }

    private fun mutate(
        index: Int,
        block: (SeaBattleShip) -> SeaBattleShip,
    ): List<SeaBattleShip> =
        rowFleet(0).toMutableList().also { it[index] = block(it[index]) }

    @Test
    fun `a legal fleet validates`() {
        assertNull(SeaBattleRules.validate(rowFleet(0)))
    }

    @Test
    fun `wrong ship count is rejected`() {
        assertEquals(SeaBattleFailure.WRONG_SHIP_COUNT,
            SeaBattleRules.validate(rowFleet(0).take(4)))
        assertEquals(SeaBattleFailure.WRONG_SHIP_COUNT,
            SeaBattleRules.validate(rowFleet(0) + rowFleet(0)[0]))
    }

    @Test
    fun `two ships of the same type are rejected`() {
        assertEquals(SeaBattleFailure.DUPLICATE_TYPE,
            SeaBattleRules.validate(mutate(1) { it.copy(type = 0) }))
    }

    @Test
    fun `an unknown ship type is rejected`() {
        assertEquals(SeaBattleFailure.UNKNOWN_TYPE,
            SeaBattleRules.validate(mutate(0) { it.copy(type = 9) }))
    }

    /** Nothing is trusted about ship identity: length is recomputed from the ship's own cells. */
    @Test
    fun `a Carrier claiming two cells is rejected`() {
        assertEquals(SeaBattleFailure.WRONG_LENGTH,
            SeaBattleRules.validate(mutate(0) { it.copy(cells = it.cells.take(2)) }))
    }

    @Test
    fun `cells outside the board are rejected`() {
        assertEquals(SeaBattleFailure.OFF_BOARD,
            SeaBattleRules.validate(mutate(0) { it.copy(cells = listOf(95, 96, 97, 98, 199)) }))
        assertEquals(SeaBattleFailure.OFF_BOARD,
            SeaBattleRules.validate(mutate(4) { it.copy(cells = listOf(-1, 0)) }))
    }

    /**
     * There is no separate diagonal rule — a diagonal ship is in neither one row nor one column,
     * so the contiguity check is what rejects it.
     */
    @Test
    fun `a diagonal ship is rejected`() {
        assertEquals(SeaBattleFailure.NOT_CONTIGUOUS, SeaBattleRules.validate(
            mutate(4) { it.copy(cells = listOf(SeaBattle.packed(0, 8), SeaBattle.packed(1, 9))) }))
    }

    @Test
    fun `a ship with a gap is rejected`() {
        assertEquals(SeaBattleFailure.NOT_CONTIGUOUS, SeaBattleRules.validate(
            mutate(4) { it.copy(cells = listOf(SeaBattle.packed(0, 8), SeaBattle.packed(2, 8))) }))
    }

    /**
     * Placed on rows 8/9, away from the rest of the fleet on purpose: at cells 9,10 it would
     * collide with the Cruiser on row 1, so OVERLAP is reported first and the test would pass
     * for the wrong reason without ever exercising the wrap check.
     */
    @Test
    fun `a ship wrapping from column J to column A is rejected`() {
        assertEquals(SeaBattleFailure.NOT_CONTIGUOUS, SeaBattleRules.validate(
            mutate(4) { it.copy(cells = listOf(SeaBattle.packed(9, 8), SeaBattle.packed(0, 9))) }))
    }

    @Test
    fun `overlapping ships are rejected`() {
        assertEquals(SeaBattleFailure.OVERLAP, SeaBattleRules.validate(
            mutate(4) { it.copy(cells = listOf(SeaBattle.packed(0, 0), SeaBattle.packed(1, 0))) }))
        // A ship doubling back over itself is the same failure, caught by the same set.
        assertEquals(SeaBattleFailure.OVERLAP,
            SeaBattleRules.validate(mutate(4) { it.copy(cells = listOf(50, 50)) }))
    }

    /** Ships MAY touch, including at corners — deliberately against the Russian rules (§2.2). */
    @Test
    fun `adjacent ships are legal`() {
        val touching = listOf(
            SeaBattleShip(0, listOf(0, 1, 2, 3, 4)),
            SeaBattleShip(1, listOf(5, 6, 7, 8)),      // adjacent to the Carrier
            SeaBattleShip(2, listOf(10, 11, 12)),      // directly below it
            SeaBattleShip(3, listOf(13, 14, 15)),
            SeaBattleShip(4, listOf(16, 17)),
        )
        assertNull(SeaBattleRules.validate(touching))
    }

    /**
     * Random is mandatory and the default path (§2.2), so it must never produce a fleet the
     * server would reject — a player whose one tap yields an illegal board has no recourse.
     */
    @Test
    fun `random fleets are always legal`() {
        repeat(500) {
            assertNull(SeaBattleRules.validate(SeaBattleRules.randomFleet()))
        }
    }

    /** A ship dragged past the edge slides back on-board rather than vanishing under the finger. */
    @Test
    fun `run clamps to the board`() {
        val cells = SeaBattleRules.run(SeaBattle.packed(8, 0), length = 5, horizontal = true)
        assertEquals(5, cells.size)
        assertTrue(cells.all { it in 0 until SeaBattle.CELLS })
        assertTrue(SeaBattleRules.isContiguousLine(cells))
    }

    @Test
    fun `coordinates pack and label correctly`() {
        assertEquals(0, SeaBattle.packed(0, 0))
        assertEquals(99, SeaBattle.packed(9, 9))
        assertEquals("A1", SeaBattle.coordLabel(0))
        assertEquals("J10", SeaBattle.coordLabel(99))
        // D7 — the coordinate the doc uses for the FIRE button, and the one a player types into
        // the chat. Column D is index 3, row 7 is index 6.
        assertEquals("D7", SeaBattle.coordLabel(SeaBattle.packed(3, 6)))
    }
}
