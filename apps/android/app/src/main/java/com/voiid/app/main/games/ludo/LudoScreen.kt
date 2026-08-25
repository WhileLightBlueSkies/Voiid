package com.voiid.app.main.games.ludo

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.foundation.layout.absoluteOffset
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.role
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.unit.IntOffset
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.animation.core.CubicBezierEasing
import androidx.compose.animation.core.animate
import androidx.compose.animation.core.tween
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.main.games.GameSettings
import com.voiid.app.net.GamesEngine
import com.voiid.app.main.games.ludo.ringFractionFor
import com.voiid.app.main.games.ludo.timerOverrideColor
import com.voiid.app.main.games.ludo.podAccessibility
import com.voiid.app.ui.theme.LudoDimens
import com.voiid.app.ui.theme.LudoMotion
import com.voiid.app.ui.theme.LudoPalette
import com.voiid.app.ui.theme.ludoPaletteFor
import com.voiid.app.ui.theme.VoiidColor
import kotlin.math.roundToInt

/**
 * The Ludo match screen (§11): responsive portrait chrome — top bar (close / help / network),
 * two pod rows, the generated board as visual center, ONE global die that rests at the active
 * player's anchor outside the board, bottom chat/emote tools.
 *
 * NO TEXTUAL TURN BANNER EXISTS. Ownership is shown only by border hue + die pip color; the
 * pod ring communicates HOW LONG. The board is the visual center — no rules text or score card
 * sits beneath it (§11.1).
 */
@Composable
fun LudoScreen(
    matchId: String,
    conversationId: String?,
    onClose: () -> Unit,
    onRematch: (String) -> Unit,
) {
    val context = LocalContext.current
    val engine = remember { GamesEngine.get(context) }
    val frameV2 by engine.ludoV2.collectAsState()
    val requiresUpdate by engine.ludoRequiresUpdate.collectAsState()
    val presence by engine.ludoPresence.collectAsState()

    var showExitConfirm by remember { mutableStateOf(false) }
    var showHelp by remember { mutableStateOf(false) }
    var showChat by remember { mutableStateOf(false) }
    var exploreBoard by remember { mutableStateOf(false) }

    LaunchedEffect(matchId) {
        engine.setLudoConversationId(conversationId)
        engine.open(matchId)
    }
    LifecycleSnapshotSync(engine)

    val state = frameV2?.state
    val reduceMotion = remember { ReduceMotionReader() }
    val powerManager = remember {
        context.getSystemService(android.content.Context.POWER_SERVICE) as android.os.PowerManager
    }
    var lowPower by remember { androidx.compose.runtime.mutableStateOf(powerManager.isPowerSaveMode) }
    androidx.compose.runtime.DisposableEffect(context, powerManager) {
        val receiver = object : android.content.BroadcastReceiver() {
            override fun onReceive(c: android.content.Context?, intent: android.content.Intent?) {
                lowPower = powerManager.isPowerSaveMode
            }
        }
        context.registerReceiver(
            receiver,
            android.content.IntentFilter(android.os.PowerManager.ACTION_POWER_SAVE_MODE_CHANGED),
        )
        onDispose { context.unregisterReceiver(receiver) }
    }
    val highContrast = remember {
        android.provider.Settings.Secure.getInt(context.contentResolver,
            "high_text_contrast_enabled", 0) == 1
    }

    // Presentation coordinator: one instance per match; new action ids enqueue beats once.
    val coordinator = remember(matchId) { LudoPresentationCoordinator().also { it.setMatchId(matchId) } }
    DisposableEffect(Unit) { onDispose { coordinator.cancelAll() } }

    val sweep by coordinator.sweep.collectAsState()
    val rollVisual by coordinator.roll.collectAsState()

    LaunchedEffect(state?.lastAction?.id) {
        val s = state ?: return@LaunchedEffect
        coordinator.setReduceMotion(reduceMotion.read(context) || lowPower)
        when (val a = s.lastAction) {
            null -> Unit
            else -> when (a.type) {
                "turnChanged" -> coordinator.enqueueTurnChange(a.fromSeat ?: a.actorSeat, a.actorSeat)
                "roll" -> a.roll?.let {
                    coordinator.enqueueRoll(it.rollId, it.value)
                    LudoHaptics.rollImpact(context, it.rollId)
                }
                "capture", "move", "autoTurn" -> a.move?.let { m ->
                    coordinator.enqueueMove(m.path.size, m.captured) { _ -> /* hop frame hook */ }
                    if (m.captured != null) {
                        if (m.captured.seat == s.viewerSeat) LudoHaptics.captureOnMe(context)
                        if (a.actorSeat == s.viewerSeat) LudoHaptics.captureByMe(context)
                    }
                }
                else -> Unit
            }
        }
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(LudoPalette.screenBackground()),
    ) {
        if (requiresUpdate) {
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text("Update Voiid to continue this Ludo match.")
            }
            return@Box
        }
        Column(Modifier.fillMaxSize().padding(horizontal = 12.dp)) {
            TopBar(
                connected = state != null,
                onClose = { if (state?.isActive == true) showExitConfirm = true else onClose() },
                onHelp = { showHelp = true },
            )

            if (state == null) {
                SkeletonBody(engine.joinError.value, Modifier.weight(1f))
            } else {
                PodRow(state, presence, top = true)
                BoardArea(
                    state = state,
                    sweep = sweep,
                    rollVisual = rollVisual,
                    coordinator = coordinator,
                    engine = engine,
                    exploreBoard = exploreBoard,
                    reduceMotionEnabled = reduceMotion.read(context) || lowPower,
                    highContrast = highContrast,
                    modifier = Modifier.weight(1f),
                )
                PodRow(state, presence, top = false)
            }

            Row(Modifier.fillMaxWidth().height(44.dp),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically) {
                Text("💬", fontSize = 20.sp,
                    modifier = Modifier
                        .clickable(enabled = engine.currentLudoConversationId() != null,
                            onClick = { showChat = true })
                        .semantics { contentDescription = "Game chat" })
                Text(
                    if (exploreBoard) "Board labels on" else "Board labels off",
                    fontSize = 11.sp, color = LudoPalette.textSecondary(),
                    modifier = Modifier.clickable { exploreBoard = !exploreBoard },
                )
            }
        }

        if (showExitConfirm && state?.isActive == true) {
            ExitConfirmSheet(
                onKeepPlaying = { showExitConfirm = false },
                onForfeit = {
                    showExitConfirm = false
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.Main).launch {
                        engine.forfeitLudo()
                        onClose()
                    }
                },
            )
        }
        if (showHelp) {
            LudoWalkthroughSheet(
                demoMode = DemoMode.Sandbox,
                clockNote = state?.isActive == true,
                onDismiss = { showHelp = false },
            )
        }
        if (showChat && engine.currentLudoConversationId() != null) {
            LudoChatSheet(
                matchId = matchId,
                conversationId = engine.currentLudoConversationId(),
                onDismiss = { showChat = false },
            )
        }
        if (state?.isFinished == true) {
            ResultSheet(
                state = state,
                matchId = matchId,
                onRematchNew = { id -> onRematch(id) },
                onBack = { onClose() },
            )
        }
    }
}

