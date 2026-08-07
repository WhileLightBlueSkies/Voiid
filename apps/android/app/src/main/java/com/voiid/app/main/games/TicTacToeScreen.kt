package com.voiid.app.main.games

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
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.outlined.Clear
import androidx.compose.material.icons.outlined.RadioButtonUnchecked
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
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
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
fun TicTacToeScreen(matchId: String, onClose: () -> Unit) {
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
    // changed and its seat (0 = X, 1 = O) picks the pitch. Mirrors iOS TicTacToeView's
    // identical board-diff approach.
    var lastBoard by remember { mutableStateOf<List<Int?>?>(null) }
    LaunchedEffect(state?.board) {
        val newBoard = state?.board
        val oldBoard = lastBoard
        if (oldBoard != null && newBoard != null && oldBoard.size == newBoard.size) {
            for (i in newBoard.indices) {
                if (oldBoard[i] == null && newBoard[i] != null) {
                    GameAudio.play(if (newBoard[i] == 0) "mark_x" else "mark_o", gain = 0.55f)
                    break   // exactly one cell changes per move; server enforces this
                }
            }
        }
        lastBoard = newBoard
    }

    var lastFinished by remember { mutableStateOf(false) }
    LaunchedEffect(state?.finished) {
        val finished = state?.finished == true
        if (finished && !lastFinished) {
            GameAudio.play(if (state?.winnerUserId == null) "draw" else "win_line", gain = 0.6f)
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

                Column(
                    Modifier.fillMaxWidth().padding(top = VoiidSpacing.md),
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    for (row in 0 until 3) {
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            for (col in 0 until 3) {
                                val index = row * 3 + col
                                val mark = s.board.getOrNull(index)
                                val isWinning = s.line?.contains(index) == true
                                // Disabled unless it is genuinely my turn and the cell is
                                // free. The server would reject the tap anyway — this only
                                // avoids sending a frame we know is pointless.
                                val tappable = isMyTurn && mark == null

                                Box(
                                    Modifier
                                        .weight(1f)
                                        .aspectRatio(1f)
                                        .clip(RoundedCornerShape(VoiidRadius.md))
                                        .background(
                                            if (isWinning) VoiidColor.primary.copy(alpha = 0.18f)
                                            else VoiidColor.surfaceCard
                                        )
                                        .clickable(enabled = tappable) { engine.play(context, index) }
                                        .semantics {
                                            contentDescription = cellLabel(mark, index)
                                        },
                                    contentAlignment = Alignment.Center,
                                ) {
                                    if (mark != null) {
                                        Icon(
                                            if (mark == 0) Icons.Outlined.Clear
                                            else Icons.Outlined.RadioButtonUnchecked,
                                            contentDescription = null,
                                            tint = if (mark == 0) VoiidColor.primary else VoiidColor.accent,
                                            modifier = Modifier.size(34.dp),
                                        )
                                    }
                                }
                            }
                        }
                    }
                }

                val status = when {
                    s.finished && s.winnerUserId == null -> "Draw"
                    s.finished && s.winnerUserId == me -> "You win"
                    s.finished -> "You lose"
                    isMyTurn -> "Your turn"
                    else -> "Their turn"
                }
                Text(
                    status,
                    color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .fillMaxWidth()
                        .padding(top = VoiidSpacing.md),
                    textAlign = androidx.compose.ui.text.style.TextAlign.Center,
                )
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

private fun cellLabel(mark: Int?, index: Int): String {
    val position = "row ${index / 3 + 1}, column ${index % 3 + 1}"
    return if (mark == null) "Empty, $position" else "${if (mark == 0) "X" else "O"}, $position"
}
