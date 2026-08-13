package com.voiid.app.main.games

import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.Canvas
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import kotlin.math.min
import kotlin.random.Random

/**
 * Board geometry, fleet rules and the grid renderer for Sea Battle
 * (docs/games/future/SEA_BATTLE.md §6, §8).
 *
 * THE RULES IN HERE ARE A MIRROR, NOT AN AUTHORITY. The server validates every fleet and
 * resolves every shot; this exists so the placement UI can show a ship red before the player
 * drops it, and so Random can produce something without a round trip. Anything it decides that
 * the server would decide differently is a bug in this file — the server is the referee
 * (GAMES.md §1) and the frame is always the truth.
 *
 * PORTED LITERALLY from iOS `SeaBattleBoard.swift`, constants included. SNAKE.md §2.4 records
 * two renderers that "were ported line-for-line including the bug" and warns that divergent
 * constants are how two builds of one game end up feeling different. The Swift and Kotlin
 * validators are checked against the server's TypeScript over the same case table.
 */
object SeaBattle {
    /** 10x10, columns A–J, rows 1–10. */
    const val SIZE = 10
    const val CELLS = SIZE * SIZE

    /**
     * Coordinates are ONE packed integer, never a string. "B10" and "B1" differ by a character
     * and a client that misparses that fires at the wrong square silently.
     */
    fun packed(x: Int, y: Int) = y * SIZE + x
    fun cx(c: Int) = c % SIZE
    fun cy(c: Int) = c / SIZE

    /**
     * The classic Milton Bradley set — 17 squares of 100. Index is the type id on the wire.
     *
     * The SERVER sends `fleetSpec` in every frame and the renderer prefers that; this is the
     * fallback for the placement screen, which runs before any frame has arrived.
     */
    val FLEET_SPEC = listOf(5, 4, 3, 3, 2)
    val SHIP_NAMES = listOf("Carrier", "Battleship", "Cruiser", "Submarine", "Destroyer")
    const val FLEET_CELLS = 17

    /** `A`…`J` — a player calling out "D7" in the chat has to read D7 off the screen. */
    fun columnLabel(x: Int): String = ('A' + x).toString()

    fun coordLabel(cell: Int): String = "${columnLabel(cx(cell))}${cy(cell) + 1}"
}

/** A ship being placed, or one the server told us about. */
data class SeaBattleShip(
    val type: Int,
    val cells: List<Int>,
    val hits: Int = 0,
) {
    val isSunk: Boolean get() = hits >= cells.size
    val name: String get() = SeaBattle.SHIP_NAMES.getOrElse(type) { "Ship" }
}

/** Why a fleet is illegal. Distinct reasons because the UI renders a different message for each. */
enum class SeaBattleFailure(val message: String) {
    WRONG_SHIP_COUNT("Place all five ships"),
    DUPLICATE_TYPE("Two ships of the same kind"),
    UNKNOWN_TYPE("Unknown ship"),
    WRONG_LENGTH("That ship is the wrong length"),
    OFF_BOARD("That ship is off the board"),
    NOT_CONTIGUOUS("Ships must be straight, along a row or a column"),
    OVERLAP("Ships cannot overlap"),
}

object SeaBattleRules {
    /**
     * Contiguous and collinear along one row or one column.
     *
     * THIS ONE CHECK IS WHAT ENFORCES "NO DIAGONALS" — a diagonal ship is by definition in
     * neither a single row nor a single column, so there is no separate diagonal rule.
     *
     * It also catches row wrap: packed cells 9 and 10 are consecutive integers on different
     * rows, so a Destroyer running off column J passes a naive `next == prev + 1` check.
     */
    fun isContiguousLine(cells: List<Int>): Boolean {
        if (cells.size < 2) return true
        val sameRow = cells.all { SeaBattle.cy(it) == SeaBattle.cy(cells[0]) }
        val sameCol = cells.all { SeaBattle.cx(it) == SeaBattle.cx(cells[0]) }
        if (!sameRow && !sameCol) return false
        val step = if (sameRow) 1 else SeaBattle.SIZE
        val sorted = cells.sorted()
        for (i in 1 until sorted.size) {
            if (sorted[i] - sorted[i - 1] != step) return false
        }
        return true
    }