private class ReduceMotionReader {
    fun read(context: android.content.Context): Boolean =
        com.voiid.app.main.games.ReduceMotion.isEnabled(context)
}

@Composable
private fun LifecycleSnapshotSync(engine: GamesEngine) {
    val context = LocalContext.current
    val lifecycleOwner = androidx.lifecycle.compose.LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        var backgroundedAt: Long? = null
        val observer = androidx.lifecycle.LifecycleEventObserver { _, event ->
            when (event) {
                androidx.lifecycle.Lifecycle.Event.ON_PAUSE ->
                    backgroundedAt = System.currentTimeMillis()
                androidx.lifecycle.Lifecycle.Event.ON_RESUME -> {
                    val away = backgroundedAt?.let { System.currentTimeMillis() - it } ?: 0L
                    backgroundedAt = null
                    if (away > 5_000) {
                        kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                            runCatching { engine.fetchLudoSnapshot(force = true) }
                            LudoHaptics.reset()   // never replay timer haptics after foreground (§13)
                        }
                    }
                }
                else -> Unit
            }
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose { lifecycleOwner.lifecycle.removeObserver(observer) }
    }
}

internal fun ringFractionFor(state: LudoGameState, seat: Int): Float? {
    if (state.isFinished || state.turn?.seat != seat) return null
    val turn = state.turn ?: return null
    val deadline = turn.deadlineAt ?: return null
    val total = (deadline - turn.opensAt).coerceAtLeast(1)
    val remaining = (deadline - nowEstimated()).coerceIn(0L, LudoRules.TURN_WINDOW_MS.toLong())
    return remaining.toFloat() / total
}

