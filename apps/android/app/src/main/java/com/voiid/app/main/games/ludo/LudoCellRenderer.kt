package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.LudoDimens
import com.voiid.app.ui.theme.LudoThemeColors
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * Keyed cell drawing (§3.3). Every node draws itself from ITS OWN rect — highlights, pulses
 * and semantics stay per-cell. Draw order lives in LudoBoard: backing → yards → pockets →
 * cells → center → safe marks → previews/highlights → pawns → perimeter.
 */
object LudoCellRenderer {

    fun cellFill(node: LudoBoardGeometry.CellNode, colors: LudoThemeColors): Color = when (node.role) {
        LudoBoardGeometry.Role.SHARED_TRACK ->
            if (node.isSafe) colors.c(colors.safeCellFill) else colors.c(colors.trackCellFill)
        LudoBoardGeometry.Role.HOME_LANE -> colors.homeLane(node.seat ?: 0)
        LudoBoardGeometry.Role.CENTER, LudoBoardGeometry.Role.UNUSED -> colors.c(colors.unusedCellFill)
        else -> colors.c(colors.trackCellFill)
    }

    /** Yard fields tint with their owner hue; a DROPPED seat desaturates to inactiveYard (§13). */
    fun yardFill(node: LudoBoardGeometry.CellNode, droppedSeats: Set<Int>, colors: LudoThemeColors): Color {
        val owner = node.seat ?: return colors.c(colors.unusedCellFill)
        return colors.yard(owner)
    }

    fun DrawScope.drawCell(
        node: LudoBoardGeometry.CellNode,
        rect: Rect,
        pressed: Boolean,
        highlight: Color?,
        highContrast: Boolean,
        cellBorderPx: Float,
        colors: LudoThemeColors,
    ) {
        val radius = min(LudoDimens.cellCornerRadiusFactor * rect.width, 2.dp.toPx())
        val fill = if (pressed) colors.c(colors.trackCellPressed) else cellFill(node, colors)
        drawRoundRect(
            color = fill,
            topLeft = rect.topLeft,
            size = rect.size,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
        )
        // Cell rule line; high contrast raises it (§17).
        val border = if (highContrast) 1.5.dp.toPx() else cellBorderPx
        drawRoundRect(
            color = colors.c(colors.trackCellBorder),
            topLeft = rect.topLeft,
            size = rect.size,
            cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
            style = Stroke(width = border),
        )
        highlight?.let {
            drawRoundRect(
                color = it,
                topLeft = rect.topLeft,
                size = rect.size,
                cornerRadius = androidx.compose.ui.geometry.CornerRadius(radius),
                style = Stroke(width = 2.5.dp.toPx()),
            )
        }
    }

    /**
     * Safe decorations are Paths, never glyphs (§1): five-point star on 8/21/34/47, filled
     * directional chevron in the owner hue on the four entries.
     */
    fun safeStarPath(rect: Rect): Path {
        val outer = 0.34f * rect.width
        val inner = 0.15f * rect.width
        val cx = rect.center.x
        val cy = rect.center.y
        val path = Path()
        for (i in 0 until 10) {
            val angle = Math.PI / 2 + i * Math.PI / 5      // point up
            val r = if (i % 2 == 0) outer else inner
            val px = cx + (r * cos(angle)).toFloat()
            val py = cy - (r * sin(angle)).toFloat()
            if (i == 0) path.moveTo(px, py) else path.lineTo(px, py)
        }
        path.close()
        return path
    }

    /**
     * Chevron pointing INTO the seat's route direction. The entry cells sit just after each
     * corner turn; the chevron faces along the travel direction of that seat's first step.
     */
    fun entryChevronPath(rect: Rect, seat: Int): Path {
        // Travel direction entering the board at this seat's start index.
        val dir = when (seat) {
            0 -> Offset(0f, -1f)   // red start (6,13), travels upward
            1 -> Offset(1f, 0f)    // green start (1,6), travels rightward
            2 -> Offset(0f, 1f)    // yellow start (8,1), travels downward
            else -> Offset(-1f, 0f)
        }
        val size = rect.width * 0.38f
        val c = rect.center
        val tip = Offset(c.x + dir.x * size * 0.6f, c.y + dir.y * size * 0.6f)
        val perp = Offset(-dir.y, dir.x)
        val backL = Offset(tip.x - dir.x * size - perp.x * size * 0.8f,
                           tip.y - dir.y * size - perp.y * size * 0.8f)
        val backR = Offset(tip.x - dir.x * size + perp.x * size * 0.8f,
                           tip.y - dir.y * size + perp.y * size * 0.8f)
        return Path().apply {
            moveTo(backL.x, backL.y)
            lineTo(tip.x, tip.y)
            lineTo(backR.x, backR.y)
        }
    }

    /** Center triangles: green from left, yellow from top, blue from right, red from bottom. */
    fun centerTrianglePath(seat: Int, centerRect: Rect): Path {
        val l = centerRect.left; val t = centerRect.top
        val r = centerRect.right; val b = centerRect.bottom
        val cx = centerRect.center.x; val cy = centerRect.center.y
        return Path().apply {
            when (seat % 4) {
                1 -> { moveTo(l, t); lineTo(l, b); lineTo(cx, cy) }          // green from left
                2 -> { moveTo(l, t); lineTo(r, t); lineTo(cx, cy) }          // yellow from top
                3 -> { moveTo(r, t); lineTo(r, b); lineTo(cx, cy) }          // blue from right
                else -> { moveTo(l, b); lineTo(r, b); lineTo(cx, cy) }       // red from bottom
            }
            close()
        }
    }

    /** The 2×2 finish slots inside each triangle; a finished pawn shrinks into one at 52%. */
    fun finishSlotRect(seat: Int, pawnIndex: Int, centerRect: Rect): Rect {
        val unit = centerRect.width / 3f
        val slot = LudoBoardGeometry.FINISH_SLOTS[seat % 4][pawnIndex % 4]
        val left = centerRect.left + slot.first * unit - unit * .26f
        val top = centerRect.top + slot.second * unit - unit * .26f
        return Rect(left, top, left + unit * .52f, top + unit * .52f)
    }
}