    /**
     * The same checks, in the same order, as `backend/games/src/engine/seabattle/fleet.ts`.
     * Order matters for the message the player sees: overlap is reported before contiguity on
     * the server, so it must be here too or the two disagree about *why* a fleet failed.
     */
    fun validate(ships: List<SeaBattleShip>): SeaBattleFailure? {
        if (ships.size != SeaBattle.FLEET_SPEC.size) return SeaBattleFailure.WRONG_SHIP_COUNT

        val seenTypes = mutableSetOf<Int>()
        val occupied = mutableSetOf<Int>()

        for (ship in ships) {
            if (ship.type < 0 || ship.type >= SeaBattle.FLEET_SPEC.size) {
                return SeaBattleFailure.UNKNOWN_TYPE
            }
            if (!seenTypes.add(ship.type)) return SeaBattleFailure.DUPLICATE_TYPE
            if (ship.cells.size != SeaBattle.FLEET_SPEC[ship.type]) {
                return SeaBattleFailure.WRONG_LENGTH
            }
            for (c in ship.cells) {
                if (c < 0 || c >= SeaBattle.CELLS) return SeaBattleFailure.OFF_BOARD
                // Across the whole fleet, so this catches a ship doubling back on itself too.
                if (!occupied.add(c)) return SeaBattleFailure.OVERLAP
            }
            if (!isContiguousLine(ship.cells)) return SeaBattleFailure.NOT_CONTIGUOUS
        }

        return null
    }

    /** Can this ship sit here, ignoring itself? Used per-frame by the live drag preview. */
    fun canPlace(cells: List<Int>, others: List<SeaBattleShip>, length: Int): Boolean {
        if (cells.size != length) return false
        if (cells.any { it < 0 || it >= SeaBattle.CELLS }) return false
        if (!isContiguousLine(cells)) return false
        val taken = others.flatMap { it.cells }.toSet()
        return cells.none { it in taken }
    }

    /** The cells a ship of [length] would occupy from an origin. */
    fun run(origin: Int, length: Int, horizontal: Boolean): List<Int> {
        val x = SeaBattle.cx(origin)
        val y = SeaBattle.cy(origin)
        // Clamped so a ship dragged past the edge slides back on-board rather than vanishing —
        // a ship that disappears under the finger reads as a bug, not as a rejection.
        val ox = if (horizontal) min(x, SeaBattle.SIZE - length) else x
        val oy = if (horizontal) y else min(y, SeaBattle.SIZE - length)
        return (0 until length).map {
            if (horizontal) SeaBattle.packed(ox + it, oy) else SeaBattle.packed(ox, oy + it)
        }
    }

    /**
     * A legal fleet placed at random.
     *
     * MANDATORY AND THE DEFAULT PATH (§2.2): a player who must place five ships before their
     * first shot may never reach the first shot.
     */
    fun randomFleet(): List<SeaBattleShip> {
        repeat(200) {
            val ships = mutableListOf<SeaBattleShip>()
            val occupied = mutableSetOf<Int>()
            var ok = true

            // Longest first: a Carrier placed last into a crowded board is what fails.
            for ((type, length) in SeaBattle.FLEET_SPEC.withIndex()) {
                var placed = false
                var tries = 0
                while (tries < 100 && !placed) {
                    tries++
                    val horizontal = Random.nextBoolean()
                    val x = Random.nextInt(
                        if (horizontal) SeaBattle.SIZE - length + 1 else SeaBattle.SIZE)
                    val y = Random.nextInt(
                        if (horizontal) SeaBattle.SIZE else SeaBattle.SIZE - length + 1)
                    val cells = (0 until length).map {
                        if (horizontal) SeaBattle.packed(x + it, y) else SeaBattle.packed(x, y + it)
                    }
                    if (cells.any { it in occupied }) continue
                    occupied.addAll(cells)
                    ships.add(SeaBattleShip(type, cells))
                    placed = true
                }
                if (!placed) { ok = false; break }
            }

            if (ok) return ships
        }

        // Unreachable in practice. A dull legal fleet still beats throwing inside a match.
        return SeaBattle.FLEET_SPEC.mapIndexed { type, length ->
            SeaBattleShip(type, (0 until length).map { SeaBattle.packed(it, type) })
        }
    }
}

/** What one square shows. Derived from the frame, never from a local guess about a shot. */
enum class SeaBattleCell { WATER, MISS, HIT, SUNK, SHIP, SHIP_HIT }

// Ink on paper (§8.2). Not naval-realistic and not Snake's retro-neon: the fiction is a naval
// chart, which is what the player is actually working, and it makes "nothing moves" an aesthetic
// rather than a limitation. Values match iOS exactly.
private val Ink = Color(0.16f, 0.21f, 0.28f)
private val Paper = Color(0.93f, 0.91f, 0.86f)
private val Sea = Color(0.80f, 0.85f, 0.87f)
private val HitRed = Color(0.72f, 0.22f, 0.15f)
private val SunkRed = Color(0.42f, 0.13f, 0.10f)

/**
 * A grid of 100 squares.
 *
 * PLAIN CANVAS, NOT a surface renderer: this draws 100 static rounded rects and at most one
 * animating shell. GAMES.md §4 specifies exactly this split.
 */
