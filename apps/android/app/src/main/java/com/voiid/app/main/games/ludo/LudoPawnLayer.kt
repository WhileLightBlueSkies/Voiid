package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.graphics.Color

/**
 * Pawn stacking and hit-target resolution (§4, §17).
 *
 *  - Two same-colour pawns on a NON-safe cell: 82% scale, offset ±0.14 cellSide perpendicular.
 *  - Up to four pawns on a SAFE cell: 2×2 fan at 68% scale.
 *  - Hit-testing resolves to the lowest legal token index at the tapped point; overlapping
 *    legal pawns open the token chooser (handled by the screen).
 */
object LudoPawnLayer {

    data class PlacedPawn(
        val seat: Int,
        val pawnIndex: Int,
        /** Display center in board coordinates. */
        val center: Offset,
        val scale: Float,
        /** True when part of a stack that needs the chooser on tap. */
        val overlapsLegalPeer: Boolean = false,
    )

    /**
     * Lay out every visible pawn for the frame. `displayOverrides` lets the presentation
     * coordinator move ONE display pawn along its hop path while authoritative state already
     * holds the destination — animation never feeds back into state.
     */
    fun layout(
        state: LudoGameState,
        layout: LudoBoardGeometry.Layout,
        droppedSeats: Set<Int>,
        displayOverride: Triple<Int, Int, Offset>? = null,
    ): List<PlacedPawn> {
        val out = mutableListOf<PlacedPawn>()
        if (state.tokens.isEmpty()) return out

        // Group pawns by their absolute position so stacks can be fanned.
        data class Entry(val seat: Int, val pawn: Int, val center: Offset)
        val groups = LinkedHashMap<Int, MutableList<Entry>>()

        for ((seat, row) in state.tokens.withIndex()) {
            if (seat in droppedSeats) continue
            for ((pawn, pos) in row.withIndex()) {
                val center: Offset = when {
                    pos == LudoRules.YARD ->
                        layout.yardSlotCenter(seat, pawn).let { Offset(it.first, it.second) }
                    pos == LudoRules.FINISHED -> {
                        val rect = LudoCellRenderer.finishSlotRect(seat, pawn, centerRect(layout))
                        rect.center
                    }
                    pos >= LudoRules.HOME_LANE_BASE -> {
                        val step = pos - LudoRules.HOME_LANE_BASE
                        val coord = LudoBoardGeometry.HOME_LANE_COORDS[seat][step]
                        val r = layout.rectOf(LudoBoardGeometry.cell(coord.first, coord.second))
                        r.center
                    }
                    else -> {
                        val coord = LudoBoardGeometry.TRACK_COORDS[pos]
                        val r = layout.rectOf(LudoBoardGeometry.cell(coord.first, coord.second))
                        r.center
                    }
                }
                // Finished pawns draw at 52% inside their triangle slot (§3.2).
                val key = when {
                    pos == LudoRules.YARD -> null
                    pos == LudoRules.FINISHED -> null
                    else -> "pos:$pos"
                }
                if (key == null) { out += single(seat, pawn, center); continue }
                groups.getOrPut(pos) { mutableListOf() }.add(Entry(seat, pawn, center))
            }
        }

        for ((pos, entries) in groups) {
            val safe = LudoRules.SAFE_INDICES.contains(pos)
            val unit = layout.unit
            if (!safe && entries.size == 2 && entries.all { it.seat == entries[0].seat }) {
                // Same-colour block: 82%, offset perpendicular to travel (±0.14 cellSide).
                val dir = travelDirection(entries[0].seat, pos)
                val perp = Offset(-dir.y, dir.x)
                val off = 0.14f * unit
                out += PlacedPawn(entries[0].seat, entries[0].pawn,
                    entries[0].center + (perp * -off), 0.82f)
                out += PlacedPawn(entries[1].seat, entries[1].pawn,
                    entries[1].center + (perp * off), 0.82f)
            } else if (entries.size > 1) {
                // Safe-cell coexistence (any colours): 2×2 fan at 68%.
                entries.forEachIndexed { i, e ->
                    val dx = if (i % 2 == 0) -1f else 1f
                    val dy = if (i < 2) -1f else 1f
                    val off = 0.16f * unit
                    out += PlacedPawn(e.seat, e.pawn,
                        e.center + Offset(dx * off, dy * off), 0.68f, overlapsLegalPeer = true)
                }
            } else {
                val e = entries.first()
                out += single(e.seat, e.pawn, e.center)
            }
        }

        // One display pawn may be mid-hop; it wins its slot visually.
        displayOverride?.let { ov ->
            val seatOv = ov.first
            val pawnIdx = ov.second
            val centerOv = ov.third
            return out.map {
                if (it.seat == seatOv && it.pawnIndex == pawnIdx) it.copy(center = centerOv) else it
            }.sortedBy { it.seat * 10 + it.pawnIndex }
        }
        return out.sortedBy { it.seat * 10 + it.pawnIndex }
    }

    private fun single(seat: Int, pawn: Int, center: Offset, finished: Boolean = false): PlacedPawn =
        PlacedPawn(seat, pawn, center, if (finished) 0.52f else 1f)

    private fun centerRect(layout: LudoBoardGeometry.Layout): Rect {
        val a = layout.rectOf(LudoBoardGeometry.cell(6, 6))
        val b = layout.rectOf(LudoBoardGeometry.cell(8, 8))
        return Rect(a.left, a.top, b.right, b.bottom)
    }

    /** Travel direction at an absolute track position for a seat's clockwise route. */
    fun travelDirection(seat: Int, pos: Int): Offset {
        val next = (LudoRules.progressOf(pos, seat) + 1) % LudoRules.TRACK_COUNT
        val curCoord = LudoBoardGeometry.TRACK_COORDS[pos]
        val absNext = (LudoRules.startIndex(seat) + next) % LudoRules.TRACK_COUNT
        val nCoord = LudoBoardGeometry.TRACK_COORDS[absNext]
        val dx = (nCoord.first - curCoord.first).toFloat()
        val dy = (nCoord.second - curCoord.second).toFloat()
        val len = kotlin.math.sqrt(dx * dx + dy * dy).coerceAtLeast(0.001f)
        return Offset(dx / len, dy / len)
    }

    /**
     * Hit-test: resolve ONLY among server-legal tokens (§17). Returns the lowest legal token
     * whose hit circle contains the point, plus whether any other legal pawn overlaps it
     * (which opens the compact token chooser anchored to the cell).
     */
    fun hitTest(
        placed: List<PlacedPawn>,
        unit: Float,
        x: Float,
        y: Float,
        legalPawns: Set<Pair<Int, Int>>,
    ): Pair<Int, Int>? {
        val radius = 0.5f * unit.coerceAtLeast(24f)
        var best: Pair<Int, Int>? = null
        for (p in placed.sortedBy { it.seat * 10 + it.pawnIndex }) {
            val key = p.seat to p.pawnIndex
            if (key !in legalPawns) continue
            val dx = x - p.center.x
            val dy = y - p.center.y
            if (dx * dx + dy * dy <= radius * radius && best == null) best = key
        }
        return best
    }
}
