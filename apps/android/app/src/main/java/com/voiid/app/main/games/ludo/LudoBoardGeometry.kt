package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size

/**
 * Generated 15×15 board geometry (LUDO_GAME_SPEC.md §3).
 *
 * ONE immutable array of 225 addressable nodes, row-major, built from the same tables the
 * backend fixture generator uses. The checked-in fixture
 * (app/src/test/resources/ludo_board_v3.json) pins every coordinate; [selfCheck] fails fast
 * in unit tests and in DEBUG builds if any table ever drifts.
 *
 * The board NEVER rotates per viewer: green top-left, yellow top-right, blue bottom-right,
 * red bottom-left, (0,0) at the physical top-left, x increasing right, y increasing down.
 */
object LudoBoardGeometry {

    const val SIDE = 15
    const val CELL_COUNT = SIDE * SIDE

    enum class Role { YARD, YARD_POCKET, SHARED_TRACK, HOME_LANE, CENTER, UNUSED }
    enum class Decoration { NONE, STAR, APPROACH_CHEVRON }

    data class CellNode(
        val id: String,
        val x: Int,
        val y: Int,
        val role: Role,
        val seat: Int?,
        val trackIndex: Int?,
        val homeStep: Int?,
        val isSafe: Boolean,
        val decoration: Decoration,
    )

