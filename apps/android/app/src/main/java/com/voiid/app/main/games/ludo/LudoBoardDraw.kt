package com.voiid.app.main.games.ludo

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Rect
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.theme.LudoDimens
import com.voiid.app.ui.theme.LudoThemeColors
import com.voiid.app.ui.theme.ludoPaletteFor
import kotlin.math.min

/**
 * Board composition (§3.3). Draw order is fixed:
 *   backing → yard fields → yard pockets → cells → center triangles → safe marks/chevrons →
 *   highlights/previews → pawns → perimeter stroke.
 *
 * Every node draws from ITS OWN rect — never a flattened bitmap — so cells stay addressable
 * for highlight, pulse, hit-test and semantics. Token hit targets are overlays, not drawing.
 */
object LudoBoardDraw {

    fun drawAll(
        scope: DrawScope,
        colors: LudoThemeColors,
        state: LudoGameState,
        placedPawns: List<LudoPawnLayer.PlacedPawn>,
        highlightCells: Set<String>,
        sweep: LudoPresentationCoordinator.BorderSweep?,
        darkTheme: Boolean,
        reduceMotion: Boolean,
    ) = with(scope) {
        val side = size.width
        val layout = LudoBoardGeometry.Layout(side)
        val unit = layout.unit
        val droppedSeats = state.seats.filter { it.isDropped }.map { it.seat }.toSet()

        // 1) Backing.
        drawRoundRect(
            color = LudoBoardDraw.tok(colors.boardSurface),
            topLeft = Offset.Zero,
            size = Size(side, side),
            cornerRadius = CornerRadius(LudoDimens.boardCornerRadius.toPx()),
        )

        // 2+3) Yard fields then pockets.
        for (node in LudoBoardGeometry.CELLS) {
            val r = layout.rectOf(node)
            when (node.role) {
                LudoBoardGeometry.Role.YARD -> {
                    drawRoundRect(yardFill(node, droppedSeats, colors), r.topLeft, r.size, CornerRadius(2f))
                }
                LudoBoardGeometry.Role.YARD_POCKET -> {
                    drawRoundRect(
                        LudoBoardDraw.tok(colors.yardPocket),
                        r.topLeft, r.size,
                        CornerRadius(min(LudoDimens.yardPocketRadiusFactor * unit, r.width / 2f)),
                    )
                }
                else -> Unit
            }
        }

        // 4) Cells (track + lanes + center base + unused), each from its own rect.
        val cellBorderPx = if (darkTheme) LudoDimens.cellBorderDarkDp.dp.toPx()
                           else LudoDimens.cellBorderLightDp.dp.toPx()
        for (node in LudoBoardGeometry.CELLS) {
            if (node.role == LudoBoardGeometry.Role.YARD ||
                node.role == LudoBoardGeometry.Role.YARD_POCKET
            ) continue
            val r = layout.rectOf(node)
            val pressed = false
            with(LudoCellRenderer) {
                node.let { drawCell(it, r, pressed, null, highContrast = false, cellBorderPx, colors) }
            }
        }

        // 5) Center triangles over the 3×3 center region; four meet at its middle.
        val centerRect = Rect(
            layout.rectOf(LudoBoardGeometry.cell(6, 6)).left,
            layout.rectOf(LudoBoardGeometry.cell(6, 6)).top,
            layout.rectOf(LudoBoardGeometry.cell(8, 8)).right,
            layout.rectOf(LudoBoardGeometry.cell(8, 8)).bottom,
        )
        for (seat in 0..3) {
            val path = LudoCellRenderer.centerTrianglePath(seat, centerRect)
            drawPath(path, colors.centerTriangle(seat))
        }

        // 6) Safe marks: stars + owner-hue entry chevrons (Paths, never glyphs).
        for (node in LudoBoardGeometry.CELLS) {
            if (node.decoration == LudoBoardGeometry.Decoration.NONE) continue
            val r = layout.rectOf(node)
            when (node.decoration) {
                LudoBoardGeometry.Decoration.STAR ->
                    drawPath(LudoCellRenderer.safeStarPath(r), LudoBoardDraw.tok(colors.safeCellStar))
                LudoBoardGeometry.Decoration.ENTRY_CHEVRON ->
                    drawPath(
                        LudoCellRenderer.entryChevronPath(r, node.seat ?: node.trackIndex!! / 13),
                        colors.hue(node.trackIndex!! / 13),
                    )
                else -> Unit
            }
        }

        // 7) Highlights/previews: legal-pawn cells breathe ONCE via the coordinator's alpha;
        // here we draw the steady ring the coordinator leaves behind.
        for (node in LudoBoardGeometry.CELLS) {
            if (node.id !in highlightCells) continue
            val r = layout.rectOf(node).inflate(1.5f)
            val hue = highlightHue(state, node, colors)
            drawRoundRect(hue.copy(alpha = 0.45f), r.topLeft, r.size, CornerRadius(3f),
                style = Stroke(2.dp.toPx()))
        }

        // 8) Pawns — blank silhouettes tinted per seat; finished pawns already sit in their
        // triangle slots at 52% via the layer layout.
        for (pawn in placedPawns.sortedBy { it.seat }) {
            val boxW = LudoPawnPath.WIDTH_FACTOR * unit * pawn.scale
            val boxH = LudoPawnPath.HEIGHT_FACTOR * unit * pawn.scale
            translate(pawn.center.x - boxW / 2f, pawn.center.y - boxH / 2f) {
                val hue = colors.hue(pawn.seat)

                // Contact shadow: y=2, blur=3 at rest (§2.2 elevation).
                drawCircle(Color.Black.copy(alpha = 0.14f), radius = boxW * 0.34f,
                    center = Offset(boxW / 2f, boxH * 0.965f))

                drawPath(LudoPawnPath.path(boxW, boxH), hue)
                drawPath(LudoPawnPath.rimPath(boxW, boxH),
                    LudoPawnPath.rimColor(hue, darkTheme),
                    style = Stroke(if (darkTheme) 1f else 0.75f))
                // Rim line across the base at y=0.82H.
                val rimY = 0.82f * boxH
                drawLine(
                    LudoPawnPath.rimColor(hue, darkTheme),
                    Offset(boxW * 0.10f, rimY), Offset(boxW * 0.90f, rimY),
                    strokeWidth = 1f,
                )
                drawPath(LudoPawnPath.highlightArc(boxW, boxH),
                    Color.White.copy(alpha = if (darkTheme) 0.10f else 0.14f),
                    style = Stroke(0.035f * boxW, cap = androidx.compose.ui.graphics.StrokeCap.Round))
            }
        }

        // 9) Perimeter stroke LAST — the turn border sweeps OVER everything (§12).
        val perimeter = roundedPerimeterPath(side, LudoDimens.boardCornerRadius.toPx())
        val strokePx = if (darkTheme) LudoDimens.perimeterStrokeDarkDp.dp.toPx()
                       else LudoDimens.perimeterStrokeLightDp.dp.toPx()
        val restingColor = restingBorderColor(state, colors)
        if (sweep == null || reduceMotion) {
            // Reduced motion changes the full border instantly; no travel (§12.2).
            drawPath(perimeter, sweep?.toColor ?: restingColor, style = Stroke(strokePx))
        } else {
            with(LudoTurnBorder) {
                drawBorder(
                    perimeter, strokePx,
                    baseColor = sweep.fromColor,
                    overlayColor = sweep.toColor,
                    phaseStart = LudoBoardGeometry.BORDER_ANCHORS[sweep.fromSeat],
                    progress = sweep.progress,
                )
            }
        }

        // Game end: border returns to podBorder instantly (§12.1); winner presentation belongs
        // to the result sheet.
        if (state.isFinished) {
            drawPath(perimeter, LudoBoardDraw.tok(colors.podBorder), style = Stroke(strokePx))
        }
    }

    private fun tok(v: Int): Color = Color(v.toULong().toLong().toInt())

    private fun yardFill(node: LudoBoardGeometry.CellNode, dropped: Set<Int>, colors: LudoThemeColors): Color {
        val owner = node.seat ?: return LudoBoardDraw.tok(colors.unusedCellFill)
        return if (owner in dropped) LudoBoardDraw.tok(colors.inactiveYard) else colors.yard(owner)
    }

    private fun highlightHue(state: LudoGameState, node: LudoBoardGeometry.CellNode, colors: LudoThemeColors): Color =
        state.turn?.seat?.let { colors.hue(it) } ?: tok(colors.focusRing)

    /** Steady border color by current state (§12.1). */
    fun restingBorderColor(state: LudoGameState, colors: LudoThemeColors): Color = when {
        state.status != "active" -> LudoBoardDraw.tok(colors.podBorder)
        else -> colors.hue(state.turn?.seat ?: 0)
    }

    fun roundedPerimeterPath(side: Float, cornerRadius: Float): Path =
        Path().apply {
            addRoundRect(
                androidx.compose.ui.geometry.RoundRect(
                    rect = Rect(0f, 0f, side, side),
                    cornerRadius = CornerRadius(cornerRadius),
                )
            )
        }
}


