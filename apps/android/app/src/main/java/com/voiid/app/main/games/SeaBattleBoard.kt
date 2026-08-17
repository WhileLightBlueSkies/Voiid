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
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.unit.dp
import com.voiid.app.net.GamesEngine
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
    /**
     * 0..1 through the shell's travel, so the reticle can contract to a point (§9).
     *
     * Was missing entirely: `firing` used to draw a static dot that appeared and vanished, so a
     * shot on a fast connection was over before it registered. See [SeaBattleMotion].
     */
    shellProgress: Float = 0f,
    /** Cells of a ship that has just been sunk, revealed one at a time (§9). */
    sunkReveal: List<Int> = emptyList(),
    /** Seconds, for the water shimmer and the flame flicker. */
    now: Float = 0f,
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

            // THE CHART UNDER THE WATER (§8.2). Paper and ink, not naval realism.
            with(GameSurface) {
                paper(
                    androidx.compose.ui.geometry.Rect(Offset.Zero, size),
                    Paper, grain = 0.020, seed = 3)
            }

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
                // WATER SHIMMER on anything still unknown. Each cell has its own phase from a
                // positional hash, so the surface moves as a field rather than the whole screen
                // breathing in unison. ~0.04 amplitude, per §8.2.
                if (state == SeaBattleCell.WATER) {
                    val phase = GameSurface.noise(SeaBattle.cx(index), SeaBattle.cy(index), 5)
                    val caustic = (0.04 * (0.5 + 0.5 * kotlin.math.sin(now * 0.79 + phase * 6.28)))
                        .toFloat()
                    drawRoundRect(
                        color = Color.White.copy(alpha = caustic * alpha),
                        topLeft = Offset(x + inset, y + inset),
                        size = Size(cellSize - inset * 2, cellSize - inset * 2),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f),
                    )
                }
                with(GameSurface) {
                    inset(
                        androidx.compose.ui.geometry.Rect(
                            Offset(x + inset, y + inset),
                            Size(cellSize - inset * 2, cellSize - inset * 2)),
                        radius = 1.5f, depth = 0.6f)
                }

                // HIT AND MISS DIFFER IN SHAPE AND FILL BEFORE THEY DIFFER IN COLOUR (§8.4).
                // CROSS_CUTTING.md §13 flags Snake identifying players by colour alone as a
                // problem for ~8% of men; hit/miss is the most important read in this game, so
                // the board must survive being rendered in greyscale.
                val centre = Offset(x + cellSize / 2, y + cellSize / 2)
                when (state) {
                    // A SPLASH: the ring plus two fainter ones still spreading. Recedes.
                    SeaBattleCell.MISS -> {
                        drawCircle(
                            color = Ink.copy(alpha = 0.5f * alpha),
                            radius = cellSize * 0.18f,
                            center = centre,
                            style = Stroke(width = 1.2f),
                        )
                        listOf(1.55f to 0.16f, 2.05f to 0.10f).forEach { (scale, a) ->
                            drawCircle(
                                color = Ink.copy(alpha = a * alpha),
                                radius = cellSize * 0.18f * scale,
                                center = centre,
                                style = Stroke(width = 0.7f),
                            )
                        }
                    }
                    // A SCORCH: a hot radial burn. Advances.
                    SeaBattleCell.HIT, SeaBattleCell.SHIP_HIT -> drawCircle(
                        brush = Brush.radialGradient(
                            colors = listOf(
                                Color(0.95f, 0.55f, 0.15f),
                                HitRed,
                                Color(0.30f, 0.10f, 0.08f),
                            ),
                            center = centre,
                            radius = cellSize * 0.32f,
                        ),
                        radius = cellSize * 0.32f,
                        center = centre,
                    )
                    // A SUNK HULL, still burning. The flame flickers on its own phase so a
                    // multi-cell wreck does not pulse as one block.
                    SeaBattleCell.SUNK -> {
                        drawRoundRect(
                            color = Color(0.24f, 0.09f, 0.07f).copy(alpha = alpha),
                            topLeft = Offset(x + cellSize * 0.10f, y + cellSize * 0.10f),
                            size = Size(cellSize * 0.80f, cellSize * 0.80f),
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(1.5f),
                        )
                        val phase = GameSurface.noise(SeaBattle.cx(index), SeaBattle.cy(index), 9)
                        val flicker = (0.5 + 0.5 * kotlin.math.sin(now * 6.1 + phase * 6.28)).toFloat()
                        val fh = cellSize * (0.26f + 0.16f * flicker)
                        val base = centre.y + cellSize * 0.10f
                        val flame = Path().apply {
                            moveTo(centre.x - cellSize * 0.14f, base)
                            quadraticBezierTo(
                                centre.x - cellSize * 0.18f, base - fh * 0.3f, centre.x, base - fh)
                            quadraticBezierTo(
                                centre.x + cellSize * 0.18f, base - fh * 0.3f,
                                centre.x + cellSize * 0.14f, base)
                            close()
                        }
                        drawPath(
                            flame,
                            Brush.verticalGradient(
                                colors = listOf(
                                    Color(0.55f, 0.12f, 0.05f).copy(alpha = 0f),
                                    Color(0.92f, 0.36f, 0.10f).copy(alpha = 0.75f),
                                    Color(1f, 0.85f, 0.35f).copy(alpha = 0.95f),
                                ),
                                startY = base - fh,
                                endY = base,
                            ),
                        )
                    }
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

            // THE SHELL (§9). The reticle contracts to a point over 380 ms, accelerating —
            // because accelerating reads as falling. That window is also where the server's
            // answer arrives, which is what lets a fully round-tripped game feel instant.
            firing?.let {
                val t = shellProgress.coerceIn(0f, 1f)
                // easeIn: t^2. Slow away, fast into the water.
                val eased = t * t
                val shrink = cellSize * 0.5f * (1f - eased)
                val inset = 0.6f
                drawRoundRect(
                    color = HitRed,
                    topLeft = Offset(
                        SeaBattle.cx(it) * cellSize + inset + shrink,
                        SeaBattle.cy(it) * cellSize + inset + shrink),
                    size = Size(
                        (cellSize - inset * 2 - shrink * 2).coerceAtLeast(0f),
                        (cellSize - inset * 2 - shrink * 2).coerceAtLeast(0f)),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                    style = Stroke(width = 2f * (1f - eased) + 0.5f),
                )
                val dot = cellSize * 0.06f + cellSize * 0.10f * eased
                drawCircle(
                    color = Ink.copy(alpha = 0.35f + 0.5f * eased),
                    radius = dot,
                    center = Offset(
                        SeaBattle.cx(it) * cellSize + cellSize / 2,
                        SeaBattle.cy(it) * cellSize + cellSize / 2),
                )
            }

            // THE SUNK OUTLINE, DRAWN IN CELL BY CELL (§9). A ship that simply turns dark reads
            // as a state change; drawing it along its own hull reads as the ship going down.
            for (cell in sunkReveal) {
                if (cell >= SeaBattle.CELLS) continue
                drawRoundRect(
                    color = SunkRed,
                    topLeft = Offset(
                        SeaBattle.cx(cell) * cellSize - 0.4f,
                        SeaBattle.cy(cell) * cellSize - 0.4f),
                    size = Size(cellSize + 0.8f, cellSize + 0.8f),
                    cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                    style = Stroke(width = 2f),
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

// ---- deriving the two boards from a frame -------------------------------------------------
//
// SHARED BY THE ONLINE MATCH AND PRACTICE MODE, and that is the whole reason these are not
// private to a screen. The bot match builds a `SeaBattleState` that looks exactly like a server
// frame, so both screens read the board through the same three functions — which means a player
// cannot tell a practice board from a real one, and a fix to one is a fix to both.
//
// Every rule that decides what is VISIBLE lives here: their un-hit ships are never in a frame,
// sunk outlines become public at the moment of sinking, and both fleets appear only once the
// match is over. Mirrors iOS `SeaBattleCells`.

/**
 * What the OPPONENT's board looks like from here: my shots, and any ship I have sunk. Their
 * un-hit ships are not in this frame at all, so there is nothing to accidentally draw.
 */
fun enemyCells(s: GamesEngine.SeaBattleState, mySeat: Int?): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    val seat = mySeat ?: return cells
    val enemy = 1 - seat
    s.shots.getOrElse(seat) { emptyList() }.forEachIndexed { i, cell ->
        if (cell in cells.indices) {
            val result = s.results.getOrElse(seat) { emptyList() }.getOrElse(i) { 0 }
            cells[cell] = if (result == 0) SeaBattleCell.MISS else SeaBattleCell.HIT
        }
    }
    // Sunk outlines are public once the ship is down, and they are what makes the endgame
    // deduction rather than a grind (§2.4).
    s.sunkCells.getOrElse(enemy) { emptyList() }.forEach {
        if (it in cells.indices) cells[it] = SeaBattleCell.SUNK
    }
    // Once the match is over the terminal frame carries both fleets, so the loser's unhit ships
    // finally appear. This is the ONLY path that draws an enemy ship that is not sunk.
    if (s.finished) {
        s.revealedFleets?.getOrNull(enemy)?.forEach { ship ->
            ship.cells.forEach {
                if (it in cells.indices && cells[it] == SeaBattleCell.WATER) {
                    cells[it] = SeaBattleCell.SHIP
                }
            }
        }
    }
    return cells
}

/** My own board: my fleet, and their shots on it. */
fun ownCells(
    s: GamesEngine.SeaBattleState,
    mySeat: Int?,
    draft: List<SeaBattleShip>,
): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    // During placement the frame has no fleet yet, so fall back to the local draft — the only
    // place the two are interchangeable, and only because nothing is committed.
    val fleet = if (s.myFleet.isEmpty()) {
        draft.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) }
    } else s.myFleet
    fleet.forEach { ship ->
        ship.cells.forEach { if (it in cells.indices) cells[it] = SeaBattleCell.SHIP }
    }
    val seat = mySeat ?: return cells
    val enemy = 1 - seat
    s.shots.getOrElse(enemy) { emptyList() }.forEachIndexed { i, cell ->
        if (cell in cells.indices) {
            val result = s.results.getOrElse(enemy) { emptyList() }.getOrElse(i) { 0 }
            cells[cell] = if (result == 0) SeaBattleCell.MISS else SeaBattleCell.SHIP_HIT
        }
    }
    s.sunkCells.getOrElse(seat) { emptyList() }.forEach {
        if (it in cells.indices) cells[it] = SeaBattleCell.SUNK
    }
    return cells
}

fun draftCells(draft: List<SeaBattleShip>): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    draft.forEach { ship ->
        ship.cells.forEach { if (it in cells.indices) cells[it] = SeaBattleCell.SHIP }
    }
    return cells
}