@Composable
fun SeaBattleGrid(
    cells: List<SeaBattleCell>,
    modifier: Modifier = Modifier,
    reticle: Int? = null,
    firing: Int? = null,
    dimmed: Boolean = false,
    onTap: ((Int) -> Unit)? = null,
    onDrag: ((Int) -> Unit)? = null,
) {
    Box(modifier.fillMaxWidth().aspectRatio(1f).padding(2.dp)) {
        Canvas(
            Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .pointerInput(onTap) {
                    detectTapGestures { offset ->
                        val cell = hit(offset, size.width.toFloat())
                        if (cell != null) onTap?.invoke(cell)
                    }
                }
                .pointerInput(onDrag) {
                    detectDragGestures { change, _ ->
                        val cell = hit(change.position, size.width.toFloat())
                        if (cell != null) onDrag?.invoke(cell)
                    }
                }
        ) {
            val cellSize = size.width / SeaBattle.SIZE
            val alpha = if (dimmed) 0.6f else 1f

            for (index in 0 until SeaBattle.CELLS) {
                val x = SeaBattle.cx(index) * cellSize
                val y = SeaBattle.cy(index) * cellSize
                val state = cells.getOrElse(index) { SeaBattleCell.WATER }
                val inset = 0.6f

                drawRoundRect(
                    color = fillFor(state).copy(alpha = fillFor(state).alpha * alpha),
                    topLeft = Offset(x + inset, y + inset),
                    size = Size(cellSize - inset * 2, cellSize - inset * 2),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f),
                )
                drawRoundRect(
                    color = Ink.copy(alpha = 0.12f * alpha),
                    topLeft = Offset(x + inset, y + inset),
                    size = Size(cellSize - inset * 2, cellSize - inset * 2),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f),
                    style = Stroke(width = 0.5f),
                )

                // HIT AND MISS DIFFER IN SHAPE AND FILL BEFORE THEY DIFFER IN COLOUR (§8.4).
                // CROSS_CUTTING.md §13 flags Snake identifying players by colour alone as a
                // problem for ~8% of men; hit/miss is the most important read in this game, so
                // the board must survive being rendered in greyscale.
                val centre = Offset(x + cellSize / 2, y + cellSize / 2)
                when (state) {
                    // A small hollow ring. Recedes.
                    SeaBattleCell.MISS -> drawCircle(
                        color = Ink.copy(alpha = 0.5f * alpha),
                        radius = cellSize * 0.18f,
                        center = centre,
                        style = Stroke(width = 1.2f),
                    )
                    // A large filled mark. Advances.
                    SeaBattleCell.HIT, SeaBattleCell.SHIP_HIT -> drawCircle(
                        color = HitRed.copy(alpha = alpha),
                        radius = cellSize * 0.30f,
                        center = centre,
                    )
                    SeaBattleCell.SUNK -> drawRoundRect(
                        color = SunkRed.copy(alpha = alpha),
                        topLeft = Offset(x + cellSize * 0.12f, y + cellSize * 0.12f),
                        size = Size(cellSize * 0.76f, cellSize * 0.76f),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f),
                    )
                    else -> Unit
                }
            }

            reticle?.let {
                drawRoundRect(
                    color = HitRed,
                    topLeft = Offset(SeaBattle.cx(it) * cellSize, SeaBattle.cy(it) * cellSize),
                    size = Size(cellSize, cellSize),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                    style = Stroke(width = 2f),
                )
            }

            firing?.let {
                drawCircle(
                    color = Ink.copy(alpha = 0.8f),
                    radius = cellSize * 0.16f,
                    center = Offset(
                        SeaBattle.cx(it) * cellSize + cellSize / 2,
                        SeaBattle.cy(it) * cellSize + cellSize / 2),
                )
            }
        }
    }
}

private fun hit(offset: Offset, width: Float): Int? {
    val cellSize = width / SeaBattle.SIZE
    val x = (offset.x / cellSize).toInt()
    val y = (offset.y / cellSize).toInt()
    if (x < 0 || x >= SeaBattle.SIZE || y < 0 || y >= SeaBattle.SIZE) return null
    return SeaBattle.packed(x, y)
}

private fun fillFor(state: SeaBattleCell): Color = when (state) {
    SeaBattleCell.WATER -> Sea.copy(alpha = 0.55f)
    SeaBattleCell.MISS -> Sea.copy(alpha = 0.35f)
    SeaBattleCell.HIT -> Paper
    SeaBattleCell.SUNK -> Paper
    SeaBattleCell.SHIP -> Ink.copy(alpha = 0.62f)
    SeaBattleCell.SHIP_HIT -> Ink.copy(alpha = 0.45f)
}