@Composable
internal fun timerOverrideColor(state: LudoGameState, seat: Int): Color? {
    if (state.isFinished || state.turn?.seat != seat) return null
    val colors = ludoPaletteFor(!com.voiid.app.ui.theme.isLightTheme())
    val remaining = state.turn!!.deadlineAt?.minus(nowEstimated()) ?: return null
    return when {
        remaining <= 2_000 -> colors.c(colors.timerCritical)
        remaining <= 5_000 -> colors.c(colors.timerWarning)
        else -> colors.c(colors.timerActive)
    }
}

private fun nowEstimated(): Long = System.currentTimeMillis()

internal fun podAccessibility(
    sv: LudoSeatView?,
    state: LudoGameState,
    seat: Int,
    connection: String?,
): String = buildString {
    if (sv == null) return ""
    append(sv.displayName)
    if (!state.isFinished && state.turn?.seat == seat) append(", action")
    append(", ${sv.finishedPawns} of 4 pawns home")
    if (sv.isBot) append(", bot")
}

// ── Chrome ───────────────────────────────────────────────────────────────────────────────

@Composable
private fun TopBar(connected: Boolean, onClose: () -> Unit, onHelp: () -> Unit) {
    Row(Modifier.fillMaxWidth().height(44.dp), verticalAlignment = Alignment.CenterVertically) {
        Text("×", fontSize = 26.sp, color = VoiidColor.textPrimary,
            modifier = Modifier.clickable(onClick = onClose)
                .semantics { contentDescription = "Close" })
        Spacer(Modifier.weight(1f))
        if (!connected) NetworkCapsule()
        Spacer(Modifier.weight(1f))
        Text("?", fontSize = 20.sp, fontWeight = FontWeight.SemiBold,
            color = VoiidColor.textPrimary,
            modifier = Modifier.clickable(onClick = onHelp)
                .semantics { contentDescription = "How to play" })
    }
}

/** The viewer's OWN connection problem lives in the nav bar capsule, never over the board. */
@Composable
internal fun NetworkCapsule() {
    Row(verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.clip(RoundedCornerShape(999.dp))
            .background(VoiidColor.error.copy(alpha = 0.12f))
            .padding(horizontal = 10.dp, vertical = 3.dp)) {
        Box(Modifier.size(6.dp).clip(CircleShape).background(VoiidColor.error))
        Text(" reconnecting", fontSize = 11.sp, color = VoiidColor.error)
    }
}

@Composable
private fun SkeletonBody(error: String?, modifier: Modifier = Modifier) {
    Column(modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally) {
        if (error != null) {
            Text(error, color = VoiidColor.error, fontSize = 15.sp)
        } else {
            NeutralBoardSkeleton()
            Spacer(Modifier.height(16.dp))
            Text("Setting up the board…", color = LudoPalette.textSecondary(), fontSize = 14.sp)
        }
    }
}

/** Cold start draws the NEUTRAL generated board; never a default token layout flash (§9). */
@Composable
internal fun NeutralBoardSkeleton() {
    val colors = ludoPaletteFor(!com.voiid.app.ui.theme.isLightTheme())
    Canvas(Modifier.fillMaxWidth(0.92f).aspectRatio(1f)) {
        drawRoundRect(
            colors.c(colors.boardSurface),
            cornerRadius = CornerRadius(LudoDimens.boardCornerRadius.toPx()),
        )
        val u = size.width / LudoBoardGeometry.SIDE
        for (node in LudoBoardGeometry.CELLS) {
            when (node.role) {
                LudoBoardGeometry.Role.UNUSED,
                LudoBoardGeometry.Role.YARD,
                LudoBoardGeometry.Role.YARD_POCKET -> continue
                else -> drawRoundRect(
                    colors.c(colors.trackCellFill).copy(alpha = 0.4f),
                    topLeft = Offset(node.x * u + 1f, node.y * u + 1f),
                    size = Size(u - 2f, u - 2f),
                    cornerRadius = CornerRadius(3f),
                )
            }
        }
    }
}

// ── Pods ─────────────────────────────────────────────────────────────────────────────────

