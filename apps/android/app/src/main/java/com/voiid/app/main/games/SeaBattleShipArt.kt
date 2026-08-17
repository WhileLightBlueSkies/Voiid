package com.voiid.app.main.games

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path

/**
 * Hull silhouettes for the five ships (docs/games/VISUALS_AUDIO_AND_PARITY.md §6.3).
 *
 * THE STRUCTURAL CHANGE: SHIPS ARE DRAWN PER SHIP, NOT PER CELL.
 *
 * The grid renderer loops 0 until 100 and draws each square independently, so a cell has no idea
 * it is the bow of a Carrier — a fleet was five runs of identical flat rectangles. A hull cannot
 * be assembled out of squares that do not know about each other, which is why this takes a ship's
 * whole bounding box and returns one path across it.
 *
 * [SeaBattleRules.isContiguousLine] already guarantees a ship's cells are collinear and
 * contiguous, so the bounding box IS the ship and there is nothing to infer here.
 *
 * FIVE SILHOUETTES FOR FIVE LENGTHS, matching `FLEET_SPEC = [5, 4, 3, 3, 2]`. The two 3-cell
 * ships are deliberately different shapes — a Cruiser and a Submarine are the same length and
 * must not be the same picture, or the fleet strip teaches nothing.
 *
 * Ported from iOS `SeaBattleShipArt.swift`. Every control point is a parity surface.
 */
object SeaBattleShipArt {

    /**
     * A hull in UNIT SPACE: x runs 0..1 bow-to-stern along the ship's length, y runs 0..1 across
     * its beam. The caller scales it into the ship's bounding box and rotates for a vertical
     * ship, so one path serves both orientations.
     */
    fun hull(type: Int): Path = Path().apply {
        when (type) {
            0 -> carrier(this)
            1 -> battleship(this)
            2 -> cruiser(this)
            3 -> submarine(this)
            else -> destroyer(this)
        }
    }

    /**
     * Deck furniture drawn ON TOP of the hull — towers, turrets, funnels. Separate from the hull
     * so a damaged ship can scorch the hull and keep its silhouette readable.
     */
    fun details(type: Int): List<Path> = when (type) {
        0 -> carrierDetails()
        1 -> battleshipDetails()
        2 -> cruiserDetails()
        3 -> submarineDetails()
        else -> destroyerDetails()
    }

    // ---- hulls ------------------------------------------------------------------------------

    /** CARRIER (5) — a flat deck with a blunt bow. The longest ship reads by its deck. */
    private fun carrier(p: Path) = with(p) {
        moveTo(0.02f, 0.34f)
        quadraticTo(0.02f, 0.22f, 0.12f, 0.18f)
        lineTo(0.94f, 0.20f)
        quadraticTo(1.00f, 0.34f, 0.98f, 0.50f)
        quadraticTo(1.00f, 0.66f, 0.94f, 0.80f)
        lineTo(0.12f, 0.82f)
        quadraticTo(0.02f, 0.78f, 0.02f, 0.66f)
        close()
    }

    /** BATTLESHIP (4) — a pointed bow and a squared stern. The classic warship profile. */
    private fun battleship(p: Path) = with(p) {
        moveTo(0.01f, 0.50f)
        quadraticTo(0.06f, 0.24f, 0.22f, 0.19f)
        lineTo(0.93f, 0.22f)
        lineTo(0.97f, 0.50f)
        lineTo(0.93f, 0.78f)
        lineTo(0.22f, 0.81f)
        quadraticTo(0.06f, 0.76f, 0.01f, 0.50f)
        close()
    }

    /** CRUISER (3) — narrower than the battleship, with a raked bow. */
    private fun cruiser(p: Path) = with(p) {
        moveTo(0.02f, 0.50f)
        quadraticTo(0.07f, 0.29f, 0.26f, 0.25f)
        lineTo(0.92f, 0.28f)
        lineTo(0.96f, 0.50f)
        lineTo(0.92f, 0.72f)
        lineTo(0.26f, 0.75f)
        quadraticTo(0.07f, 0.71f, 0.02f, 0.50f)
        close()
    }

