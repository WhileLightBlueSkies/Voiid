package com.voiid.app.main.games.ludobot

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.systemBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.zIndex
import androidx.lifecycle.viewmodel.compose.viewModel
import com.voiid.app.ui.theme.VoiidFont

/**
 * Ludo against bots. Port of iOS `Games/Ludo/LudoGameView.swift`.
 *
 * Offline only, deliberately: online Ludo comes back after a stable release, and until then
 * one code path is easier to keep honest than two.
 */
@Composable
fun LudoBotScreen(
    difficulty: String = "easy",
    onClose: () -> Unit,
    onOpenSettings: () -> Unit = {},
) {
    val game: LudoGame = viewModel()
    val reduceMotion = com.voiid.app.ui.components.reduceMotionEnabled()
    val context = androidx.compose.ui.platform.LocalContext.current

    LaunchedEffect(context) { game.haptics = LudoBotHaptics(context) }

    var showSetup by remember { mutableStateOf(false) }
    var confirmQuit by remember { mutableStateOf(false) }
    var confirmRestart by remember { mutableStateOf(false) }
    var started by remember { mutableStateOf(false) }
    var showSettings by remember { mutableStateOf(false) }

    LaunchedEffect(reduceMotion) { game.reduceMotion = reduceMotion }

    LaunchedEffect(Unit) {
        if (game.winner == null && !started) {
            game.start(humans = 1, difficulty = difficulty)
            started = true
        }
    }

    DisposableEffect(Unit) { onDispose { game.stop() } }

    LaunchedEffect(game.winner) {
        if (game.winner != null) {
            kotlinx.coroutines.delay(1500)
            showSetup = true
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(LudoTheme.backdrop),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .systemBarsPadding()
                .widthIn(max = 620.dp)
                .align(Alignment.TopCenter),
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            // Header. The buttons carry their own 48dp target, so the row sits flush and
            // only the board and controls take the side margin.
            Row(
                Modifier.fillMaxWidth().padding(horizontal = 4.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = { if (showSetup) onClose() else confirmQuit = true }) {
                    Icon(
                        Icons.AutoMirrored.Filled.ArrowBack,
                        contentDescription = "Quit match",
                        tint = LudoTheme.cream,
                    )
                }
                Spacer(Modifier.weight(1f))
                IconButton(onClick = { confirmRestart = true }) {
                    Icon(
                        Icons.Filled.Refresh,
                        contentDescription = "Restart match",
                        tint = LudoTheme.cream,
                    )
                }
                IconButton(onClick = { showSettings = true; onOpenSettings() }) {
                    Icon(
                        Icons.Filled.Settings,
                        contentDescription = "Game settings",
                        tint = LudoTheme.muted,
                    )
                }
            }

            SeatRail(game, Modifier.padding(horizontal = 12.dp))

            // The board is the screen: it takes the space left over rather than being
            // squeezed by everything stacked around it.
            Box(
                Modifier
                    .weight(1f)
                    .fillMaxWidth()
                    .padding(horizontal = 12.dp),
                contentAlignment = Alignment.Center,
            ) {
                LudoBoard(game)
            }

            Controls(game, Modifier.padding(horizontal = 12.dp))
            Spacer(Modifier.height(10.dp))
        }

        if (showSetup) {
            SetupOverlay(
                winner = game.winner,
                onPick = { picked ->
                    game.start(humans = 1, difficulty = picked)
                    showSetup = false
                },
                onClose = onClose,
            )
        }
    }

    if (showSettings) {
        com.voiid.app.main.games.GameSettingsSheet(onDismiss = { showSettings = false })
    }

    if (confirmRestart) {
        AlertDialog(
            onDismissRequest = { confirmRestart = false },
            title = { Text("Restart match?") },
            text = { Text("This will reset the board and start a new match.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmRestart = false
                    game.restart()
                }) {
                    Text("Restart match", color = androidx.compose.ui.graphics.Color(0xFFE53935))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmRestart = false }) { Text("Keep playing") }
            },
        )
    }

    if (confirmQuit) {
        AlertDialog(
            onDismissRequest = { confirmQuit = false },
            title = { Text("Leave the game?") },
            text = { Text("Your progress won't be saved.") },
            confirmButton = {
                TextButton(onClick = { game.stop(); onClose() }) {
                    Text("Leave game", color = androidx.compose.ui.graphics.Color(0xFFE53935))
                }
            },
            dismissButton = {
                TextButton(onClick = { confirmQuit = false }) { Text("Keep playing") }
            },
        )
    }
}

