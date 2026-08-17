package com.voiid.app.main.games

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Practice against local bots. No server, no match row, no connection needed.
 *
 * IT DRAWS THROUGH THE SAME BOARD AS THE ONLINE MATCH. [LudoBotMatch] builds a `LudoState` shaped
 * exactly like a server frame, so [LudoBoardCanvas] renders both — a player cannot tell a
 * practice board from a real one, and a fix to one is a fix to both.
 *
 * Difficulty arrives already chosen and is LOCKED for the match. It is labelled by PLAYSTYLE
 * rather than strength (§11.2): Ludo's skill ceiling is worth about ten percentage points of win
 * rate, so "Hard" would promise something the game cannot deliver.
 *
 * Ported from iOS `LudoBotView.swift`. This screen did not exist on Android at all: the Practice
 * row was hidden for Ludo, so the game was online-only here.
 */
@Composable
fun LudoBotScreen(level: BotDifficulty, skill: Float, onClose: () -> Unit) {
    val context = LocalContext.current
    val scores = remember { BotScoreStore(context) }
    val match = remember { LudoBotMatch(level, skill, scores = scores) }

    val scope = rememberCoroutineScope()
    val hop = remember { LudoHop(scope) }
    val haptics = remember { GameHaptics(context) }
    val reduceMotion = remember { ReduceMotion.isEnabled(context) }
    var lastDie by remember { mutableIntStateOf(0) }

    // Bumped whenever a bot seat owes a beat. The delay loop lives HERE, scoped to this screen,
    // so a bot move can never land after the player has left the match.
    var botToken by remember { mutableIntStateOf(0) }
    var botOwed by remember { mutableStateOf(false) }

    DisposableEffect(Unit) {
        GameAudio.preload(context, "ludo")
        onDispose {
            GameAudio.release("ludo")
            hop.skip()
        }
    }

    LaunchedEffect(botToken) {
        if (!botOwed) return@LaunchedEffect
        botOwed = false
        var more = true
        while (more) {
            delay(LudoBot.thinkingDelayMs())
            more = match.stepBot()
        }
    }

    val s = match.state

    LaunchedEffect(s.die) {
        val face = s.die ?: return@LaunchedEffect
        lastDie = face
        LudoSound.dieSettled(haptics)
    }
    LaunchedEffect(s.lastMove) {
        val move = s.lastMove ?: return@LaunchedEffect
        hop.play(
            seat = move.seat,
            token = move.token,
            from = move.from,
            to = move.to,
            die = lastDie,
            reduceMotion = reduceMotion,
            onStep = { LudoSound.hopped() },
            onFinish = { LudoSound.moved(move, LudoBotMatch.HUMAN_SEAT, haptics) },
        )
    }
    LaunchedEffect(s.finished) {
        if (s.finished) LudoSound.matchEnded(s, "you")
    }

    // A Box, not the bare Column: the end screen is a SIBLING that sits OVER the
    // board (§9.2). Inside the Column it would be laid out in flow and push the
    // board up the screen instead of covering it.
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .background(VoiidColor.background)
                .statusBarsPadding()
                .padding(horizontal = VoiidSpacing.md),
            verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier.clickable { onClose() }.padding(VoiidSpacing.sm),
                )
                Text(
                    "Ludo",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                // PLAYSTYLE, NOT STRENGTH — see LudoBot's header.
                Text(
                    LudoBot.styleLabel(skill.toDouble()),
                    fontSize = 13.sp,
                    color = VoiidColor.textSecondary,
                )
            }

            PlayerStrips(s, "you")

            LudoBoardCanvas(
                state = s,
                mySeat = LudoBotMatch.HUMAN_SEAT,
                legal = if (match.canMove) s.legal else emptyList(),
                onTapToken = { token ->
                    if (match.move(token)) {
                        botOwed = true
                        botToken++
                    }
                },
                hopOverrides = hop.overrides,
                reduceMotion = reduceMotion,
            )

            Status(s, "you", match.canRoll || match.canMove, LudoBotMatch.HUMAN_SEAT)

            // The end screen is an OVERLAY over the board (§9.2).
            if (!s.finished) {
                DieButton(s, match.canRoll) {
                    LudoSound.dieRolled()
                    if (match.roll()) {
                        botOwed = true
                        botToken++
                    }
                }
            }

            Spacer(Modifier.weight(1f))
        }

        // THE BOARD STAYS VISIBLE BEHIND THE VERDICT (§9.2).
        if (s.finished) {
            MatchEndOverlay(
                result = ludoResult(s, LudoBotMatch.HUMAN_SEAT, "you"),
                onExit = onClose,
                onPlayAgain = { match.restart() },
            )
        }
    }

}
