package com.voiid.app.main.games

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.animation.scaleOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.scale
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlin.random.Random
import kotlinx.coroutines.delay

/**
 * Practice against the local bot. No server, no match row, no connection needed.
 *
 * THREE PHASES, NOT ONE SCREEN: pick difficulty → play → result. Difficulty is chosen up
 * front and LOCKED for the match, which is what makes a result meaningful — a record of
 * "beat the hard bot" is worthless if the slider could be dragged to easy mid-game. To
 * change it you finish or abandon the match, which is exactly the honest cost.
 *
 * Mirrors iOS `TicTacToeBotView.swift`.
 */
private const val HUMAN_SEAT = 0
private const val BOT_SEAT = 1

/**
 * Difficulty arrives already chosen from [GameSetupSheet] and is LOCKED for the match —
 * a record of "beat the hard bot" is worthless if it could be lowered mid-game.
 */
@Composable
fun TicTacToeBotScreen(level: BotDifficulty, skill: Float, onClose: () -> Unit) {
    val context = LocalContext.current
    val scores = remember { BotScoreStore(context) }

    val board = remember { mutableStateListOf<Int?>(null, null, null, null, null, null, null, null, null) }
    var finished by remember { mutableStateOf(false) }
    var winnerSeat by remember { mutableStateOf<Int?>(null) }
    var line by remember { mutableStateOf<List<Int>?>(null) }
    var botThinking by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    var botTurnToken by remember { mutableIntStateOf(0) }
    // Guards against double-counting a result if the composable recomposes after the game
    // ends — a score store that inflates on rotation is worse than no score store.
    var recorded by remember { mutableStateOf(false) }

    fun reset() {
        for (i in board.indices) board[i] = null
        finished = false
        winnerSeat = null
        line = null
        botThinking = false
        paused = false
        recorded = false
    }

    fun settleIfOver(): Boolean {
        val w = TicTacToeBot.winner(board)
        if (w != null) {
            finished = true
            winnerSeat = w
            line = TicTacToeBot.lines.firstOrNull { l ->
                board[l[0]] == w && board[l[1]] == w && board[l[2]] == w
            }
            if (!recorded) { scores.add(level, if (w == HUMAN_SEAT) 1 else -1); recorded = true }
            return true
        }
        if (board.none { it == null }) {
            finished = true
            winnerSeat = null
            if (!recorded) { scores.add(level, 0); recorded = true }
            return true
        }
        return false
    }

    // The bot's reply, after a short randomised pause so its mark doesn't appear in the
    // same frame as yours (which reads as a glitch). Paused games do not think.
    LaunchedEffect(botTurnToken) {
        if (botTurnToken == 0 || !botThinking) return@LaunchedEffect
        delay(Random.nextLong(320, 620))
        if (!finished && !paused) {
            TicTacToeBot.chooseMove(board.toList(), BOT_SEAT, skill)?.let { move ->
                board[move] = BOT_SEAT
                settleIfOver()
            }
        }
        botThinking = false
    }

    fun play(cell: Int) {
        if (finished || botThinking || paused || board[cell] != null) return
        board[cell] = HUMAN_SEAT
        if (settleIfOver()) return
        botThinking = true
        botTurnToken++
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding(),
    ) {
        PlayBoard(
            board = board,
            line = line,
            finished = finished,
            winnerSeat = winnerSeat,
            botThinking = botThinking,
            paused = paused,
            level = level,
            record = scores.record(level),
            onTap = ::play,
            onPause = { paused = true },
            onResume = { paused = false },
            onRestart = { reset() },
            onGiveUp = {
                // Forfeit counts as a loss. A give-up that costs nothing is just a reset
                // button with extra steps.
                if (!finished && !recorded) { scores.add(level, -1); recorded = true }
                onClose()
            },
            onExit = onClose,
        )
    }
}

@Composable
private fun Stat(label: String, value: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text("$value", color = VoiidColor.textPrimary, fontSize = 20.sp, fontWeight = FontWeight.Bold)
        Text(label, color = VoiidColor.textSecondary, fontSize = 12.sp)
    }
}

