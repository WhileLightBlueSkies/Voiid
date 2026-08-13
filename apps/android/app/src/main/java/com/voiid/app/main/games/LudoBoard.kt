package com.voiid.app.main.games

import androidx.compose.ui.graphics.Color

/**
 * Ludo board geometry (docs/games/future/LUDO.md §6.2).
 *
 * THE GEOMETRY IS A LOOKUP TABLE, NOT DRAWING CODE. [squareCentre] maps a server position
 * encoding to a point in normalised board space, and every token position, tap target and
 * highlight reads from it. §6.2 is explicit about why: two hand-drawn board layouts that
 * disagree by a few points is exactly the parity drift ANDROID_IOS_PARITY.md exists to prevent,
 * and a table is checkable where drawing code is not.
 *
 * The POSITION ENCODING is the server's, unchanged (backend/games/src/engine/ludo/board.ts):
 *   -1        yard
 *   0..51     main track, ABSOLUTE index
 *   100..104  home column, 100 + step
 *   200       home
 *
 * PORTED LITERALLY from iOS `LudoBoard.swift`. `LudoBoardTest` asserts the properties that
 * matter — 52 cells, no duplicates, entries at 0/13/26/39 — against the same numbers.
 */
object Ludo {
    const val TRACK = 52
    const val COLUMN = 5
    const val MAX_SEATS = 4
    const val GRID = 15

    const val YARD = -1
    const val COLUMN_BASE = 100
    const val HOME = 200

    fun inYard(p: Int) = p == YARD
    fun onTrack(p: Int) = p in 0 until TRACK
    fun inColumn(p: Int) = p in COLUMN_BASE until (COLUMN_BASE + COLUMN)
    fun isHome(p: Int) = p == HOME

    fun entrySquare(seat: Int) = (seat * 13) % TRACK

    /** The eight starred squares. The board must TEACH this rule, so they are drawn (§8.1). */
    val SAFE_SQUARES = setOf(0, 8, 13, 21, 26, 34, 39, 47)
    fun isSafe(p: Int) = onTrack(p) && p in SAFE_SQUARES

    /**
     * Four colours that are ALSO distinguishable by shape (§8.1).
     *
     * Ludo is traditionally colour-only and that is precisely the trap: CROSS_CUTTING.md §13
     * flags Snake identifying players by colour alone as a problem for ~8% of men, and with four
     * players it is four times worse.
     */
    val SEAT_COLORS = listOf(
        Color(0.85f, 0.27f, 0.24f),   // red
        Color(0.20f, 0.51f, 0.78f),   // blue
        Color(0.25f, 0.62f, 0.35f),   // green
        Color(0.94f, 0.71f, 0.20f),   // yellow
    )
    val SEAT_NAMES = listOf("Red", "Blue", "Green", "Yellow")

    /**
     * The 52 main-track squares, in order, on a 15x15 grid. Index 0 is seat 0's entry.
     *
     * DERIVED, THEN PINNED — the traced perimeter of the standard cross, with the four cells
     * diagonally adjacent to the centre removed. Written as a literal rather than generated
     * because the array is the thing both platforms must agree on, and a literal can be diffed.
     *
     * FOUR OF THE 52 STEPS ARE DIAGONAL, at the arm corners, and that is inherent rather than a
     * defect: the orthogonal perimeter of this cross is 56, so a 52-cell ring must cut the
     * corners. Stated here because "why are there diagonal steps" is otherwise a bug report.
     */
    val TRACK_CELLS: List<Pair<Int, Int>> = listOf(
        6 to 13, 6 to 12, 6 to 11, 6 to 10, 6 to 9, 5 to 8,
        4 to 8, 3 to 8, 2 to 8, 1 to 8, 0 to 8, 0 to 7,
        0 to 6, 1 to 6, 2 to 6, 3 to 6, 4 to 6, 5 to 6,
        6 to 5, 6 to 4, 6 to 3, 6 to 2, 6 to 1, 6 to 0,
        7 to 0, 8 to 0, 8 to 1, 8 to 2, 8 to 3, 8 to 4,
        8 to 5, 9 to 6, 10 to 6, 11 to 6, 12 to 6, 13 to 6,
        14 to 6, 14 to 7, 14 to 8, 13 to 8, 12 to 8, 11 to 8,
        10 to 8, 9 to 8, 8 to 9, 8 to 10, 8 to 11, 8 to 12,
        8 to 13, 8 to 14, 7 to 14, 6 to 14,
    )

    /**
     * The 5 home-column squares per seat, running inward toward the centre.
     *
     * Five, matching the server's `COLUMN = 5`. The sixth cell of each middle lane is the arm
     * mouth and belongs to the track, which is what makes the ring 52 rather than 56.
     */
    val COLUMN_CELLS: List<List<Pair<Int, Int>>> = listOf(
        listOf(7 to 13, 7 to 12, 7 to 11, 7 to 10, 7 to 9),   // seat 0, up from the bottom
        listOf(1 to 7, 2 to 7, 3 to 7, 4 to 7, 5 to 7),       // seat 1, in from the left
        listOf(7 to 1, 7 to 2, 7 to 3, 7 to 4, 7 to 5),       // seat 2, down from the top
        listOf(13 to 7, 12 to 7, 11 to 7, 10 to 7, 9 to 7),   // seat 3, in from the right
    )

    /** The four yard pockets, four slots each. */
    val YARD_CELLS: List<List<Pair<Int, Int>>> = listOf(
        listOf(2 to 11, 4 to 11, 2 to 13, 4 to 13),     // seat 0, bottom-left
        listOf(2 to 2, 4 to 2, 2 to 4, 4 to 4),         // seat 1, top-left
        listOf(10 to 2, 12 to 2, 10 to 4, 12 to 4),     // seat 2, top-right
        listOf(10 to 10, 12 to 10, 10 to 12, 12 to 12), // seat 3, bottom-right
    )

    /**
     * Where a token sits, in normalised board space (0..1 on both axes).
     *
     * [tokenIndex] only matters in the yard, where four tokens occupy four distinct slots;
     * everywhere else a seat's tokens can legitimately share a square (a block or a safe stack)
     * and the renderer fans them out rather than the table doing it.
     */
    fun squareCentre(position: Int, seat: Int, tokenIndex: Int = 0): Pair<Float, Float> {
        val cell = when {
            isHome(position) -> 7 to 7                                  // the centre triangle
            inColumn(position) ->
                COLUMN_CELLS[seat % MAX_SEATS][minOf(position - COLUMN_BASE, COLUMN - 1)]
            onTrack(position) -> TRACK_CELLS[position % TRACK]
            else -> YARD_CELLS[seat % MAX_SEATS][tokenIndex % 4]
        }
        val unit = 1f / GRID
        return ((cell.first + 0.5f) * unit) to ((cell.second + 0.5f) * unit)
    }
}
