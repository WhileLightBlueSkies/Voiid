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
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.platform.LocalContext
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

    DisposableEffect(Unit) {
        GameAudio.preload(context, "tictactoe")
        onDispose { GameAudio.release("tictactoe") }
    }

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
    // The result line and record panel wait for the win stroke to finish drawing
    // (TICTACTOE_WIN_LINE.md §2.2: the banner is the last beat, not the first). A draw has no
    // stroke to wait for, so it settles immediately.
    var settled by remember { mutableStateOf(false) }

    fun reset() {
        for (i in board.indices) board[i] = null
        finished = false
        winnerSeat = null
        line = null
        botThinking = false
        paused = false
        recorded = false
        settled = false
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
            // A WIN'S SOUND IS NOT PLAYED HERE. `win_line` belongs to the stroke that draws it
            // and fires from TicTacToeBoard on the same beat the stroke starts — 120 ms after
            // the mark lands, not the instant the win is detected.
            return true
        }
        if (board.none { it == null }) {
            finished = true
            winnerSeat = null
            if (!recorded) { scores.add(level, 0); recorded = true }
            // A draw has no stroke, so it keeps its sound and settles here.
            GameAudio.play("chalk_erase", gain = 0.55f)
            settled = true
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
                val before = board.toList()
                board[move] = BOT_SEAT
                TicTacToeSound.boardChanged(before, board.toList(), HUMAN_SEAT)
                settleIfOver()
            }
        }
        botThinking = false
    }

    fun play(cell: Int) {
        if (finished || botThinking || paused || board[cell] != null) return
        val before = board.toList()
        board[cell] = HUMAN_SEAT
        TicTacToeSound.boardChanged(before, board.toList(), HUMAN_SEAT)
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
            settled = settled,
            onLineComplete = { settled = true },
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
    /// True once the win stroke has finished drawing (or immediately on a draw) — what the
    /// result line and record panel key off, rather than [finished] itself.
    settled: Boolean,
    winnerSeat: Int?,
    botThinking: Boolean,
    paused: Boolean,
    level: BotDifficulty,
    record: BotScoreStore.Record,
    onTap: (Int) -> Unit,
    onLineComplete: () -> Unit,
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

            // Shared with the online game so the two modes cannot drift visually.
            TicTacToeBoard(
                board = board,
                line = line,
                enabled = !finished && !botThinking && !paused,
                onTap = onTap,
                isDraw = finished && winnerSeat == null,
                onLineComplete = onLineComplete,
            )

            // `settled` rather than `finished`: the result is announced once the win stroke has
            // been drawn, so the player reads the line and then the verdict instead of both at
            // once. Until then the last in-play status holds.
            val status = when {
                settled && winnerSeat == null -> "Dead heat — nobody could force it"
                settled && winnerSeat == HUMAN_SEAT -> "You win"
                settled -> "Bot wins"
                botThinking -> "Bot is thinking…"
                else -> "Your turn"
            }
            // The result line pops in rather than appearing, so a win feels like an event.
            val statusScale by animateFloatAsState(
                targetValue = if (settled) 1.15f else 1f,
                animationSpec = spring(dampingRatio = 0.4f, stiffness = Spring.StiffnessLow),
                label = "status",
            )
            Text(
                status,
                color = if (settled) VoiidColor.primary else VoiidColor.textSecondary,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = VoiidSpacing.lg)
                    .scale(statusScale),
            )

            // The record card and the buttons moved into MatchEndOverlay (§9.3).
        }

        // GATED ON `settled`, so the win stroke finishes drawing before the verdict
        // speaks — the same rule the online screen follows (§9.2).
        if (settled) {
            MatchEndOverlay(
                result = MatchEndResult.ticTacToe(
                    // A DRAW IS `winnerSeat == null` WITH A FULL BOARD. `settled` only becomes
                    // true once the game has actually resolved, so a null seat here is a draw
                    // rather than a match still in progress.
                    won = winnerSeat?.let { it == HUMAN_SEAT },
                    moves = board.count { it != null },
                    record = "${record.wins}W ${record.draws}D ${record.losses}L",
                ),
                onExit = onExit,
                onPlayAgain = onRestart,
            )
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

