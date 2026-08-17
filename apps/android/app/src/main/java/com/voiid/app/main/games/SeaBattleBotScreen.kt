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
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Practice against the local bot. No server, no match row, no connection needed.
 *
 * Difficulty arrives already chosen from [GameSetupSheet] and is LOCKED for the match — a record
 * of "beat the hard bot" is worthless if it could be lowered mid-game. To change it you leave
 * and start again, which is exactly the honest cost.
 *
 * IT DRAWS THROUGH THE SAME CODE AS THE ONLINE MATCH. [SeaBattleBotMatch] builds a
 * `SeaBattleState` shaped exactly like a server frame, and both boards come from [enemyCells] /
 * [ownCells] — so a player cannot tell a practice board from a real one, and a fix to one is a
 * fix to both.
 *
 * Ported from iOS `SeaBattleBotView.swift`. This screen did not exist on Android at all: the
 * Practice row was hidden for Sea Battle, so the game was online-only here.
 */
@Composable
fun SeaBattleBotScreen(level: BotDifficulty, skill: Float, onClose: () -> Unit) {
    val context = LocalContext.current
    val scores = remember { BotScoreStore(context) }
    val match = remember { SeaBattleBotMatch(level, skill, scores) }

    val motionScope = rememberCoroutineScope()
    val motion = rememberSeaBattleMotion(motionScope)
    val reduceMotion = remember { ReduceMotion.isEnabled(context) }

    // Placement is local until committed, exactly as it is online. The board arrives already
    // populated — never an empty board with a demand to fill it.
    var draft by remember { mutableStateOf(SeaBattleRules.randomFleet()) }
    var draggingType by remember { mutableStateOf<Int?>(null) }
    var horizontal by remember { mutableStateOf(mapOf<Int, Boolean>()) }
    var reticle by remember { mutableStateOf<Int?>(null) }
    var showingOwnBoard by remember { mutableStateOf(false) }

    // Bumped whenever the bot owes a move, so the LaunchedEffect below re-arms for each turn
    // rather than firing once. The delay lives HERE, in a coroutine scoped to this screen, so a
    // bot shot can never land after the player has left the match.
    var botTurnToken by remember { mutableIntStateOf(0) }
    var pendingDelay by remember { mutableStateOf<Long?>(null) }

    DisposableEffect(Unit) {
        GameAudio.preload(context, "seabattle")
        onDispose {
            GameAudio.release("seabattle")
            motion.cancel()
        }
    }

    LaunchedEffect(botTurnToken) {
        val wait = pendingDelay ?: return@LaunchedEffect
        pendingDelay = null
        delay(wait)
        match.botTurn()
    }

    val s = match.state

    // Same two beats as online, driven by the same fields.
    LaunchedEffect(s.shots[0].size + s.shots[1].size) {
        if (s.lastShot == null) return@LaunchedEffect
        reticle = null
        SeaBattleSound.shotResolved(s, "you")
        if ((s.lastResult ?: 0) > 0) motion.hitShake(reduceMotion)
        if (s.lastResult == 2) {
            val owner = if (s.turn == SeaBattleBotMatch.HUMAN_SEAT) {
                SeaBattleBotMatch.BOT_SEAT
            } else {
                SeaBattleBotMatch.HUMAN_SEAT
            }
            motion.revealSunk(s.sunkCells[owner].takeLast(5), reduceMotion)
        }
    }
    LaunchedEffect(s.finished) {
        if (s.finished) SeaBattleSound.matchEnded(s, "you")
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
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier.clickable { onClose() }.padding(VoiidSpacing.sm),
                )
                Text(
                    "Sea Battle",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VoiidColor.textPrimary,
                )
                Spacer(Modifier.weight(1f))
                Text(level.label, fontSize = 13.sp, color = VoiidColor.textSecondary)
            }

            if (s.phase == "placing") {
                Placement(
                    draft = draft,
                    onRandom = {
                        draft = SeaBattleRules.randomFleet()
                        GameAudio.play("place_thud", gain = 0.5f)
                    },
                    onReady = { match.place(draft) },
                    onTapCell = { cell ->
                        val type = draft.firstOrNull { cell in it.cells }?.type
                        if (type != null) {
                            val idx = draft.indexOfFirst { it.type == type }
                            val isH = horizontal[type] ?: true
                            val length = draft[idx].cells.size
                            val cells = SeaBattleRules.run(draft[idx].cells[0], length, !isH)
                            val others = draft.filter { it.type != type }
                            if (SeaBattleRules.canPlace(cells, others, length)) {
                                horizontal = horizontal + (type to !isH)
                                draft = draft.toMutableList()
                                    .also { it[idx] = it[idx].copy(cells = cells) }
                                GameAudio.play("place_thud", gain = 0.45f)
                            } else {
                                GameAudio.play("error", gain = 0.4f)
                            }
                        }
                    },
                    onDragCell = { cell ->
                        if (draggingType == null) {
                            draggingType = draft.firstOrNull { cell in it.cells }?.type
                        }
                        val type = draggingType
                        if (type != null) {
                            val idx = draft.indexOfFirst { it.type == type }
                            if (idx >= 0) {
                                val length = draft[idx].cells.size
                                val isH = horizontal[type] ?: true
                                val cells = SeaBattleRules.run(cell, length, isH)
                                val others = draft.filter { it.type != type }
                                if (SeaBattleRules.canPlace(cells, others, length)) {
                                    draft = draft.toMutableList()
                                        .also { it[idx] = it[idx].copy(cells = cells) }
                                }
                            }
                        }
                    },
                )
            } else {
                Battle(
                    s = s,
                    match = match,
                    motion = motion,
                    reduceMotion = reduceMotion,
                    draft = draft,
                    reticle = reticle,
                    showingOwnBoard = showingOwnBoard,
                    onToggleBoards = { showingOwnBoard = !showingOwnBoard },
                    onAim = { reticle = it },
                    onFire = { cell ->
                        GameAudio.play("fire_launch", gain = 0.7f)
                        // The shell falls, THEN the shot resolves — so a local bot game has the same
                        // beat as a round-tripped online one rather than answering instantly.
                        motion.fire(reduceMotion) {
                            val wait = match.fire(cell)
                            if (wait != null) {
                                pendingDelay = wait
                                botTurnToken++
                            }
                        }
                    },
                    onPlayAgain = {
                        match.restart()
                        draft = SeaBattleRules.randomFleet()
                        reticle = null
                    },
                    onClose = onClose,
                )
            }
            Spacer(Modifier.weight(1f))
        }

        // THE BOARDS STAY VISIBLE BEHIND THE VERDICT (§9.2).
        if (s.finished) {
            val hitCells = s.shots[SeaBattleBotMatch.BOT_SEAT]
                .filterIndexed { i, _ ->
                    s.results[SeaBattleBotMatch.BOT_SEAT].getOrElse(i) { 0 } > 0
                }
                .toHashSet()
            MatchEndOverlay(
                result = MatchEndResult.seaBattle(
                    won = s.winnerUserId == "you",
                    shots = s.shots[SeaBattleBotMatch.HUMAN_SEAT].size,
                    hits = s.results[SeaBattleBotMatch.HUMAN_SEAT].count { it > 0 },
                    sunk = s.sunk[SeaBattleBotMatch.BOT_SEAT].size,
                    hiddenShips = s.myFleet.count { ship -> ship.cells.none { it in hitCells } },
                    endedBy = s.endedBy,
                ),
                onExit = onClose,
                onPlayAgain = {
                    match.restart()
                    draft = SeaBattleRules.randomFleet()
                    reticle = null
                },
            )
        }
    }

}