/** Fixed seats around the board (§11.2); duel renders NO pod for unassigned seats. */
@Composable
private fun PodRow(state: LudoGameState, presence: Map<Int, String>, top: Boolean) {
    val seats = if (top) listOf(1, 2) else listOf(0, 3)
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween) {
        seats.forEach { seat ->
            val sv = state.seats.firstOrNull { it.seat == seat }
            if (sv == null) {
                Spacer(Modifier.size(LudoDimens.podWidthStandard, 1.dp))
                return@forEach
            }
            LudoPlayerPod(
                seatView = sv,
                isSeatAssigned = true,
                active = !state.isFinished && state.turn?.seat == seat,
                ringFraction = ringFractionFor(state, seat),
                ringColorOverride = timerOverrideColor(state, seat),
                compact = false,
                modifier = Modifier.semantics {
                    contentDescription = podAccessibility(sv, state, seat, presence[seat])
                },
            )
        }
    }
}

// ── Board + die area ─────────────────────────────────────────────────────────────────────

@Composable
private fun BoardArea(
    state: LudoGameState,
    sweep: LudoPresentationCoordinator.BorderSweep?,
    rollVisual: LudoPresentationCoordinator.RollVisual?,
    coordinator: LudoPresentationCoordinator,
    engine: GamesEngine,
    exploreBoard: Boolean,
    reduceMotionEnabled: Boolean,
    highContrast: Boolean,
    modifier: Modifier,
) {
    val context = LocalContext.current
    var sidePx by remember { mutableIntStateOf(0) }

    // §15 hop chain: the display pawn animates along the SERVER'S EXACT path while
    // authoritative state already holds the destination. A tap anywhere fast-forwards.
    var hopOverride by remember { mutableStateOf<Triple<Int, Int, Offset>?>(null) }   // seat,pawn,center
    var captureOverride by remember { mutableStateOf<Pair<Pair<Int,Int>, Offset>?>(null) }

    LaunchedEffect(state.lastAction?.id) {
        val action = state.lastAction ?: return@LaunchedEffect
        val move = action.move ?: return@LaunchedEffect
        if (action.type == "roll") return@LaunchedEffect
        // Wait for the first layout so cell centers exist.
        kotlinx.coroutines.withTimeoutOrNull(500) {
            while (sidePx == 0) delay(16)
            true
        } ?: return@LaunchedEffect
        val layout = LudoBoardGeometry.Layout(sidePx.toFloat())
        val seat = action.actorSeat

        suspend fun centerOfPos(pos: Int): Offset? {
            if (pos in 0 until LudoRules.TRACK_COUNT) {
                val c = LudoBoardGeometry.TRACK_COORDS[pos]
                return layout.rectOf(LudoBoardGeometry.cell(c.first, c.second)).center
            }
            if (pos >= LudoRules.HOME_LANE_BASE && pos < LudoRules.FINISHED) {
                val c = LudoBoardGeometry.HOME_LANE_COORDS[seat][pos - LudoRules.HOME_LANE_BASE]
                return layout.rectOf(LudoBoardGeometry.cell(c.first, c.second)).center
            }
            return null
        }

        val easing = androidx.compose.animation.core.CubicBezierEasing(0.22f, 0f, 0.20f, 1f)
        val start = centerOfPos(move.from)
        val stops = move.path.mapNotNull { centerOfPos(it) }
        if (start != null && stops.isNotEmpty()) {
            var prev: Offset = start
            for ((i, stop) in stops.withIndex()) {
                if (i > 0) delay(LudoRules.HOP_STAGGER_MS.toLong())
                androidx.compose.animation.core.animate(
                    initialValue = 0f, targetValue = 1f,
                    animationSpec = androidx.compose.animation.core.tween(LudoRules.HOP_MS, easing = easing),
                ) { v, _ ->
                    hopOverride = Triple(
                        seat, move.tokenId,
                        Offset(prev.x + (stop.x - prev.x) * v, prev.y + (stop.y - prev.y) * v),
                    )
                }
                prev = stop
            }
        }
        hopOverride = null

        // Capture return: after a 70 ms hold the victim follows a 260 ms quadratic arc home.
        val cap = move.captured
        if (cap != null) {
            delay(70)
            val fromC = centerOfPos(cap.from)
            val slot = layout.yardSlotCenter(cap.seat, cap.tokenId).let { Offset(it.first, it.second) }
            if (fromC != null) {
                val mid = Offset((fromC.x + slot.x) / 2f, kotlin.math.min(fromC.y, slot.y) - layout.unit)
                animate(0f, 1f, animationSpec = tween(260, easing = CubicBezierEasing(0.30f, 0f, 0.10f, 1f))) { v, _ ->
                    val inv = 1 - v
                    val p = Offset(
                        inv * inv * fromC.x + 2 * inv * v * mid.x + v * v * slot.x,
                        inv * inv * fromC.y + 2 * inv * v * mid.y + v * v * slot.y,
                    )
                    captureOverride = (cap.seat to cap.tokenId) to p
                }
            }
            captureOverride = null
        }
    }

    val boardColors = ludoPaletteFor(!com.voiid.app.ui.theme.isLightTheme())
    val darkTheme = !com.voiid.app.ui.theme.isLightTheme()

    Box(modifier.fillMaxWidth(), Alignment.Center) {
        Canvas(
            modifier = Modifier
                .fillMaxWidth()
                .aspectRatio(1f)
                .pointerInput(state.seq) {
                    detectTapGestures { offset ->
                        val side = size.width.toFloat()
                        val layout = LudoBoardGeometry.Layout(side)
                        // Fast-forward any running hop chain first (§15); sends NO input.
                        coordinator.cancelAll()

                        // Resolve ONLY among server-legal pawns at the tapped point (§17).
                        val turn = state.turn ?: return@detectTapGestures
                        val viewer = state.seats.firstOrNull { it.seat == state.viewerSeat }
                        if (turn.phase != "awaitingMove" || state.viewerRole != "controller" ||
                            state.viewerSeat != turn.seat || viewer?.controller != "human") return@detectTapGestures
                        val placed = LudoPawnLayer.layout(state, layout, droppedSeats(state))
                        val legalPawns = turn.legalTokenIds.mapNotNull { t ->
                            val pos = state.tokens.getOrNull(turn.seat)?.getOrNull(t)
                                ?: return@mapNotNull null
                            posCellCenter(pos, turn.seat, layout)?.let { t to it }
                        }.toMap()
                        legalPawns.entries.firstOrNull { (_, c) ->
                            val dx = offset.x - c.first
                            val dy = offset.y - c.second
                            dx * dx + dy * dy <= (layout.unit * 0.75f) * (layout.unit * 0.75f)
                        }?.let { (token, _) ->
                            engine.moveLudoV2(context, token)
                        }
                    }
                }
                .semantics { contentDescription = LudoSemantics.boardSummary(state) },
        ) {
            sidePx = size.width.toInt()
            val layout = LudoBoardGeometry.Layout(size.width)

            // Display pawn mid-hop override: interpolated along the server's exact path;
            // authoritative state already holds the destination and is never fed back.
            val pawnsBase = LudoPawnLayer.layout(state, layout, droppedSeats(state), hopOverride)
            val pawns = captureOverride?.let { cap ->
                val key = cap.first
                val centerOv = cap.second
                pawnsBase.map {
                    if (it.seat == key.first && it.pawnIndex == key.second) {
                        it.copy(center = centerOv, scale = 0.88f)
                    } else it
                }
            } ?: pawnsBase

            LudoBoardDraw.drawAll(
                scope = this,
                colors = boardColors,
                state = state,
                placedPawns = pawns,
                highlightCells = highlightCellsForLegal(state),
                sweep = sweep,
                darkTheme = darkTheme,
                    reduceMotion = reduceMotionEnabled,
                    highContrast = highContrast,
            )
        }

        val turn = state.turn
        if (sidePx > 0 && turn?.phase == "awaitingMove" && state.viewerRole == "controller" &&
            state.viewerSeat == turn.seat) {
            val layout = LudoBoardGeometry.Layout(sidePx.toFloat())
            val placed = LudoPawnLayer.layout(state, layout, emptySet())
            val name = state.seats.firstOrNull { it.seat == turn.seat }?.displayName ?: "Player"
            for (token in turn.legalTokenIds) {
                val pawn = placed.firstOrNull { it.seat == turn.seat && it.pawnIndex == token } ?: continue
                Box(
                    Modifier
                        .size(48.dp)
                        .absoluteOffset {
                            IntOffset((pawn.center.x - 24.dp.toPx()).roundToInt(),
                                (pawn.center.y - 24.dp.toPx()).roundToInt())
                        }
                        .clickable { engine.moveLudoV2(context, token) }
                        .semantics {
                            role = Role.Button
                            contentDescription = LudoSemantics.pawnLabel(state, turn.seat, token, name) +
                                ", " + (LudoSemantics.legalHint(state, token) ?: "Move pawn")
                        },
                )
            }
        }

        DieAtAnchor(
            anchor = anchorForSeat(state),
            state = state,
            rollVisual = rollVisual,
            onTap = { engine.rollLudoV2(context) },
        )

        // Explore-board overlay: per-cell semantic labels, opt-in so normal navigation never
        // walks 225 cells (§17).
        if (exploreBoard) {
            ExploreOverlay(state)
        }
    }
}

