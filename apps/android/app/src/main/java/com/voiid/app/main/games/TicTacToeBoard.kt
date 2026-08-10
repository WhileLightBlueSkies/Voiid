package com.voiid.app.main.games

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.EaseOutCubic
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberUpdatedState
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.lerp
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.voiid.app.ui.components.VoiidHaptics
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay
import kotlin.math.hypot

/**
 * The 3x3 board, shared by the online game (server state) and the bot game (local state).
 *
 * EXTRACTED so the two modes cannot drift visually — the counterpart to iOS
 * `TicTacToeBoard.swift`, which was extracted for the same reason and left Android's board
 * inline in two screens (docs/games/TICTACTOE.md §2.5). The win line is needed by both screens,
 * which is what finally made two copies untenable.
 *
 * It takes plain values, not an engine: it has no idea whether the marks came from a server
 * frame or a minimax search, which is exactly the point — one board, two callers.
 *
 * THE BOARD OWNS THE END-OF-MATCH BEATS, not its callers (docs/games/TICTACTOE_WIN_LINE.md
 * §2.2). The win line, the swell of the winning cells, the success haptic and the win sound all
 * have to land in a specific order a fifth of a second apart, and a sequence split across two
 * screens is a sequence that drifts. Callers hand over [line] and are told when the gesture has
 * finished, via [onLineComplete].
 *
 * @param board 9 cells, row-major; each is the seat index that owns it, or null.
 * @param line the winning triple to strike through, if the game is won.
 * @param isDraw the match ended with no winner. Deliberately a separate input rather than
 *   "finished && line == null", because the board cannot see `finished` and guessing a draw
 *   from an absent line would treat every match in progress as a draw.
 * @param enabled false when taps should be ignored (not your turn, game over, paused).
 * @param onLineComplete fired when the win stroke has finished drawing — the cue for a caller
 *   to reveal its result panel, so the banner does not land on top of the gesture that
 *   explains it.
 */
@Composable
fun TicTacToeBoard(
    board: List<Int?>,
    line: List<Int>?,
    enabled: Boolean,
    onTap: (Int) -> Unit,
    modifier: Modifier = Modifier,
    isDraw: Boolean = false,
    onLineComplete: (() -> Unit)? = null,
) {
    val context = LocalContext.current
    val haptics = remember(context) { VoiidHaptics(context) }
    // Reduce-motion draws the line at full length instantly (§2.5). The colour, the sound and
    // the haptic all survive; only the stroke animation is dropped. The information is the
    // point — the motion was only ever how it was delivered.
    val reduceMotion = remember(context) { ReduceMotion.isEnabled(context) }

    /** How much of the win stroke is drawn, 0-1. */
    val strokeProgress = remember { Animatable(0f) }
    /** The winning cells swell only once the stroke has landed — the payoff, not the event. */
    var swelled by remember { mutableStateOf(false) }
    // Held in an updated state so the sequence below always calls the CURRENT callback even if
    // the caller recomposed with a new lambda mid-animation.
    val onComplete by rememberUpdatedState(onLineComplete)

    // The end-of-match sequence, in the order §2.2 specifies:
    //
    //     0 ms    final mark lands, mark sound plays (the caller's board diff does this)
    //     120 ms  hold expires — stroke begins, win sound starts with it
    //     460 ms  stroke complete, winning cells swell, success haptic
    //     560 ms  caller reveals its result panel
    LaunchedEffect(line) {
        if (line == null) {
            strokeProgress.snapTo(0f)
            swelled = false
            return@LaunchedEffect
        }
        if (reduceMotion) {
            strokeProgress.snapTo(1f)
            swelled = true
            GameAudio.play("win_line", gain = 0.7f)
            haptics.success()
            onComplete?.invoke()
            return@LaunchedEffect
        }
        // 120 ms hold. Let the player SEE the third mark before it is annotated: firing the
        // line on the same frame as the winning mark makes the two read as one blurred event,
        // and the player never registers which move won. The most important number in the file.
        delay(WIN_LINE_HOLD_MS)
        // Sound and stroke start on the SAME beat: the scrape is the stroke, and a scrape that
        // outlasts the line reads as broken without the player knowing why.
        GameAudio.play("win_line", gain = 0.7f)
        strokeProgress.animateTo(
            1f,
            animationSpec = tween(WIN_LINE_DURATION_MS, easing = EaseOutCubic),
        )
        // ON COMPLETION, not on start (§2.4): the haptic is the full stop at the end of the
        // gesture, and firing it at the beginning would confirm a win the player has not been
        // shown yet.
        haptics.success()
        swelled = true
        onComplete?.invoke()
    }

    // Every cell desaturates together on a draw (§2.3) — a draw is the EXPECTED outcome between
    // competent players and had been sharing the loss treatment, which said nothing.
    val drawFade by animateFloatAsState(
        targetValue = if (isDraw) 1f else 0f,
        animationSpec = tween(if (reduceMotion) 0 else DRAW_FADE_MS),
        label = "drawFade",
    )

    Box(modifier) {
        Column(
            Modifier.fillMaxWidth().alpha(1f - drawFade * 0.30f),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            for (row in 0 until 3) {
                Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    for (col in 0 until 3) {
                        val index = row * 3 + col
                        Cell(
                            mark = board.getOrNull(index),
                            isWinning = line?.contains(index) == true && swelled,
                            enabled = enabled && board.getOrNull(index) == null,
                            index = index,
                            fade = drawFade,
                            onTap = { onTap(index) },
                            modifier = Modifier.weight(1f),
                        )
                    }
                }
            }
        }

        // The stroke, drawn OVER the grid and sized to it, so cell centres fall out of the same
        // spacing constant the layout above uses.
        if (line != null && line.size == 3) {
            WinLine(
                line = line,
                board = board,
                progress = strokeProgress.value,
                spacing = VoiidSpacing.sm,
                modifier = Modifier.matchParentSize(),
            )
        }
    }
}

