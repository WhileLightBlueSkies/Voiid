package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * The first game renderer (docs/GAMES.md §4). A dumb view over GamesEngine's state: it
 * draws the board the server sent and reports taps. It contains NO rules — no win check,
 * no turn logic, no "is this cell free". Every one of those is answered by backend/games,
 * and duplicating any of them here is how the two sides drift apart.
 *
 * Plain composables rather than Canvas, on purpose: a 3x3 grid of tappable cells is not a
 * drawing problem, and staying in ordinary composables keeps theme tokens and
 * accessibility for free. Canvas is for the arcade games later.
 *
 * Mirrors iOS `TicTacToeView.swift`.
 */
@Composable
fun TicTacToeScreen(
    matchId: String,
    onClose: () -> Unit,
    /**
     * Open a freshly-minted rematch. Null hides the Rematch button — a caller that cannot
     * navigate to a new match must not offer one.
     */
    onRematch: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    val state by engine.state.collectAsState()
    val joinError by engine.joinError.collectAsState()
    val me = engine.myUserId

    DisposableEffect(Unit) {
        GameAudio.preload(context, "tictactoe")
        onDispose { GameAudio.release("tictactoe") }
    }

    LaunchedEffect(matchId) { engine.open(matchId) }

    // Mark placed. The board only ever GAINS marks mid-match (a cell, once filled, never
    // empties), so diffing against the previously-seen board finds exactly the cell that just
    // changed and its seat (0 = X, 1 = O) picks the sound. The rule lives in TicTacToeSound,
    // shared with the bot screen and mirroring iOS, so a bot move and a human move cannot
    // drift apart.
    var lastBoard by remember { mutableStateOf<List<Int?>?>(null) }
    LaunchedEffect(state?.board) {
        val newBoard = state?.board
        TicTacToeSound.boardChanged(lastBoard, newBoard, state?.players?.indexOf(me)?.takeIf { it >= 0 })
        lastBoard = newBoard
    }

    // The result line waits for the win stroke to finish drawing (TICTACTOE_WIN_LINE.md §2.2:
    // the banner is the last beat, not the first). A draw has no stroke to wait for, so it
    // reveals immediately.
    var resultRevealed by remember { mutableStateOf(false) }

    // A WIN'S SOUND IS NOT PLAYED HERE. `win_line` belongs to the stroke that draws it and
    // fires from TicTacToeBoard on the same beat the stroke starts — 120 ms after the mark
    // lands, not on this state change. A draw has no stroke, so it keeps its sound here.
    var lastFinished by remember { mutableStateOf(false) }
    LaunchedEffect(state?.finished) {
        val finished = state?.finished == true
        if (finished && !lastFinished && state?.winnerUserId == null) {
            GameAudio.play("chalk_erase", gain = 0.55f)
            resultRevealed = true
        }
        lastFinished = finished
    }

    Column(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            // Full-screen cover drawn edge to edge; without this the header sits under
            // the clock and battery.
            .statusBarsPadding()
            .padding(horizontal = VoiidSpacing.lg),
    ) {
        // Header
        Row(
            Modifier.fillMaxWidth().padding(top = VoiidSpacing.md),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Icon(
                Icons.AutoMirrored.Filled.ArrowBack,
                contentDescription = "Back",
                tint = VoiidColor.textPrimary,
                modifier = Modifier.clickable { engine.leave(); onClose() },
            )
            Text(
                "Tic Tac Toe",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = androidx.compose.ui.text.style.TextAlign.Center,
            )
            // Balances the back arrow so the title stays optically centred.
            Box(Modifier.size(24.dp))
        }

        val s = state
        when {
            s != null -> {
                val isMyTurn = !s.finished && s.turnUserId == me

                // Shared with the bot game so the two modes cannot drift visually. Taps are
                // disabled unless it is genuinely my turn — the server would reject them
                // anyway, so this only avoids sending frames we know are pointless.
                TicTacToeBoard(
                    board = s.board,
                    line = s.line,
                    enabled = isMyTurn,
                    onTap = { engine.play(context, it) },
                    modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.md),
                    isDraw = s.finished && s.winnerUserId == null,
                    onLineComplete = { resultRevealed = true },
                )

                // `settled` rather than `s.finished`: the result is announced once the win
                // stroke has been drawn, so the player reads the line and then the verdict
                // instead of both at once. Until then the last in-play status holds.
                val settled = s.finished && resultRevealed
                val status = when {
                    settled && s.winnerUserId == null -> "Dead heat — nobody could force it"
                    settled && s.winnerUserId == me -> "You win"
                    settled -> "You lose"
                    isMyTurn -> "Your turn"
                    else -> "Their turn"
                }
                Text(
                    status,
                    color = if (settled) VoiidColor.primary else VoiidColor.textSecondary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = VoiidSpacing.md),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )

                // Appears only once the result has SETTLED, so it arrives after the win stroke
                // rather than competing with it.
                if (settled && onRematch != null) {
                    RematchBar(
                        matchId = matchId,
                        onRematch = { newId ->
                            // Leave the old match first — the engine holds one at a time.
                            engine.leave()
                            onRematch(newId)
                        },
                        onExit = { engine.leave(); onClose() },
                    )
                }
            }

            joinError != null -> {
                // Truthful failure rather than an empty board that will never fill in.
                Text(
                    joinError ?: "",
                    color = VoiidColor.error,
                    fontSize = 15.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.xl),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
            }

            else -> {
                // The opening board is built by the server and arrives as a frame, so there
                // is a real (brief) waiting state here.
                Column(
                    Modifier.fillMaxWidth().padding(top = VoiidSpacing.xl),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                    Text(
                        "Setting up the board…",
                        color = VoiidColor.textSecondary,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(top = VoiidSpacing.sm),
                    )
                }
            }
        }
    }
}