private fun cellKeyFromTrack(i: Int): String =
    LudoBoardGeometry.TRACK_COORDS[i].let { "cell-${it.first}-${it.second}" }

private fun droppedSeats(st: LudoGameState): Set<Int> =
    emptySet()

private fun posCellCenter(pos: Int, seat: Int, layout: LudoBoardGeometry.Layout): Pair<Float, Float>? = when {
    pos in 0 until LudoRules.TRACK_COUNT -> {
        val c = LudoBoardGeometry.TRACK_COORDS[pos]
        layout.rectOf(LudoBoardGeometry.cell(c.first, c.second)).center.let { it.x to it.y }
    }
    pos >= LudoRules.HOME_LANE_BASE && pos < LudoRules.FINISHED -> {
        val c = LudoBoardGeometry.HOME_LANE_COORDS[seat][pos - LudoRules.HOME_LANE_BASE]
        layout.rectOf(LudoBoardGeometry.cell(c.first, c.second)).center.let { it.x to it.y }
    }
    else -> null
}

private fun highlightCellsForLegal(state: LudoGameState): Set<String> {
    val turn = state.turn ?: return emptySet()
    if (state.isFinished) return emptySet()
    return turn.legalTokenIds.mapNotNull { t ->
        val pos = state.tokens.getOrNull(turn.seat)?.getOrNull(t) ?: return@mapNotNull null
        when {
            pos in 0 until LudoRules.TRACK_COUNT ->
                cellKeyFromTrack(pos)
            pos >= LudoRules.HOME_LANE_BASE && pos < LudoRules.FINISHED ->
                LudoBoardGeometry.HOME_LANE_COORDS[turn.seat][pos - LudoRules.HOME_LANE_BASE]
                    .let { "cell-${it.first}-${it.second}" }
            else -> null
        }
    }.toSet()
}