@Composable
private fun LudoBoard(game: LudoGame) {
    BoxWithConstraints(
        Modifier
            .fillMaxWidth()
            .aspectRatio(1f),
    ) {
        val side = minOf(maxWidth, maxHeight)
        val unitDp = side / 15f
        val density = androidx.compose.ui.platform.LocalDensity.current
        val unitPx = with(density) { unitDp.toPx() }

        Box(
            Modifier
                .size(side)
                .align(Alignment.Center)
                .clip(RoundedCornerShape(14.dp)),
        ) {
            LudoBoardCanvas(unitPx, Modifier.fillMaxSize())

            // Landing markers for the current roll
            for (move in game.pendingMoves) {
                val (cx, cy) = LudoEngine.centre(game.state.turn, move.token, move.to)
                LudoMoveHint(
                    game.state.turn,
                    Modifier
                        .size(unitDp * 0.88f)
                        .offset(
                            x = unitDp * cx - unitDp * 0.44f,
                            y = unitDp * cy - unitDp * 0.44f,
                        ),
                )
            }

            // Tokens
            for (seat in 0 until 4) {
                for (token in 0 until 4) {
                    LudoTokenSlot(
                        game = game,
                        seat = seat,
                        token = token,
                        unitDp = unitDp,
                        density = density,
                    )
                }
            }

            game.banner?.let { banner ->
                Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                    Text(
                        banner,
                        color = LudoTheme.cream,
                        style = VoiidFont.rounded(30, FontWeight.Bold),
                    )
                }
            }
        }
    }
}

@Composable
private fun LudoTokenSlot(
    game: LudoGame,
    seat: Int,
    token: Int,
    unitDp: androidx.compose.ui.unit.Dp,
    density: androidx.compose.ui.unit.Density,
) {
    val rel = game.state.positions[seat][token]
    val (cx, cy) = LudoEngine.centre(seat, token, rel)
    val (stackCount, stackIndex) = LudoEngine.stack(game.state, seat, token)

    val sizeFactor = when {
        rel == LudoPos.YARD -> 0.70f
        stackCount > 1 -> 0.62f
        else -> 0.74f
    }
    val nudge = if (stackCount > 1) (stackIndex * 0.13f - 0.06f) else 0f
    val diameter = unitDp * sizeFactor

    val targetX = unitDp * cx - diameter / 2f + unitDp * nudge
    val targetY = unitDp * cy - diameter / 2f - unitDp * nudge * 0.5f

    // Smooth physics spring for moving from square to square (matching iOS Theme.land)
    val animX by androidx.compose.animation.core.animateDpAsState(
        targetValue = targetX,
        animationSpec = androidx.compose.animation.core.spring(
            dampingRatio = 0.55f,
            stiffness = 600f,
        ),
        label = "tokenX_${seat}_$token",
    )
    val animY by androidx.compose.animation.core.animateDpAsState(
        targetValue = targetY,
        animationSpec = androidx.compose.animation.core.spring(
            dampingRatio = 0.55f,
            stiffness = 600f,
        ),
        label = "tokenY_${seat}_$token",
    )

    val isLive = game.isLive(seat, token)
    val isHopping = game.hopping == LudoGame.TokenRef(seat, token)
    val isPopping = game.popping == LudoGame.TokenRef(seat, token)

    LudoToken(
        seat = seat,
        diameter = with(density) { diameter.toPx() },
        isLive = isLive,
        isHopping = isHopping,
        isPopping = isPopping,
        modifier = Modifier
            .zIndex(if (isHopping) 30f else if (isLive) 20f else (5f + token))
            .offset(x = animX, y = animY)
            .size(diameter)
            .clickable(
                interactionSource = remember { androidx.compose.foundation.interaction.MutableInteractionSource() },
                indication = null,
                enabled = isLive,
            ) { game.tap(seat, token) },
    )
}