// MARK: Timing and geometry (TICTACTOE_WIN_LINE.md §2.1-2.2)
//
// KEEP IDENTICAL TO iOS `TicTacToeBoard.swift`. Divergence here is how two ports of one feature
// end up feeling like different games.

/** Let the player see the winning mark before it is annotated. */
private const val WIN_LINE_HOLD_MS = 120L
/** Long enough to read as a deliberate stroke, short enough not to delay the result. */
private const val WIN_LINE_DURATION_MS = 340
/**
 * Extend past the outer two centres by this fraction of a cell, so the line visibly strikes
 * THROUGH the row rather than connecting two dots. Matters most on the diagonals, where the
 * un-extended line is visually shortest relative to what it crosses.
 */
private const val WIN_LINE_OVERSHOOT = 0.35f
/** The line must dominate the marks it crosses, not match them. Marks stroke at 0.14 * cell. */
private const val WIN_LINE_WIDTH_SCALE = 1.4f
private const val MARK_STROKE_SCALE = 0.14f
private const val DRAW_FADE_MS = 300
/** Where a drawn match's marks end up: neutral, still legible, no longer anyone's colour. */
private val DRAW_NEUTRAL = Color(0xFF8A8A8A)

/**
 * The stroke through the winning triple.
 *
 * A stroke that appears at full length is a graphic; a stroke that is DRAWN is a gesture, and
 * this is a game about marking a board by hand. Compose has no `.trim`, so the end point is
 * lerped along the line instead — for a straight segment that is exactly equivalent and avoids
 * building a PathMeasure every frame.
 */