@Composable
private fun ExploreOverlay(state: LudoGameState) {
    Column(Modifier.fillMaxSize()) {
        // A compact grid of invisible focusable cells carrying §17 labels.
        for (y in 0 until LudoBoardGeometry.SIDE) {
            Row(Modifier.weight(1f)) {
                for (x in 0 until LudoBoardGeometry.SIDE) {
                    val node = LudoBoardGeometry.cell(x, y)
                    Box(
                        Modifier
                            .weight(1f)
                            .semantics { contentDescription = LudoSemantics.cellLabel(node, state) },
                    )
                }
            }
        }
    }
}

// ── Die ──────────────────────────────────────────────────────────────────────────────────

internal enum class DieAnchor { TopLeft, TopRight, BottomRight, BottomLeft }

internal fun anchorForSeat(state: LudoGameState): DieAnchor = when (state.turn?.seat ?: 0) {
    1 -> DieAnchor.TopLeft
    2 -> DieAnchor.TopRight
    3 -> DieAnchor.BottomRight
    else -> DieAnchor.BottomLeft
}

@Composable
private fun DieAtAnchor(
    anchor: DieAnchor,
    state: LudoGameState,
    rollVisual: LudoPresentationCoordinator.RollVisual?,
    onTap: () -> Unit,
) {
    val darkNow = !com.voiid.app.ui.theme.isLightTheme()
    val dColors = ludoPaletteFor(darkNow)
    val alignment = when (anchor) {
        DieAnchor.TopLeft -> Alignment.TopStart
        DieAnchor.TopRight -> Alignment.TopEnd
        DieAnchor.BottomRight -> Alignment.BottomEnd
        DieAnchor.BottomLeft -> Alignment.BottomStart
    }
    val canRoll = state.isActive &&
        state.turn?.phase == "awaitingRoll" &&
        state.viewerRole == "controller" &&
        state.viewerSeat == state.turn?.seat &&
        state.seats.firstOrNull { it.seat == state.viewerSeat }?.controller == "human"
    val value = state.turn?.value ?: 1
    val pipsNeutral = state.turn == null || state.isFinished

    Box(Modifier.fillMaxWidth().height(76.dp), alignment) {
        Canvas(
            Modifier
                .size(LudoDimens.dieHitTarget)
                .clickable(enabled = canRoll, onClick = onTap)
                .semantics { contentDescription = LudoSemantics.dieLabel(state, value) },
        ) {
            val rest = LudoDie.restAngles(value)
            val rv = rollVisual
            val pipColor = if (pipsNeutral) dColors.c(dColors.dieNeutralPip)
                           else dColors.hue(state.turn.seat)
            with(LudoDie) {
                drawDie(
                sidePx = size.width * 0.9f,
                value = value,
                rotationXDeg = rv?.rotationX ?: rest.first,
                rotationYDeg = rv?.rotationY ?: rest.second,
                translationYPx = rv?.liftPx ?: 0f,
                scaleX = rv?.scaleX ?: 1f,
                scaleY = rv?.scaleY ?: 1f,
                pipColor = pipColor,
                edgeStrokePx = 1.25f,
                colors = dColors,
            )
            }
        }
    }
}