@Composable
private fun PlayBoard(
    board: List<Int?>,
    line: List<Int>?,
    finished: Boolean,
    winnerSeat: Int?,
    botThinking: Boolean,
    paused: Boolean,
    level: BotDifficulty,
    record: BotScoreStore.Record,
    onTap: (Int) -> Unit,
    onPause: () -> Unit,
    onResume: () -> Unit,
    onRestart: () -> Unit,
    onGiveUp: () -> Unit,
    onExit: () -> Unit,
) {
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier.fillMaxSize().padding(horizontal = VoiidSpacing.lg),
            verticalArrangement = Arrangement.Center,
        ) {
            // Header: difficulty on the left (it is locked, so it is a label not a control),
            // pause on the right.
            Row(
                Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.lg),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    level.label,
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(VoiidColor.fieldFill)
                        .padding(horizontal = VoiidSpacing.md, vertical = 6.dp),
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Filled.Pause,
                    contentDescription = "Pause",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable(enabled = !finished) { onPause() }
                        .padding(VoiidSpacing.sm),
                )
            }

            Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                for (row in 0 until 3) {
                    Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                        for (col in 0 until 3) {
                            val index = row * 3 + col
                            Cell(
                                mark = board[index],
                                isWinning = line?.contains(index) == true,
                                enabled = !finished && !botThinking && !paused && board[index] == null,
                                index = index,
                                onTap = { onTap(index) },
                                modifier = Modifier.weight(1f),
                            )
                        }
                    }
                }
            }

            val status = when {
                finished && winnerSeat == null -> "Draw"
                finished && winnerSeat == HUMAN_SEAT -> "You win"
                finished -> "Bot wins"
                botThinking -> "Bot is thinking…"
                else -> "Your turn"
            }
            // The result line pops in rather than appearing, so a win feels like an event.
            val statusScale by animateFloatAsState(
                targetValue = if (finished) 1.15f else 1f,
                animationSpec = spring(dampingRatio = 0.4f, stiffness = Spring.StiffnessLow),
                label = "status",
            )
            Text(
                status,
                color = if (finished) VoiidColor.primary else VoiidColor.textSecondary,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = VoiidSpacing.lg)
                    .scale(statusScale),
            )

            AnimatedVisibility(
                visible = finished,
                enter = fadeIn() + scaleIn(initialScale = 0.85f,
                    animationSpec = spring(dampingRatio = 0.5f)),
                exit = fadeOut(),
            ) {
                Column {
                    // Your running record at this difficulty — shown after a result,
                    // which is the moment it means something.
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .padding(top = VoiidSpacing.lg)
                            .clip(RoundedCornerShape(VoiidRadius.lg))
                            .background(VoiidColor.surfaceCard)
                            .padding(VoiidSpacing.md),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                    ) {
                        Stat("Won", record.wins)
                        Stat("Drawn", record.draws)
                        Stat("Lost", record.losses)
                    }
                    Row(
                        Modifier.fillMaxWidth().padding(top = VoiidSpacing.sm),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    ) {
                        PillButton("Play again", filled = true, modifier = Modifier.weight(1f)) { onRestart() }
                        PillButton("Exit", filled = false, modifier = Modifier.weight(1f)) { onExit() }
                    }
                }
            }
        }

        // Pause overlay. A scrim over the board rather than a separate screen, so the game
        // is visibly still there — a pause that hides the board reads as having quit.
        AnimatedVisibility(
            visible = paused,
            enter = fadeIn(tween(150)),
            exit = fadeOut(tween(150)),
        ) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(VoiidColor.background.copy(alpha = 0.94f))
                    // Swallows taps so the board underneath cannot be played while paused.
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) {},
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    Modifier.padding(horizontal = VoiidSpacing.xl),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    Text(
                        "Paused",
                        color = VoiidColor.textPrimary,
                        fontSize = 26.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(bottom = VoiidSpacing.md),
                    )
                    MenuButton("Resume", Icons.Filled.PlayArrow, filled = true) { onResume() }
                    MenuButton("Restart", Icons.Filled.Refresh, filled = false) { onRestart() }
                    MenuButton("Give up", Icons.Outlined.Flag, filled = false, danger = true) { onGiveUp() }
                }
            }
        }
    }
}

@Composable
private fun Cell(
    mark: Int?,
    isWinning: Boolean,
    enabled: Boolean,
    index: Int,
    onTap: () -> Unit,
    modifier: Modifier = Modifier,
) {
    // Marks land with an overshoot — the "bouncy" feel. Keyed on the mark so it replays
    // per placement rather than once per screen.
    val pop by animateFloatAsState(
        targetValue = if (mark != null) 1f else 0.4f,
        animationSpec = spring(dampingRatio = 0.42f, stiffness = Spring.StiffnessMediumLow),
        label = "pop",
    )
    // The winning triple pulses up so the win reads instantly.
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
            .semantics { contentDescription = cellLabel(mark, index) },
        contentAlignment = Alignment.Center,
    ) {
        if (mark != null) {
            val tint = if (mark == HUMAN_SEAT) VoiidColor.primary else VoiidColor.accent
            // Drawn rather than icon glyphs: a stroked X and O scale cleanly with the cell
            // and give the crossing-style look that a font glyph cannot.
            androidx.compose.foundation.Canvas(
                Modifier.fillMaxSize().padding(VoiidSpacing.lg).scale(pop)
            ) {
                val w = size.minDimension
                val stroke = Stroke(width = w * 0.14f, cap = StrokeCap.Round)
                if (mark == HUMAN_SEAT) {
                    drawLine(tint, Offset(0f, 0f), Offset(w, w),
                        strokeWidth = stroke.width, cap = StrokeCap.Round)
                    drawLine(tint, Offset(w, 0f), Offset(0f, w),
                        strokeWidth = stroke.width, cap = StrokeCap.Round)
                } else {
                    drawCircle(tint, radius = w / 2f, style = stroke)
                }
            }
        }
    }
}

@Composable
private fun PillButton(
    text: String,
    filled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text,
            color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
            fontSize = 14.sp,
            fontWeight = FontWeight.SemiBold,
        )
    }
}

@Composable
private fun MenuButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    val fg = when {
        filled -> VoiidColor.textOnPrimary
        danger -> VoiidColor.error
        else -> VoiidColor.textPrimary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md, horizontal = VoiidSpacing.lg),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(VoiidSpacing.sm))
        Text(text, color = fg, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}

private fun cellLabel(mark: Int?, index: Int): String {
    val position = "row ${index / 3 + 1}, column ${index % 3 + 1}"
    return if (mark == null) "Empty, $position" else "${if (mark == 0) "X" else "O"}, $position"
}
