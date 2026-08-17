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
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * The Sea Battle match screen (docs/games/future/SEA_BATTLE.md §6–§9).
 *
 * A dumb view over GamesEngine, like every other renderer here: it holds no rules, decides no
 * outcomes, and never computes whether a shot hit. It draws the frame the server built FOR
 * THIS PLAYER — which for this game is not the same frame the opponent got, because the engine
 * projects state per recipient (§4.3). That is the one architectural difference from Tic Tac
 * Toe and it is invisible from in here: the fleet simply arrives, or does not.
 *
 * Mirrors iOS `SeaBattleView.swift`.
 */
@Composable
fun SeaBattleScreen(
    matchId: String,
    onClose: () -> Unit,
    onRematch: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    val state by engine.seaBattle.collectAsState()
    val joinError by engine.joinError.collectAsState()
    val me = engine.myUserId
    val haptics = remember { GameHaptics(context) }

    // Placement is local until committed. The server has no notion of a half-placed fleet
    // (§4.7), so there is nothing to sync here — this is a form, and Ready is its submit.
    //
    // A fleet is on the board before the player is asked anything. Never show an empty board
    // and ask them to fill it: that is a decision demanded before the player has committed,
    // which CROSS_CUTTING.md §9 names as the flow mistake the whole games surface makes.
    var draft by remember { mutableStateOf(SeaBattleRules.randomFleet()) }
    var draggingType by remember { mutableStateOf<Int?>(null) }
    var horizontal by remember { mutableStateOf(mapOf<Int, Boolean>()) }
    var placementError by remember { mutableStateOf<String?>(null) }

    var reticle by remember { mutableStateOf<Int?>(null) }
    var firingCell by remember { mutableStateOf<Int?>(null) }
    var showingOwnBoard by remember { mutableStateOf(false) }
    var confirmResign by remember { mutableStateOf(false) }

    // Shell travel, sunk reveal and hit shake (§9). Scoped to this composable, so a shell in
    // flight cannot land after the player has left the match.
    val motionScope = rememberCoroutineScope()
    val motion = rememberSeaBattleMotion(motionScope)
    // Read once when the match opens, per ReduceMotion's own note — not per frame.
    val reduceMotion = remember { ReduceMotion.isEnabled(context) }
    DisposableEffect(motion) { onDispose { motion.cancel() } }

    // A LIVE CLOCK, at a deliberately low rate — the counterpart to iOS's TimelineView.
    //
    // §8.2's shimmer exists to prove the screen is alive during the long pauses of an async
    // match. 20 fps is plenty for something that slow, and a board game has no reason to hold the
    // display at 120 Hz.
    var now by remember { mutableStateOf(0f) }
    LaunchedEffect(Unit) {
        while (true) {
            withFrameNanos { now = (it / 1_000_000_000.0).toFloat() }
            kotlinx.coroutines.delay(50)
        }
    }

    DisposableEffect(Unit) {
        GameAudio.preload(context, "seabattle")
        onDispose {
            GameAudio.release("seabattle")
            engine.leave()
        }
    }

    LaunchedEffect(matchId) { engine.open(matchId) }

    // THE RESULT IS REVEALED WHEN THE SHELL LANDS, NOT WHEN THE FRAME ARRIVES (§9).
    //
    // The frame usually beats the animation, and showing the answer the instant it lands would
    // make a fast connection feel different from a slow one. Holding the reveal until the end
    // of the fixed 380 ms travel is what makes every shot feel the same, and it is the whole
    // reason the travel exists. Android previously resolved on frame arrival with no travel at
    // all, so a shot was over in under 50 ms.
    LaunchedEffect(state?.lastShot) {
        val shot = state?.lastShot ?: return@LaunchedEffect
        val land = {
            val s0 = engine.seaBattle.value
            firingCell = null
            reticle = null
            SeaBattleSound.shotResolved(s0, me, haptics)
            if ((s0?.lastResult ?: 0) > 0) motion.hitShake(reduceMotion)
            val seat = s0?.seat ?: s0?.players?.indexOf(me)?.takeIf { it >= 0 }
            if (s0?.lastResult == 2 && seat != null) {
                // Whichever fleet just lost a ship owns the outline being drawn in.
                val owner = if (s0.turn?.let { 1 - it } == seat) 1 - seat else seat
                motion.revealSunk(
                    s0.sunkCells.getOrElse(owner) { emptyList() }.takeLast(5), reduceMotion)
            }
        }
        // Only wait when WE fired — an incoming shot has no shell of ours in the air.
        if (firingCell != null) motion.fire(reduceMotion, land) else land()
    }
    LaunchedEffect(state?.finished) {
        if (state?.finished == true) SeaBattleSound.matchEnded(state, me)
    }

    val s = state
    val mySeat = s?.seat ?: s?.players?.indexOf(me)?.takeIf { it >= 0 }
    val isMyTurn = s != null && !s.finished && s.turnUserId == me

    if (confirmResign) {
        // Confirmation, because the button sits next to the board and a resignation is
        // irreversible and counts as a loss (§2.6).
        AlertDialog(
            onDismissRequest = { confirmResign = false },
            title = { Text("Resign this match?") },
            text = { Text("It counts as a loss.") },
            confirmButton = {
                TextButton(onClick = {
                    confirmResign = false
                    engine.resignSeaBattle(context)
                }) { Text("Resign") }
            },
            dismissButton = {
                TextButton(onClick = { confirmResign = false }) { Text("Keep playing") }
            },
        )
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
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier.clickable { engine.leave(); onClose() },
                )
                Text(
                    "Sea Battle",
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = VoiidColor.textPrimary,
                    modifier = Modifier.padding(start = VoiidSpacing.md).weight(1f),
                )
                if (s != null && !s.finished && s.phase == "firing") {
                    Text(
                        "Resign",
                        fontSize = 14.sp,
                        color = VoiidColor.textSecondary,
                        modifier = Modifier.clickable { confirmResign = true },
                    )
                }
            }

            Spacer(Modifier.height(VoiidSpacing.md))

            when {
                s == null && joinError != null -> Text(
                    joinError!!,
                    fontSize = 15.sp,
                    color = VoiidColor.error,
                    modifier = Modifier.padding(top = VoiidSpacing.lg),
                )

                s == null -> Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.lg),
                ) {
                    CircularProgressIndicator()
                    Text(
                        "Setting up the board…",
                        fontSize = 14.sp,
                        color = VoiidColor.textSecondary,
                        modifier = Modifier.padding(top = VoiidSpacing.sm),
                    )
                }

                s.phase == "placing" -> {
                    val committed = mySeat != null && s.placed.getOrElse(mySeat) { false }
                    if (committed) {
                        Column(
                            horizontalAlignment = Alignment.CenterHorizontally,
                            modifier = Modifier.fillMaxWidth(),
                        ) {
                            CircularProgressIndicator()
                            Text(
                                "Fleet ready. Waiting for your opponent…",
                                fontSize = 14.sp,
                                color = VoiidColor.textSecondary,
                                modifier = Modifier.padding(top = VoiidSpacing.sm),
                            )
                            SeaBattleGrid(
                                cells = ownCells(s, mySeat, draft),
                                ships = myShips(s, draft),
                                sunkTypes = sunkTypesFor(s, mySeat ?: 0),
                                dimmed = true,
                            )
                        }
                    } else {
                        Text(
                            "Your ships are placed. Drag to move them, or tap Ready.",
                            fontSize = 14.sp,
                            color = VoiidColor.textSecondary,
                            textAlign = TextAlign.Center,
                            modifier = Modifier.fillMaxWidth(),
                        )
                        SeaBattleGrid(
                            cells = draftCells(draft),
                            ships = draft,
                            onTap = { cell ->
                                // Tap while dragging rotates. A separate rotate button is a
                                // two-handed operation and a long-press conflicts with the drag.
                                val type = draft.firstOrNull { cell in it.cells }?.type
                                if (type != null) {
                                    val idx = draft.indexOfFirst { it.type == type }
                                    val isH = horizontal[type] ?: true
                                    val ship = draft[idx]
                                    val cells = SeaBattleRules.run(ship.cells[0], ship.cells.size, !isH)
                                    val others = draft.filter { it.type != type }
                                    if (SeaBattleRules.canPlace(cells, others, ship.cells.size)) {
                                        horizontal = horizontal + (type to !isH)
                                        draft = draft.toMutableList()
                                            .also { it[idx] = ship.copy(cells = cells) }
                                        GameAudio.play("place_thud", gain = 0.45f)
                                    } else {
                                        // Refuse rather than silently correct — silent correction is
                                        // worse, because the player learns nothing about why.
                                        GameAudio.play("error", gain = 0.4f)
                                    }
                                }
                            },
                            onDrag = { cell ->
                                val type = draggingType
                                    ?: draft.firstOrNull { cell in it.cells }?.type
                                    ?: return@SeaBattleGrid
                                draggingType = type
                                val idx = draft.indexOfFirst { it.type == type }
                                if (idx < 0) return@SeaBattleGrid
                                val ship = draft[idx]
                                val isH = horizontal[type] ?: true
                                val cells = SeaBattleRules.run(cell, ship.cells.size, isH)
                                val others = draft.filter { it.type != type }
                                if (SeaBattleRules.canPlace(cells, others, ship.cells.size)) {
                                    draft = draft.toMutableList()
                                        .also { it[idx] = ship.copy(cells = cells) }
                                }
                            },
                        )

                        placementError?.let {
                            Text(it, fontSize = 13.sp, color = VoiidColor.error)
                        }

                        Row(
                            Modifier.fillMaxWidth().padding(top = VoiidSpacing.sm),
                            horizontalArrangement = Arrangement.SpaceBetween,
                        ) {
                            Text(
                                "Random",
                                fontSize = 15.sp,
                                color = VoiidColor.textSecondary,
                                modifier = Modifier.clickable {
                                    draft = SeaBattleRules.randomFleet()
                                    placementError = null
                                    GameAudio.play("place_thud", gain = 0.5f)
                                },
                            )
                            val valid = SeaBattleRules.validate(draft) == null
                            Text(
                                "Ready",
                                fontSize = 16.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (valid) VoiidColor.primary else VoiidColor.textSecondary,
                                modifier = Modifier.clickable(enabled = valid) {
                                    val failure = SeaBattleRules.validate(draft)
                                    if (failure != null) {
                                        placementError = failure.message
                                        GameAudio.play("error", gain = 0.5f)
                                    } else {
                                        placementError = null
                                        engine.placeFleet(context, draft.map {
                                            GamesEngine.SeaBattleState.Ship(it.type, it.cells, 0)
                                        })
                                    }
                                },
                            )
                        }
                    }
                }

                else -> {
                    Status(s, me, isMyTurn, mySeat)

                    // THE LAYOUT IS THE DESIGN (§8.1). The opponent's board is primary — it is where
                    // you act and where the deduction happens, so it gets the space. Your own board
                    // is a strip: a status readout answering "how much trouble am I in" without a
                    // tap. Emphasis follows the action rather than making the player follow it.
                    val enemy = @Composable { mod: Modifier ->
                        SeaBattleGrid(
                            cells = enemyCells(s, mySeat),
                            modifier = mod,
                            reticle = reticle,
                            firing = firingCell,
                            shellProgress = motion.shellProgress,
                            sunkReveal = motion.sunkReveal,
                            now = now,
                            dimmed = !isMyTurn,
                            onTap = { cell ->
                                if (isMyTurn && !s.finished && mySeat != null &&
                                    cell !in s.shots.getOrElse(mySeat) { emptyList() }
                                ) {
                                    reticle = cell
                                }
                            },
                        )
                    }
                    val own = @Composable { mod: Modifier ->
                        SeaBattleGrid(
                            cells = ownCells(s, mySeat, draft),
                            modifier = mod.clickable { showingOwnBoard = !showingOwnBoard },
                            now = now,
                            dimmed = isMyTurn,
                        )
                    }

                    if (showingOwnBoard) {
                        own(Modifier)
                        enemy(Modifier.heightIn(max = 96.dp))
                    } else {
                        enemy(Modifier)
                        own(Modifier.heightIn(max = 96.dp))
                    }

                    FleetStrip(s, mySeat)

                    // The end screen is an OVERLAY over the boards (§9.2) — see the Box wrapper
                    // at the bottom of this composable. Nothing takes the fire button's place.
                    if (!s.finished) {
                        // FIRE is the confirmation step the irreversibility demands (§7.2).
                        //
                        // A 10x10 grid gives ~33dp cells, below Material's 48dp minimum. One-tap
                        // firing on a sub-minimum target, where a mis-tap is irreversible and costs
                        // the match, is not acceptable — so you aim, then commit. The hesitation is
                        // also the most Battleship thing about Battleship.
                        val canFire = isMyTurn && reticle != null && firingCell == null
                        Box(
                            Modifier
                                .fillMaxWidth()
                                .padding(top = VoiidSpacing.sm)
                                .background(
                                    if (canFire) VoiidColor.primary.copy(alpha = 0.16f) else Color.Transparent,
                                    RoundedCornerShape(12.dp),
                                )
                                .clickable(enabled = canFire) {
                                    val cell = reticle ?: return@clickable
                                    firingCell = cell
                                    engine.fire(context, cell)
                                    GameAudio.play("fire_launch", gain = 0.7f)
                                }
                                .padding(vertical = VoiidSpacing.sm),
                            contentAlignment = Alignment.Center,
                        ) {
                            Text(
                                reticle?.let { "FIRE — ${SeaBattle.coordLabel(it)}" }
                                    ?: "Select a square",
                                fontSize = 16.sp,
                                fontWeight = FontWeight.SemiBold,
                                color = if (canFire) VoiidColor.primary else VoiidColor.textSecondary,
                            )
                        }
                    }
                }
            }
        }

        // THE BOARDS STAY VISIBLE BEHIND THE VERDICT (§9.2).
        val done = state
        if (done != null && done.finished) {
            MatchEndOverlay(
                result = seaBattleResult(done, mySeat, me),
                onExit = { engine.leave(); onClose() },
                matchId = matchId,
                onRematch = { newId -> engine.leave(); onRematch?.invoke(newId) },
            )
        }
    }

}