@Composable
private fun Placement(
    draft: List<SeaBattleShip>,
    onRandom: () -> Unit,
    onReady: () -> Unit,
    onTapCell: (Int) -> Unit,
    onDragCell: (Int) -> Unit,
) {
    Column(
        Modifier.padding(top = VoiidSpacing.md),
        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
    ) {
        Text(
            "Your ships are placed. Drag to move them, or tap Ready.",
            fontSize = 14.sp,
            color = VoiidColor.textSecondary,
            textAlign = TextAlign.Center,
            modifier = Modifier.fillMaxWidth(),
        )

        SeaBattleGrid(
            cells = draftCells(draft),
            onTap = onTapCell,
            onDrag = onDragCell,
        )

        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                "Random",
                fontSize = 15.sp,
                color = VoiidColor.textSecondary,
                modifier = Modifier.clickable { onRandom() }.padding(VoiidSpacing.sm),
            )
            Spacer(Modifier.weight(1f))
            val valid = SeaBattleRules.validate(draft) == null
            Text(
                "Ready",
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (valid) VoiidColor.primary else VoiidColor.textSecondary,
                modifier = Modifier
                    .clickable(enabled = valid) { onReady() }
                    .padding(VoiidSpacing.sm),
            )
        }
    }
}

@Composable
private fun Battle(
    s: com.voiid.app.net.GamesEngine.SeaBattleState,
    match: SeaBattleBotMatch,
    motion: SeaBattleMotion,
    reduceMotion: Boolean,
    draft: List<SeaBattleShip>,
    reticle: Int?,
    showingOwnBoard: Boolean,
    onToggleBoards: () -> Unit,
    onAim: (Int) -> Unit,
    onFire: (Int) -> Unit,
    onPlayAgain: () -> Unit,
    onClose: () -> Unit,
) {
    Column(verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
        val status = when {
            s.finished && s.winnerUserId == null -> "Match abandoned"
            s.finished && s.endedBy == "resign" -> "You gave up"
            s.finished -> if (s.winnerUserId == "you") "You win" else "The bot wins"
            match.botThinking -> "The bot is thinking…"
            match.canFire -> "Your turn"
            else -> "Their turn"
        }
        Column(
            Modifier.fillMaxWidth(),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(
                status,
                fontSize = 16.sp,
                fontWeight = FontWeight.SemiBold,
                color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
            )
            Text(
                "${s.shots[SeaBattleBotMatch.HUMAN_SEAT].size} shots",
                fontSize = 12.sp,
                color = VoiidColor.textSecondary.copy(alpha = 0.8f),
            )
        }

        val enemy = @Composable { mod: Modifier ->
            SeaBattleGrid(
                cells = enemyCells(s, SeaBattleBotMatch.HUMAN_SEAT),
                modifier = mod,
                reticle = reticle,
                firing = reticle.takeIf { motion.shellProgress > 0f },
                shellProgress = motion.shellProgress,
                sunkReveal = motion.sunkReveal,
                dimmed = !match.canFire,
                onTap = { cell ->
                    if (match.canFire && cell !in s.shots[SeaBattleBotMatch.HUMAN_SEAT]) {
                        onAim(cell)
                    }
                },
            )
        }
        val own = @Composable { mod: Modifier ->
            SeaBattleGrid(
                cells = ownCells(s, SeaBattleBotMatch.HUMAN_SEAT, draft),
                modifier = mod.clickable { onToggleBoards() },
                dimmed = match.canFire,
            )
        }

        if (showingOwnBoard) {
            own(Modifier)
            enemy(Modifier.heightIn(max = 96.dp))
        } else {
            enemy(Modifier)
            own(Modifier.heightIn(max = 96.dp))
        }

        FleetStrip(s)

        // The end screen is an OVERLAY over the boards (§9.2).
        if (!s.finished) {
            val canFire = match.canFire && reticle != null
            Box(
                Modifier
                    .fillMaxWidth()
                    .padding(top = VoiidSpacing.sm)
                    .background(
                        if (canFire) VoiidColor.primary.copy(alpha = 0.16f) else Color.Transparent,
                        RoundedCornerShape(12.dp),
                    )
                    .clickable(enabled = canFire) { reticle?.let(onFire) }
                    .padding(vertical = VoiidSpacing.sm),
                contentAlignment = Alignment.Center,
            ) {
                Text(
                    reticle?.let { "FIRE — ${SeaBattle.coordLabel(it)}" } ?: "Select a square",
                    fontSize = 16.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = if (canFire) VoiidColor.primary else VoiidColor.textSecondary,
                )
            }
        }
    }
}

@Composable
private fun FleetStrip(s: com.voiid.app.net.GamesEngine.SeaBattleState) {
    Row(
        Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.lg, Alignment.CenterHorizontally),
    ) {
        listOf("Theirs" to SeaBattleBotMatch.BOT_SEAT, "Yours" to SeaBattleBotMatch.HUMAN_SEAT)
            .forEach { (label, seat) ->
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Text(
                        label,
                        fontSize = 10.sp,
                        fontWeight = FontWeight.Medium,
                        color = VoiidColor.textSecondary.copy(alpha = 0.7f),
                    )
                    s.fleetSpec.forEachIndexed { type, length ->
                        val down = s.sunk.getOrElse(seat) { emptyList() }.contains(type)
                        Text(
                            "$length",
                            fontSize = 10.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = if (down) VoiidColor.textSecondary.copy(alpha = 0.35f)
                                    else VoiidColor.textPrimary,
                            textDecoration = if (down) TextDecoration.LineThrough else null,
                            modifier = Modifier.padding(start = 4.dp),
                        )
                    }
                }
            }
    }
}