// ── Sheets ───────────────────────────────────────────────────────────────────────────────

@Composable
private fun ResultSheet(
    state: LudoGameState,
    matchId: String,
    onRematchNew: (String) -> Unit,
    onBack: () -> Unit,
) {
    val context = LocalContext.current
    val winner = state.seats.firstOrNull { it.seat == state.winnerSeat }
    Box(
        Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)),
        contentAlignment = Alignment.BottomCenter,
    ) {
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(VoiidColor.surfaceCard)
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text(winner?.displayName ?: "", fontSize = 24.sp, fontWeight = FontWeight.Bold,
                color = LudoPalette.textPrimary())
            Text(
                "${winner?.finishedPawns ?: 0}/4 home · ${winner?.captures ?: 0} captures",
                fontSize = 14.sp, fontWeight = FontWeight.SemiBold,
                color = LudoPalette.textSecondary(),
                modifier = Modifier.padding(top = 4.dp),
            )
            // Restrained code-drawn ripple in the winner hue, 420 ms equivalent — one circle.
            val rColors = ludoPaletteFor(!com.voiid.app.ui.theme.isLightTheme())
            Canvas(Modifier.padding(vertical = 14.dp).size(56.dp)) {
                val hue = rColors.centerTriangle(state.winnerSeat ?: 0)
                drawCircle(hue.copy(alpha = 0.22f))
                drawCircle(hue, style = Stroke(3f))
            }
            Row(horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                androidx.compose.material3.OutlinedButton(onClick = onBack) { Text("Back to chat") }
                androidx.compose.material3.Button(onClick = {
                    kotlinx.coroutines.CoroutineScope(kotlinx.coroutines.Dispatchers.IO).launch {
                        val rematcher = com.voiid.app.net.GamesService(
                            com.voiid.app.net.ApiClient(com.voiid.app.net.TokenStore.get(context))
                        )
                        // Rematch clones the FINISHED match into a fresh waiting lobby and
                        // every other player must accept again (§11.5).
                        runCatching { rematcher.rematch(matchId) }
                            .onSuccess { newId ->
                                kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.Main) {
                                    onRematchNew(newId)
                                }
                            }
                    }
                }) { Text("Rematch") }
            }
        }
    }
}

@Composable
private fun ExitConfirmSheet(onKeepPlaying: () -> Unit, onForfeit: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.35f)),
        contentAlignment = Alignment.BottomCenter) {
        Column(
            Modifier.fillMaxWidth()
                .clip(RoundedCornerShape(topStart = 20.dp, topEnd = 20.dp))
                .background(VoiidColor.surfaceCard)
                .padding(20.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            Text("Leave this game?", fontSize = 18.sp, fontWeight = FontWeight.SemiBold,
                color = LudoPalette.textPrimary())
            Text("You will forfeit this match.", fontSize = 13.sp,
                color = LudoPalette.textSecondary(), modifier = Modifier.padding(top = 4.dp))
            Spacer(Modifier.height(12.dp))
            androidx.compose.material3.Button(onClick = onKeepPlaying, Modifier.fillMaxWidth()) {
                Text("Keep playing")
            }
            androidx.compose.material3.TextButton(onClick = onForfeit, Modifier.fillMaxWidth()) {
                Text("Forfeit and leave", color = VoiidColor.error)
            }
        }
    }
}
