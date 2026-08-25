package com.voiid.app.main.games.ludo

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTapGestures
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
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.LiveRegionMode
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
 * player's home quadrant, the board vertically centred as the screen's visual anchor.
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
    // Per-cell TalkBack labels (§17). This used to hang off a debug toggle in the bottom row;
    // with that row gone it follows the screen-reader state directly, so the 225 cell labels
    // exist exactly when something can read them and never clutter normal navigation.
    val exploreBoard = remember { isScreenReaderOn(context) }

    // The face the die shows. `turn.value` is cleared the moment the turn advances, which
    // blanked the die back to 1 as soon as a roll resolved — you never got to see what you
    // rolled. The last committed roll is held until a NEW roll replaces it, so the number stays
    // readable while you choose a pawn, and through a skip.
    var lastRolledValue by remember { mutableIntStateOf(1) }
    // Transient line naming the seat whose window expired; never blocks input.
    var skipNotice by remember { mutableStateOf<String?>(null) }

    // A timeout that produced no move is a skip; say so, because otherwise the turn simply
    // moves on and the player who ran out of time is never told why.
    LaunchedEffect(frameV2?.state?.lastAction?.id) {
        val action = frameV2?.state?.lastAction ?: return@LaunchedEffect
        action.roll?.let { lastRolledValue = it.value }
        if (action.type != "autoTurn") return@LaunchedEffect
        val who = frameV2?.state?.seats
            ?.firstOrNull { it.seat == action.actorSeat }?.displayName ?: "Player"
        skipNotice = if (action.move != null) "$who ran out of time — moved automatically"
                     else "$who ran out of time — turn skipped"
        delay(2200)
        skipNotice = null
    }

    // ONE legal token means there is no decision to make, so the move plays itself once the die
    // has settled — the way Ludo King does it. Waiting keeps the number readable before the
    // board moves under it.
    var autoMovedKey by remember { mutableStateOf<String?>(null) }
    val forcedKey = forcedMoveKey(frameV2?.state)
    LaunchedEffect(forcedKey) {
        val key = forcedKey ?: return@LaunchedEffect
        if (autoMovedKey == key) return@LaunchedEffect
        autoMovedKey = key
        delay(LudoMotion.FORCED_MOVE_HOLD_MS)
        // Re-check: the window may have closed while we waited (timeout, disconnect, resync).
        if (forcedMoveKey(engine.ludoV2.value?.state) != key) return@LaunchedEffect
        key.substringAfterLast(':').toIntOrNull()?.let { engine.moveLudoV2(context, it) }
    }

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
                // The board is the screen's optical centre: equal weighted spacers above and
                // below the pod/board/pod block centre it vertically, while the board's own
                // aspectRatio(1) centres it horizontally.
                val displayedDie = state.turn?.value ?: lastRolledValue
                val rollDie = { engine.rollLudoV2(context) }
                Spacer(Modifier.weight(1f))
                PodRow(state, presence, top = true, rollVisual = rollVisual,
                    onRollDie = rollDie, displayedDieValue = displayedDie)
                BoardArea(
                    state = state,
                    sweep = sweep,
                    rollVisual = rollVisual,
                    coordinator = coordinator,
                    engine = engine,
                    exploreBoard = exploreBoard,
                    reduceMotionEnabled = reduceMotion.read(context) || lowPower,
                    highContrast = highContrast,
                    modifier = Modifier.fillMaxWidth(),
                )
                PodRow(state, presence, top = false, rollVisual = rollVisual,
                    onRollDie = rollDie, displayedDieValue = displayedDie)
                Spacer(Modifier.weight(1f))
            }
        }

        skipNotice?.let { notice ->
            Box(Modifier.fillMaxSize().padding(top = 64.dp), Alignment.TopCenter) {
                Text(
                    notice,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    color = LudoPalette.textPrimary(),
                    modifier = Modifier
                        .clip(RoundedCornerShape(50))
                        .background(LudoPalette.podSurface())
                        .padding(horizontal = 14.dp, vertical = 8.dp)
                        .semantics { liveRegion = LiveRegionMode.Polite },
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
private fun PodRow(
    state: LudoGameState,
    presence: Map<Int, String>,
    top: Boolean,
    rollVisual: LudoPresentationCoordinator.RollVisual?,
    onRollDie: () -> Unit,
    displayedDieValue: Int,
) {
    val seats = if (top) listOf(1, 2) else listOf(0, 3)
    Row(Modifier.fillMaxWidth().padding(vertical = 4.dp),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically) {
        seats.forEachIndexed { index, seat ->
            val sv = state.seats.firstOrNull { it.seat == seat }
            if (sv == null) {
                Spacer(Modifier.size(LudoDimens.podWidthStandard, 1.dp))
                return@forEachIndexed
            }
            // The tray sits on the OUTER side of each pod, so the two never collide mid-row.
            val trayTrailing = index == 0
            Row(verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (!trayTrailing) {
                    DieTray(state, seat, rollVisual, onRollDie, displayedDieValue)
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
                if (trayTrailing) {
                    DieTray(state, seat, rollVisual, onRollDie, displayedDieValue)
                }
            }
        }
    }
}

/**
 * The die's home: a tray beside the owning pod, OUTSIDE the board.
 *
 * The die used to be drawn inside the board's own square — first past its edge, where it was
 * clipped away entirely, then inside the active seat's home yard, where it sat on top of that
 * seat's four resting pawns. It belongs next to the player it belongs to, the way Ludo King
 * seats it beside the profile. The tray is ALWAYS reserved so the row never reflows when the
 * turn moves; only the active seat's tray actually holds the die.
 */
@Composable
private fun DieTray(
    state: LudoGameState,
    seat: Int,
    rollVisual: LudoPresentationCoordinator.RollVisual?,
    onRollDie: () -> Unit,
    displayedValue: Int,
) {
    val isActive = !state.isFinished && state.turn?.seat == seat
    val trayside = LudoDimens.dieSizeStandard + 8.dp
    Box(
        Modifier
            .size(trayside)
            .then(
                if (isActive) {
                    Modifier
                        .clip(RoundedCornerShape(LudoDimens.podCornerRadius))
                        .background(LudoPalette.podSurface())
                } else Modifier
            ),
        contentAlignment = Alignment.Center,
    ) {
        if (isActive) {
            DieFace(state, rollVisual, onRollDie, displayedValue)
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

        // Capture return: after a 70 ms hold the victim walks HOME THE WAY IT CAME — backward
        // along the exact track cells it advanced through, then into its yard slot. A straight
        // arc across the board read as teleporting; retracing the route shows the player what
        // they just undid.
        val cap = move.captured
        if (cap != null) {
            delay(70)
            val fromC = centerOfPos(cap.from)
            val slot = layout.yardSlotCenter(cap.seat, cap.tokenId).let { Offset(it.first, it.second) }
            if (fromC != null) {
                val route = mutableListOf(fromC)
                val startIdx = LudoRules.startIndex(cap.seat)
                val travelled = ((cap.from - startIdx) % LudoRules.TRACK_COUNT +
                    LudoRules.TRACK_COUNT) % LudoRules.TRACK_COUNT
                for (step in 1..travelled) {
                    val idx = ((cap.from - step) % LudoRules.TRACK_COUNT +
                        LudoRules.TRACK_COUNT) % LudoRules.TRACK_COUNT
                    val c = LudoBoardGeometry.TRACK_COORDS[idx]
                    route += layout.rectOf(LudoBoardGeometry.cell(c.first, c.second)).center
                }
                route += slot

                // Fixed total duration, so a pawn sent back from two cells out and one sent
                // back from forty take about the same beat.
                val legs = route.size - 1
                val perLeg = kotlin.math.max(
                    LudoRules.CAPTURE_LEG_MIN_MS,
                    LudoRules.CAPTURE_RETURN_TOTAL_MS / legs,
                )
                val linear = CubicBezierEasing(0f, 0f, 1f, 1f)
                val settle = CubicBezierEasing(0.30f, 0f, 0.10f, 1f)
                for (i in 1 until route.size) {
                    val a = route[i - 1]
                    val b = route[i]
                    // The final leg leaves the track for the yard slot; ease it out so the pawn
                    // settles rather than slamming into its circle.
                    val isLast = i == route.size - 1
                    animate(
                        0f, 1f,
                        animationSpec = tween(
                            if (isLast) perLeg * 2 else perLeg,
                            easing = if (isLast) settle else linear,
                        ),
                    ) { v, _ ->
                        captureOverride = (cap.seat to cap.tokenId) to
                            Offset(a.x + (b.x - a.x) * v, a.y + (b.y - a.y) * v)
                    }
                }
            }
            captureOverride = null
        }
    }

    val boardColors = ludoPaletteFor(!com.voiid.app.ui.theme.isLightTheme())
    val darkTheme = !com.voiid.app.ui.theme.isLightTheme()

    // The perimeter clock needs a per-frame tick; otherwise the border only redraws when a new
    // server frame lands, so it would jump in whole seconds instead of shortening.
    var boardClock by remember { mutableStateOf<Float?>(null) }
    val clockRunning = !state.isFinished && state.turn?.deadlineAt != null && !reduceMotionEnabled
    LaunchedEffect(state.turn?.seat, state.turn?.deadlineAt, clockRunning) {
        if (!clockRunning) {
            boardClock = ringFractionFor(state, state.turn?.seat ?: -1)
            return@LaunchedEffect
        }
        while (true) {
            boardClock = ringFractionFor(state, state.turn?.seat ?: -1)
            delay(33)
        }
    }
    val boardClockTint = timerOverrideColor(state, state.turn?.seat ?: -1)

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
                timerFraction = boardClock,
                timerTint = boardClockTint,
            )
        }

        val turn = state.turn
        // Seat ownership is checked here as well as on the server so that tapping your own
        // colour during someone else's turn — including a bot's — does nothing at all rather
        // than firing an intent the server will reject.
        if (sidePx > 0 && turn?.phase == "awaitingMove" && state.viewerRole == "controller" &&
            state.viewerSeat == turn.seat &&
            state.seats.firstOrNull { it.seat == turn.seat }?.controller == "human") {
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

        // Explore-board overlay: per-cell semantic labels, opt-in so normal navigation never
        // walks 225 cells (§17).
        if (exploreBoard) {
            ExploreOverlay(state)
        }
    }
}

/** True when TalkBack (or another touch-exploration service) is driving the UI. */
private fun isScreenReaderOn(context: android.content.Context): Boolean {
    val am = context.getSystemService(android.content.Context.ACCESSIBILITY_SERVICE)
        as? android.view.accessibility.AccessibilityManager ?: return false
    return am.isEnabled && am.isTouchExplorationEnabled
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

/**
 * Identifies a decision window that has exactly one legal answer, for a seat this viewer
 * controls. Null whenever the player genuinely has a choice — or none at all.
 */
private fun forcedMoveKey(state: LudoGameState?): String? {
    if (state == null || state.isFinished) return null
    val turn = state.turn ?: return null
    if (turn.phase != "awaitingMove") return null
    if (state.viewerRole != "controller" || state.viewerSeat != turn.seat) return null
    if (state.seats.firstOrNull { it.seat == turn.seat }?.controller != "human") return null
    val only = turn.legalTokenIds.singleOrNull() ?: return null
    return "${turn.seat}:${turn.serial}:${turn.rollId ?: ""}:$only"
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

/**
 * The die itself, drawn inside its tray. At rest it is one flat face so the number stays crisp
 * and upright; the projected cube runs only while it is tumbling.
 */
@Composable
private fun DieFace(
    state: LudoGameState,
    rollVisual: LudoPresentationCoordinator.RollVisual?,
    onTap: () -> Unit,
    displayedValue: Int,
) {
    val darkNow = !com.voiid.app.ui.theme.isLightTheme()
    val dColors = ludoPaletteFor(darkNow)
    val canRoll = state.isActive &&
        state.turn?.phase == "awaitingRoll" &&
        state.viewerRole == "controller" &&
        state.viewerSeat == state.turn?.seat &&
        state.seats.firstOrNull { it.seat == state.viewerSeat }?.controller == "human"
    val pipsNeutral = state.turn == null || state.isFinished

    Canvas(
        Modifier
            .size(LudoDimens.dieSizeStandard)
            .clickable(enabled = canRoll, onClick = onTap)
            .semantics { contentDescription = LudoSemantics.dieLabel(state, displayedValue) },
    ) {
        val rv = rollVisual
        val pipColor = if (pipsNeutral) dColors.c(dColors.dieNeutralPip)
                       else dColors.hue(state.turn!!.seat)
        val restSide = size.width * LudoDie.REST_FILL_FACTOR
        with(LudoDie) {
            if (rv == null) {
                drawRestingDie(
                    sidePx = restSide,
                    value = displayedValue,
                    pipColor = pipColor,
                    edgeStrokePx = 1.25f,
                    colors = dColors,
                )
            } else {
                drawDie(
                    sidePx = restSide * rv.depthScale,
                    value = displayedValue,
                    rotationXDeg = rv.rotationX,
                    rotationYDeg = rv.rotationY,
                    translationYPx = rv.liftPx,
                    scaleX = rv.scaleX,
                    scaleY = rv.scaleY,
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