@Composable
private fun SeatRail(game: LudoGame, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        for (seat in 0 until 4) {
            val isTurn = game.state.turn == seat
            Row(
                Modifier
                    .weight(1f)
                    .clip(RoundedCornerShape(10.dp))
                    .background(if (isTurn) LudoTheme.ink3 else LudoTheme.ink2)
                    .padding(horizontal = 8.dp, vertical = 6.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp),
            ) {
                Box(
                    Modifier
                        .size(10.dp)
                        .clip(CircleShape)
                        .background(LudoTheme.seat(seat)),
                )
                Text(
                    "${game.state.homeCount(seat)}/4",
                    color = if (isTurn) LudoTheme.cream else LudoTheme.faint,
                    style = VoiidFont.rounded(12, if (isTurn) FontWeight.Bold else FontWeight.Medium),
                )
            }
        }
    }
}

@Composable
private fun Controls(game: LudoGame, modifier: Modifier = Modifier) {
    Row(
        modifier.fillMaxWidth(),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(14.dp),
    ) {
        // Two fixed lines: a row that grows and shrinks with the message length would shift
        // the die and ROLL button under the player's thumb mid-match.
        Text(
            game.message,
            color = LudoTheme.muted,
            style = VoiidFont.rounded(13, FontWeight.Normal),
            maxLines = 2,
            minLines = 2,
            modifier = Modifier.weight(1f),
        )

        LudoDie(
            value = game.die,
            rolling = game.rolling,
            enabled = game.canRoll,
            onClick = { game.roll() },
        )

        Box(
            Modifier
                .clip(RoundedCornerShape(11.dp))
                .background(if (game.canRoll) LudoTheme.brass else LudoTheme.ink3)
                .clickable(enabled = game.canRoll) { game.roll() }
                .padding(horizontal = 20.dp, vertical = 13.dp),
        ) {
            Text(
                "ROLL",
                color = if (game.canRoll) LudoTheme.ink else LudoTheme.faint,
                style = VoiidFont.rounded(12, FontWeight.Bold),
            )
        }
    }
}

@Composable
private fun SetupOverlay(winner: Int?, onPick: (String) -> Unit, onClose: () -> Unit) {
    Box(
        Modifier
            .fillMaxSize()
            .background(LudoTheme.ink.copy(alpha = 0.86f)),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            Modifier
                .widthIn(max = 340.dp)
                .padding(24.dp)
                .clip(RoundedCornerShape(18.dp))
                .background(LudoTheme.ink2)
                .padding(24.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.End) {
                IconButton(onClick = onClose) {
                    Icon(Icons.Filled.Close, contentDescription = "Close", tint = LudoTheme.muted)
                }
            }

            Text(
                winner?.let { "${LudoEngine.seats[it].name} wins!" } ?: "Ludo",
                color = LudoTheme.cream,
                style = VoiidFont.rounded(24, FontWeight.Bold),
            )
            Text(
                if (winner == null) "Four tokens, fifty-two squares, one die. Get all four home first."
                else "All four tokens home. Play again?",
                color = LudoTheme.muted,
                style = VoiidFont.rounded(13, FontWeight.Normal),
            )
            Spacer(Modifier.height(6.dp))

            listOf(
                Triple("easy", "Easy (vs Bots)", "Relaxed bots, gentle practice"),
                Triple("moderate", "Moderate (vs Bots)", "Standard balanced match against 3 bots"),
                Triple("hard", "Hard (vs Bots)", "Aggressive bots that cut and race"),
            ).forEach { (id, title, detail) ->
                Column(
                    Modifier
                        .fillMaxWidth()
                        .clip(RoundedCornerShape(11.dp))
                        .background(LudoTheme.ink3)
                        .clickable { onPick(id) }
                        .padding(vertical = 12.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Text(title, color = LudoTheme.cream, style = VoiidFont.rounded(13, FontWeight.SemiBold))
                    Text(detail, color = LudoTheme.faint, style = VoiidFont.rounded(11, FontWeight.Normal))
                }
            }

            TextButton(onClick = onClose) {
                Text(
                    "Quit to Menu",
                    color = LudoTheme.muted,
                    style = VoiidFont.rounded(12, FontWeight.Medium),
                )
            }

            // Shown here, where a player is deciding and has time to read — not pinned under
            // the board for the whole match, where it only costs the board height.
            Text(
                "Tap the die, then tap a glowing token. Outlined squares show where it will land. " +
                    "Sixes and captures earn another roll — three sixes forfeit the turn.",
                color = LudoTheme.faint,
                style = VoiidFont.rounded(11, FontWeight.Normal),
                modifier = Modifier.padding(top = 10.dp),
            )
        }
    }
}