    /**
     * SUBMARINE (3) — ROUNDED AT BOTH ENDS, no deck. Same length as the cruiser and a completely
     * different silhouette, which is the whole point.
     */
    private fun submarine(p: Path) = with(p) {
        moveTo(0.14f, 0.30f)
        lineTo(0.86f, 0.30f)
        quadraticTo(1.02f, 0.50f, 0.86f, 0.70f)
        lineTo(0.14f, 0.70f)
        quadraticTo(-0.02f, 0.50f, 0.14f, 0.30f)
        close()
    }

    /** DESTROYER (2) — small and sharp. At two cells there is no room for anything else. */
    private fun destroyer(p: Path) = with(p) {
        moveTo(0.03f, 0.50f)
        quadraticTo(0.08f, 0.30f, 0.30f, 0.27f)
        lineTo(0.90f, 0.30f)
        lineTo(0.95f, 0.50f)
        lineTo(0.90f, 0.70f)
        lineTo(0.30f, 0.73f)
        quadraticTo(0.08f, 0.70f, 0.03f, 0.50f)
        close()
    }

    // ---- deck detail ------------------------------------------------------------------------

    private fun roundRect(x: Float, y: Float, w: Float, h: Float, r: Float): Path = Path().apply {
        addRoundRect(
            androidx.compose.ui.geometry.RoundRect(
                Rect(Offset(x, y), Size(w, h)),
                androidx.compose.ui.geometry.CornerRadius(r),
            )
        )
    }

    private fun oval(x: Float, y: Float, w: Float, h: Float): Path = Path().apply {
        addOval(Rect(Offset(x, y), Size(w, h)))
    }

    private fun carrierDetails() = listOf(
        // Island tower at 60% of the length, plus two aircraft on the deck.
        roundRect(0.55f, 0.10f, 0.11f, 0.24f, 0.02f),
        roundRect(0.22f, 0.44f, 0.13f, 0.05f, 0.02f),
        roundRect(0.40f, 0.56f, 0.13f, 0.05f, 0.02f),
    )

    private fun battleshipDetails() = listOf(
        oval(0.28f, 0.40f, 0.10f, 0.20f),
        roundRect(0.46f, 0.34f, 0.14f, 0.32f, 0.03f),
        oval(0.70f, 0.40f, 0.10f, 0.20f),
    )

    private fun cruiserDetails() = listOf(
        oval(0.33f, 0.40f, 0.11f, 0.20f),
        roundRect(0.58f, 0.32f, 0.06f, 0.36f, 0.02f),
    )

    /** A conning tower and nothing else — a submarine has no deck to furnish. */
    private fun submarineDetails() = listOf(roundRect(0.44f, 0.16f, 0.14f, 0.20f, 0.04f))

    private fun destroyerDetails() = listOf(roundRect(0.52f, 0.34f, 0.10f, 0.32f, 0.03f))

    // ---- placement --------------------------------------------------------------------------

    /**
     * The rect a ship occupies, and whether it runs horizontally.
     *
     * [cells] is guaranteed contiguous and collinear by [SeaBattleRules], so min/max IS the
     * hull's extent.
     */
    fun frame(cells: List<Int>, cellSize: Float): Pair<Rect, Boolean>? {
        if (cells.isEmpty()) return null
        val xs = cells.map { SeaBattle.cx(it) }
        val ys = cells.map { SeaBattle.cy(it) }
        val minX = xs.min(); val maxX = xs.max()
        val minY = ys.min(); val maxY = ys.max()
        // A one-cell ship does not exist in this fleet, so a single row means horizontal.
        val horizontal = (maxY - minY) == 0
        return Rect(
            Offset(minX * cellSize, minY * cellSize),
            Size((maxX - minX + 1) * cellSize, (maxY - minY + 1) * cellSize),
        ) to horizontal
    }

    // ---- palette ----------------------------------------------------------------------------

    val HullBody = Color(0.30f, 0.34f, 0.38f)
    val HullLit = Color(0.44f, 0.49f, 0.53f)
    val HullDeck = Color(0.53f, 0.56f, 0.58f)
    val HullInk = Color(0.10f, 0.12f, 0.14f)
    /** A sunk hull desaturates and darkens rather than vanishing — the wreck is information. */
    val HullSunk = Color(0.20f, 0.18f, 0.18f)
}