@Composable
private fun WinLine(
    line: List<Int>,
    board: List<Int?>,
    progress: Float,
    spacing: Dp,
    modifier: Modifier = Modifier,
) {
    // The winner's own mark colour, at full saturation — so the stroke says WHO won in the same
    // gesture that says that someone won.
    val colour = if (board.getOrNull(line[0]) == 0) VoiidColor.primary else VoiidColor.accent

    Canvas(modifier) {
        val gap = spacing.toPx()
        // Cells are square with equal gaps, so one axis defines both — deriving y from the
        // height instead would drift by a rounding error and tilt the diagonals.
        val cell = (size.width - gap * 2f) / 3f

        fun centre(index: Int) = Offset(
            (index % 3) * (cell + gap) + cell / 2f,
            (index / 3) * (cell + gap) + cell / 2f,
        )

        val a = centre(line[0])
        val b = centre(line[2])
        val dx = b.x - a.x
        val dy = b.y - a.y
        val length = hypot(dx, dy).coerceAtLeast(0.0001f)
        val reach = cell * WIN_LINE_OVERSHOOT
        val start = Offset(a.x - dx / length * reach, a.y - dy / length * reach)
        val end = Offset(b.x + dx / length * reach, b.y + dy / length * reach)

        if (progress <= 0f) return@Canvas
        drawLine(
            color = colour,
            start = start,
            end = Offset(
                start.x + (end.x - start.x) * progress,
                start.y + (end.y - start.y) * progress,
            ),
            strokeWidth = cell * MARK_STROKE_SCALE * WIN_LINE_WIDTH_SCALE,
            cap = StrokeCap.Round,
        )
    }
}

@Composable
private fun Cell(
    mark: Int?,
    isWinning: Boolean,
    enabled: Boolean,
    index: Int,
    /// 0 in play, 1 fully drawn-out. Lerps the mark toward neutral for the draw treatment.
    fade: Float,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Marks land with an overshoot — the "bouncy" feel. Keyed on the mark so it replays per
    // placement rather than once per screen.
    val pop by animateFloatAsState(
        targetValue = if (mark != null) 1f else 0.4f,
        animationSpec = spring(dampingRatio = 0.42f, stiffness = Spring.StiffnessMediumLow),
        label = "pop",
    )
    // The winning triple swells — but only AFTER the stroke has been drawn, so it reads as the
    // payoff to the gesture rather than competing with it.
    val winScale by animateFloatAsState(
        targetValue = if (isWinning) 1.08f else 1f,
        animationSpec = spring(dampingRatio = 0.35f, stiffness = Spring.StiffnessLow),
        label = "win",
    )

    Box(
        modifier
            .aspectRatio(1f)
            .scale(winScale)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(if (isWinning) VoiidColor.primary.copy(alpha = 0.20f) else VoiidColor.surfaceCard)
            .clickable(enabled = enabled) { onTap() }
            .semantics { contentDescription = ticTacToeCellLabel(mark, index) },
        contentAlignment = Alignment.Center,
    ) {
        if (mark != null) {
            val base = if (mark == 0) VoiidColor.primary else VoiidColor.accent
            val tint = lerp(base, DRAW_NEUTRAL, fade * 0.85f)
            // Drawn rather than icon glyphs: a stroked X and O scale cleanly with the cell and
            // give the crossing-style look that a font glyph cannot. This is also what lets the
            // win line share a visual language with the marks it crosses.
            Canvas(Modifier.fillMaxSize().padding(VoiidSpacing.lg).scale(pop)) {
                val w = size.minDimension
                val width = w * MARK_STROKE_SCALE
                if (mark == 0) {
                    drawLine(tint, Offset(0f, 0f), Offset(w, w), strokeWidth = width, cap = StrokeCap.Round)
                    drawLine(tint, Offset(w, 0f), Offset(0f, w), strokeWidth = width, cap = StrokeCap.Round)
                } else {
                    drawCircle(tint, radius = w / 2f, style = Stroke(width = width, cap = StrokeCap.Round))
                }
            }
        }
    }
}

/** Shared by both Tic Tac Toe screens' accessibility labels. */
internal fun ticTacToeCellLabel(mark: Int?, index: Int): String {
    val position = "row ${index / 3 + 1}, column ${index % 3 + 1}"
    return if (mark == null) "Empty, $position" else "${if (mark == 0) "X" else "O"}, $position"
}
