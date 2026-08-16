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

    // The shot resolves when the FRAME arrives, not when an animation ends. Clearing the local
    // firing cell here is what hands the square back to the server's answer.
    LaunchedEffect(state?.lastShot) {
        if (state?.lastShot != null) {
            firingCell = null
            reticle = null
            SeaBattleSound.shotResolved(state, me, haptics)
        }
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
                        SeaBattleGrid(cells = ownCells(s, mySeat, draft), dimmed = true)
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

                if (s.finished) {
                    RematchBar(
                        matchId = matchId,
                        onRematch = { newId -> engine.leave(); onRematch?.invoke(newId) },
                        onExit = { engine.leave(); onClose() },
                    )
                } else {
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

/**
 * What the OPPONENT's board looks like from here: my shots, and any ship I have sunk. Their
 * un-hit ships are not in this frame at all, so there is nothing to accidentally draw.
 */
private fun enemyCells(s: GamesEngine.SeaBattleState, mySeat: Int?): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    val seat = mySeat ?: return cells
    val enemy = 1 - seat
    s.shots.getOrElse(seat) { emptyList() }.forEachIndexed { i, cell ->
        if (cell in cells.indices) {
            val result = s.results.getOrElse(seat) { emptyList() }.getOrElse(i) { 0 }
            cells[cell] = if (result == 0) SeaBattleCell.MISS else SeaBattleCell.HIT
        }
    }
    // Sunk outlines are public once the ship is down, and they are what makes the endgame
    // deduction rather than a grind (§2.4).
    s.sunkCells.getOrElse(enemy) { emptyList() }.forEach {
        if (it in cells.indices) cells[it] = SeaBattleCell.SUNK
    }
    // Once the match is over the terminal frame carries both fleets, so the loser's unhit ships
    // finally appear. This is the ONLY path that draws an enemy ship that is not sunk.
    if (s.finished) {
        s.revealedFleets?.getOrNull(enemy)?.forEach { ship ->
            ship.cells.forEach {
                if (it in cells.indices && cells[it] == SeaBattleCell.WATER) {
                    cells[it] = SeaBattleCell.SHIP
                }
            }
        }
    }
    return cells
}

/** My own board: my fleet, and their shots on it. */
private fun ownCells(
    s: GamesEngine.SeaBattleState,
    mySeat: Int?,
    draft: List<SeaBattleShip>,
): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    // During placement the frame has no fleet yet, so fall back to the local draft — the only
    // place the two are interchangeable, and only because nothing is committed.
    val fleet = if (s.myFleet.isEmpty()) {
        draft.map { GamesEngine.SeaBattleState.Ship(it.type, it.cells, it.hits) }
    } else s.myFleet
    fleet.forEach { ship ->
        ship.cells.forEach { if (it in cells.indices) cells[it] = SeaBattleCell.SHIP }
    }
    val seat = mySeat ?: return cells
    val enemy = 1 - seat
    s.shots.getOrElse(enemy) { emptyList() }.forEachIndexed { i, cell ->
        if (cell in cells.indices) {
            val result = s.results.getOrElse(enemy) { emptyList() }.getOrElse(i) { 0 }
            cells[cell] = if (result == 0) SeaBattleCell.MISS else SeaBattleCell.SHIP_HIT
        }
    }
    s.sunkCells.getOrElse(seat) { emptyList() }.forEach {
        if (it in cells.indices) cells[it] = SeaBattleCell.SUNK
    }
    return cells
}

private fun draftCells(draft: List<SeaBattleShip>): List<SeaBattleCell> {
    val cells = MutableList(SeaBattle.CELLS) { SeaBattleCell.WATER }
    draft.forEach { ship ->
        ship.cells.forEach { if (it in cells.indices) cells[it] = SeaBattleCell.SHIP }
    }
    return cells
}