    /** Shared-track absolute index → (x,y). Authoritative table from §3.2. */
    val TRACK_COORDS: List<Pair<Int, Int>> = listOf(
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

    /** Home lane coordinates per seat, OUTSIDE → INSIDE (homeStep 0..4). */
    val HOME_LANE_COORDS: List<List<Pair<Int, Int>>> = listOf(
        listOf(7 to 13, 7 to 12, 7 to 11, 7 to 10, 7 to 9),   // red
        listOf(1 to 7, 2 to 7, 3 to 7, 4 to 7, 5 to 7),       // green
        listOf(7 to 1, 7 to 2, 7 to 3, 7 to 4, 7 to 5),       // yellow
        listOf(13 to 7, 12 to 7, 11 to 7, 10 to 7, 9 to 7),   // blue
    )

    /** Yard origins (top-left of each 6x6 yard block), in grid units. */
    val YARD_ORIGINS: List<Pair<Float, Float>> = listOf(
        0f to 9f,   // red, bottom-left
        0f to 0f,   // green, top-left
        9f to 0f,   // yellow, top-right
        9f to 9f,   // blue, bottom-right
    )

    /**
     * Yard pawn slots as CONTINUOUS grid coordinates, not cell indices. The pocket drawn in each
     * yard is centred on origin+3, so the slots sit at that centre ±1 and read as evenly inset
     * from every pocket edge. Consuming these as cell indices (and so as cell CENTRES, index +
     * 0.5) is what used to push every pawn half a cell down-right.
     */
    val YARD_SLOTS: List<List<Pair<Float, Float>>> = YARD_ORIGINS.map { (ox, oy) ->
        listOf(
            ox + 2f to oy + 2f,
            ox + 4f to oy + 2f,
            ox + 2f to oy + 4f,
            ox + 4f to oy + 4f,
        )
    }
    val FINISH_SLOTS: List<List<Pair<Float, Float>>> = listOf(
        listOf(1.15f to 2.15f, 1.85f to 2.15f, 1.15f to 2.65f, 1.85f to 2.65f),
        listOf(.35f to 1.15f, .85f to 1.15f, .35f to 1.85f, .85f to 1.85f),
        listOf(1.15f to .35f, 1.85f to .35f, 1.15f to .85f, 1.85f to .85f),
        listOf(2.15f to 1.15f, 2.65f to 1.15f, 2.15f to 1.85f, 2.65f to 1.85f),
    )

    /** Normalized clockwise border anchors (§12.1). */
    val BORDER_ANCHORS = floatArrayOf(0.00f, 0.25f, 0.50f, 0.75f)

    private val trackAt: Map<Pair<Int, Int>, Int> =
        TRACK_COORDS.withIndex().associate { (i, c) -> c to i }

    private val laneAt: Map<Pair<Int, Int>, Pair<Int, Int>> =
        HOME_LANE_COORDS.flatMapIndexed { seat, lane ->
            lane.mapIndexed { step, c -> c to (seat to step) }
        }.toMap()

    private fun centerOf(x: Int, y: Int): Boolean =
        x in 6..8 && y in 6..8

    private fun quadrantOf(x: Int, y: Int): Triple<Int, Int, Int>? = when {
        x < 6 && y < 6 -> Triple(1, 0, 0)   // green top-left
        x > 8 && y < 6 -> Triple(2, 9, 0)   // yellow top-right
        x < 6 && y > 8 -> Triple(0, 0, 9)   // red bottom-left
        x > 8 && y > 8 -> Triple(3, 9, 9)   // blue bottom-right
        else -> null
    }

    /** The 225 nodes, row-major, ids "cell-x-y". Built once; immutable afterwards. */
    val CELLS: List<CellNode> = buildList {
        for (y in 0 until SIDE) {
            for (x in 0 until SIDE) {
                var role = Role.UNUSED
                var seat: Int? = null
                var trackIndex: Int? = null
                var homeStep: Int? = null
                var isSafe = false
                var decoration = Decoration.NONE

                when {
                    centerOf(x, y) -> role = Role.CENTER
                    trackAt.containsKey(x to y) -> {
                        role = Role.SHARED_TRACK
                        trackIndex = trackAt[x to y]
                        isSafe = LudoRules.SAFE_INDICES.contains(trackIndex)
                        if (trackIndex in LudoRules.ENTRY_INDICES) seat = LudoRules.ENTRY_INDICES.indexOf(trackIndex)
                        decoration = when (trackIndex) {
                            in LudoRules.APPROACH_INDICES -> {
                                seat = LudoRules.APPROACH_INDICES.indexOf(trackIndex)
                                Decoration.APPROACH_CHEVRON
                            }
                            in LudoRules.STAR_INDICES -> Decoration.STAR
                            else -> Decoration.NONE
                        }
                    }
                    laneAt.containsKey(x to y) -> {
                        role = Role.HOME_LANE
                        val (s, step) = laneAt[x to y]!!
                        seat = s
                        homeStep = step
                    }
                    else -> {
                        quadrantOf(x, y)?.let { (q, ox, oy) ->
                            val lx = x - ox
                            val ly = y - oy
                            seat = q
                            role = if (lx in 1..4 && ly in 1..4) Role.YARD_POCKET else Role.YARD
                        }
                    }
                }

                add(
                    CellNode(
                        id = "cell-$x-$y",
                        x = x, y = y,
                        role = role,
                        seat = seat,
                        trackIndex = trackIndex,
                        homeStep = homeStep,
                        isSafe = isSafe,
                        decoration = decoration,
                    )
                )
            }
        }
    }

    private val cellByCoord: Map<Pair<Int, Int>, CellNode> =
        CELLS.associateBy { it.x to it.y }

    fun cell(x: Int, y: Int): CellNode = cellByCoord.getValue(x to y)

    /**
     * Rect mapping derived each layout pass (§3.3): one logical unit is side/15.
     * Cells keep their OWN rect — never a flattened bitmap — so each node stays highlightable,
     * pulseable, hit-testable and describable independently.
     */
    class Layout(val side: Float) {
        val unit: Float = side / SIDE
        private val rects: Array<Rect?> = arrayOfNulls(CELL_COUNT)

        init {
            for (node in CELLS) {
                rects[node.y * SIDE + node.x] = Rect(
                    left = node.x * unit,
                    top = node.y * unit,
                    right = (node.x + 1) * unit,
                    bottom = (node.y + 1) * unit,
                )
            }
        }

        fun rectOf(node: CellNode): Rect = rects[node.y * SIDE + node.x]!!

        fun cellAt(offsetX: Float, offsetY: Float): CellNode? {
            if (offsetX < 0 || offsetY < 0 || offsetX >= side || offsetY >= side) return null
            val cx = (offsetX / unit).toInt().coerceIn(0, SIDE - 1)
            val cy = (offsetY / unit).toInt().coerceIn(0, SIDE - 1)
            return cell(cx, cy)
        }

        /** Center of an encoded position for this viewer-independent layout. */
        fun centerOfPosition(pos: Int, seat: Int): Pair<Float, Float> {
            val coord: Pair<Int, Int> = when {
                pos == LudoRules.YARD -> return yardSlotCenter(seat, 0)  // caller supplies pawn slot instead
                pos == LudoRules.FINISHED -> 7 to 7
                pos in LudoRules.HOME_LANE_BASE until LudoRules.HOME_LANE_BASE + LudoRules.HOME_LANE_COUNT ->
                    HOME_LANE_COORDS[seat][pos - LudoRules.HOME_LANE_BASE]
                else -> TRACK_COORDS[pos]
            }
            val r = rectOf(cell(coord.first, coord.second))
            return r.center.x to r.center.y
        }

        fun yardSlotCenter(seat: Int, pawn: Int): Pair<Float, Float> {
            val (sx, sy) = YARD_SLOTS[seat][pawn]
            return sx * unit to sy * unit
        }

        /** Centre of a seat's yard pocket, in px — the anchor the four slots ring. */
        fun yardPocketCenter(seat: Int): Pair<Float, Float> {
            val (ox, oy) = YARD_ORIGINS[seat % 4]
            return (ox + 3f) * unit to (oy + 3f) * unit
        }
    }

    /**
     * Parity self-check against the checked-in fixture (§19). Runs in the JVM unit test AND
     * as a DEBUG assertion on first layout, so no platform can drift from the one fixture.
     */
    fun selfCheck(fixtureCells: List<Map<String, Any?>>): Boolean {
        if (fixtureCells.size != CELL_COUNT) return false
        for ((i, node) in CELLS.withIndex()) {
            val f = fixtureCells[i]
            if (f["id"] != node.id) return false
            if ((f["x"] as Int) != node.x || (f["y"] as Int) != node.y) return false
            val roleOk = when (node.role) {
                Role.YARD -> f["role"] == "yard"
                Role.YARD_POCKET -> f["role"] == "yardPocket"
                Role.SHARED_TRACK -> f["role"] == "sharedTrack"
                Role.HOME_LANE -> f["role"] == "homeLane"
                Role.CENTER -> f["role"] == "center"
                Role.UNUSED -> f["role"] == "unused"
            }
            if (!roleOk) return false
            if ((f["seat"] as? Int) != node.seat) return false
            if ((f["trackIndex"] as? Int) != node.trackIndex) return false
            if ((f["homeStep"] as? Int) != node.homeStep) return false
            if ((f["isSafe"] as Boolean) != node.isSafe) return false
            val decOk = when (node.decoration) {
                Decoration.NONE -> f["decoration"] == "none"
                Decoration.STAR -> f["decoration"] == "star"
                Decoration.APPROACH_CHEVRON -> f["decoration"] == "approachChevron"
            }
            if (!decOk) return false
        }
        return true
    }
}