@Composable
private fun Status(
    s: GamesEngine.SeaBattleState,
    me: String?,
    isMyTurn: Boolean,
    mySeat: Int?,
) {
    val text = when {
        s.finished -> {
            val winner = s.winnerUserId
            if (winner == null) "Match abandoned" else {
                val won = winner == me
                when (s.endedBy) {
                    "resign" -> if (won) "They resigned — you win" else "You resigned"
                    "timeout" -> if (won) "They ran out of time — you win" else "You ran out of time"
                    else -> if (won) "You win" else "You lose"
                }
            }
        }
        isMyTurn -> "Your turn"
        else -> "Their turn"
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text,
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
        )
        // Shots fired is the score (§2.5) — a player who cannot see it cannot chase a best.
        if (mySeat != null) {
            Text(
                "${s.shots.getOrElse(mySeat) { emptyList() }.size} shots",
                fontSize = 12.sp,
                color = VoiidColor.textSecondary.copy(alpha = 0.8f),
            )
        }
        // The turn deadline, and ONLY inside 6 hours. A countdown from 24 h is noise (§8.3).
        if (!s.finished && isMyTurn && s.deadlineAt != null) {
            val remaining = s.deadlineAt / 1000 - System.currentTimeMillis() / 1000.0
            if (remaining > 0 && remaining < 6 * 3600) {
                Text(
                    "${(remaining / 60).toInt()} min left",
                    fontSize = 11.sp,
                    fontWeight = FontWeight.Medium,
                    color = VoiidColor.error.copy(alpha = 0.9f),
                )
            }
        }
    }
}

/**
 * Remaining fleet, both sides. The deduction aid, and the difference between the endgame being
 * reasoning and being a grind (§8.3).
 */
@Composable
private fun FleetStrip(s: GamesEngine.SeaBattleState, mySeat: Int?) {
    val seat = mySeat ?: 0
    Row(
        Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.sm),
        horizontalArrangement = Arrangement.SpaceEvenly,
    ) {
        listOf("Theirs" to 1 - seat, "Yours" to seat).forEach { (label, which) ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(
                    label,
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = VoiidColor.textSecondary.copy(alpha = 0.7f),
                )
                s.fleetSpec.forEachIndexed { type, length ->
                    val down = s.sunk.getOrElse(which) { emptyList() }.contains(type)
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

