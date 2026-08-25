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
    /**
     * "seat:pawn" keys for every token the CURRENT roll can legally move. Empty between turns,
     * so nothing glows while there is no decision to make.
     */
    fun activePawnKeys(state: LudoGameState): Set<String> {
        val turn = state.turn ?: return emptySet()
        if (state.isFinished || turn.phase != "awaitingMove") return emptySet()
        return turn.legalTokenIds.map { "${'$'}{turn.seat}:${'$'}it" }.toSet()
    }


    fun drawAll(
        scope: DrawScope,
        colors: LudoThemeColors,
        state: LudoGameState,
        placedPawns: List<LudoPawnLayer.PlacedPawn>,
        highlightCells: Set<String>,
        sweep: LudoPresentationCoordinator.BorderSweep?,
        darkTheme: Boolean,
        reduceMotion: Boolean,
        highContrast: Boolean = false,
        /** Advances the marching dashes on playable tokens. */
        dashPhase: Float = 0f,
        /** 0..1 of the active seat's decision window still remaining; null hides the clock. */
        timerFraction: Float? = null,
        /** Warning / critical tint for the last seconds; null keeps the seat hue. */
        timerTint: Color? = null,
    ) = with(scope) {
        val side = size.width
        val layout = LudoBoardGeometry.Layout(side)
        val unit = layout.unit
        val droppedSeats = emptySet<Int>()

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
                    drawRect(yardFill(node, droppedSeats, colors), r.topLeft, r.size)
                }
                else -> Unit
            }
        }
        for (seat in 0..3) {
            val origin = when (seat) { 0 -> 0 to 9; 1 -> 0 to 0; 2 -> 9 to 0; else -> 9 to 9 }
            val inset = unit * .80f
            val topLeft = Offset(origin.first * unit + inset, origin.second * unit + inset)
            val pocketSize = Size(unit * 4.4f, unit * 4.4f)
            drawRoundRect(tok(colors.yardPocket), topLeft, pocketSize, CornerRadius.Zero)
            drawRoundRect(tok(colors.yardPocketBorder), topLeft, pocketSize, CornerRadius.Zero,
                style = Stroke(maxOf(.75.dp.toPx(), unit * .04f)))

            // Four resting circles, one per pawn, ringed on the pocket centre. They give a pawn
            // in the yard somewhere to SIT rather than float, and stay legible when the slot is
            // empty — the same read as the seat rings in Ludo King.
            val slotRadius = unit * LudoDimens.yardSlotRadiusFactor
            val seatHue = colors.yard(seat)
            for (pawn in 0..3) {
                val (cx, cy) = layout.yardSlotCenter(seat, pawn)
                drawCircle(seatHue.copy(alpha = .16f), slotRadius, Offset(cx, cy))
                drawCircle(seatHue, slotRadius, Offset(cx, cy),
                    style = Stroke(maxOf(.75.dp.toPx(), unit * .045f)))
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
                node.let { drawCell(it, r, pressed, null, highContrast, cellBorderPx, colors) }
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
                    drawPath(LudoCellRenderer.safeStarPath(r), LudoBoardDraw.tok(colors.safeCellStar),
                        style = Stroke(maxOf(1.dp.toPx(), unit * .055f)))
                LudoBoardGeometry.Decoration.APPROACH_CHEVRON ->
                    drawPath(
                        LudoCellRenderer.entryChevronPath(r, node.seat ?: 0),
                        colors.yard(node.seat ?: 0),
                        style = Stroke(unit * .10f, cap = androidx.compose.ui.graphics.StrokeCap.Round,
                            join = androidx.compose.ui.graphics.StrokeJoin.Round),
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

        // 8) Pawns — pin silhouettes tinted per seat; finished pawns already sit in their
        // triangle slots at 52% via the layer layout.
        //
        // A token is ACTIVE when the current roll could actually be played with it. That is the
        // server's legal set, never a guess: the glow is a promise that tapping does something.
        val activeTokens = activePawnKeys(state)
        // Playable tokens paint LAST so they sit over anything sharing their cell — a token you
        // can act on must never be buried under one you cannot.
        val orderedPawns = placedPawns.sortedWith(
            compareBy({ activeTokens.contains("${'$'}{it.seat}:${'$'}{it.pawnIndex}") }, { it.seat }),
        )
        for (pawn in orderedPawns) {
            val isActive = activeTokens.contains("${'$'}{pawn.seat}:${'$'}{pawn.pawnIndex}")
            val scale = pawn.scale * (if (isActive) LudoPawnPath.ACTIVE_SCALE else 1f)
            val boxW = LudoPawnPath.WIDTH_FACTOR * unit * scale
            val boxH = LudoPawnPath.HEIGHT_FACTOR * unit * scale
            with(LudoPawnPath) {
                drawPawn(
                    origin = Offset(pawn.center.x - boxW / 2f, pawn.center.y - boxH / 2f),
                    width = boxW,
                    height = boxH,
                    hue = colors.hue(pawn.seat),
                    active = isActive,
                    colors = colors,
                    dashPhase = dashPhase,
                )
            }
        }

        // 9) Perimeter stroke LAST — the turn border sweeps OVER everything (§12).
        val perimeter = roundedPerimeterPath(side, LudoDimens.boardCornerRadius.toPx())
        val strokePx = if (darkTheme) LudoDimens.perimeterStrokeDarkDp.dp.toPx()
                       else LudoDimens.perimeterStrokeLightDp.dp.toPx()
        val restingColor = restingBorderColor(state, colors)
        if (sweep == null || reduceMotion) {
            // The perimeter IS the clock. It carries the active seat's hue and shortens from
            // that seat's own anchor as their window runs down, so who is on the clock and how
            // long they have left are one signal instead of two (§12.1). Reduced motion lands
            // here too: the border stops shortening smoothly, it never disappears.
            val seat = state.turn?.seat ?: 0
            val hue = timerTint ?: (sweep?.toColor ?: restingColor)
            if (timerFraction == null || state.isFinished || state.turn == null) {
                drawPath(perimeter, hue, style = Stroke(strokePx))
            } else {
                // The spent part stays as a dim track so the board never loses its outline. It
                // uses the pod ring's track token, not the cell-border token, which is near-black
                // and read as a hard shadow down one edge of the board.
                drawPath(perimeter, LudoBoardDraw.tok(colors.timerTrack), style = Stroke(strokePx))
                val remaining = timerFraction.coerceIn(0f, 1f)
                if (remaining > 0.001f) {
                    with(LudoTurnBorder) {
                        drawArc(perimeter, strokePx, hue,
                            LudoBoardGeometry.BORDER_ANCHORS[seat % 4], remaining)
                    }
                }
            }
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
            drawPath(perimeter, LudoBoardDraw.tok(colors.trackCellBorder), style = Stroke(strokePx))
        }
    }

    private fun tok(v: Int): Color = Color(v.toULong().toLong().toInt())

    private fun yardFill(node: LudoBoardGeometry.CellNode, dropped: Set<Int>, colors: LudoThemeColors): Color {
        val owner = node.seat ?: return LudoBoardDraw.tok(colors.unusedCellFill)
        return colors.yard(owner)
    }

    private fun highlightHue(state: LudoGameState, node: LudoBoardGeometry.CellNode, colors: LudoThemeColors): Color =
        state.turn?.seat?.let { colors.hue(it) } ?: tok(colors.focusRing)

    /** Steady border color by current state (§12.1). */
    fun restingBorderColor(state: LudoGameState, colors: LudoThemeColors): Color = when {
        state.status != "active" || state.turn == null -> LudoBoardDraw.tok(colors.trackCellBorder)
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
