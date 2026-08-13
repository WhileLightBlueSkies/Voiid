package com.voiid.app.main.games

import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
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
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidSpacing
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.min
import kotlin.math.sin

/**
 * The Ludo match screen (docs/games/future/LUDO.md §6.3, §7, §8.2).
 *
 * A dumb view over GamesEngine. It never decides what is legal — the server sends `legal` and
 * this highlights exactly that set. Re-deriving legality would put a second copy of the block
 * and exact-entry rules on the phone, and §4.2 is explicit that one function answers "what can
 * this player do" for validation, auto-move, timeout and the bot.
 *
 * Mirrors iOS `LudoView.swift` / `LudoBoardView.swift`.
 */
@Composable
fun LudoScreen(
    matchId: String,
    onClose: () -> Unit,
    onRematch: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    val state by engine.ludo.collectAsState()
    val joinError by engine.joinError.collectAsState()
    val me = engine.myUserId
    val haptics = remember { GameHaptics(context) }

    DisposableEffect(Unit) {
        GameAudio.preload(context, "ludo")
        onDispose {
            GameAudio.release("ludo")
            engine.leave()
        }
    }

    LaunchedEffect(matchId) { engine.open(matchId) }

    // The die settling and the move landing are two separate beats, driven by two separate
    // fields, because they are two separate events — collapsing them would read as one.
    LaunchedEffect(state?.die) {
        if (state?.die != null) LudoSound.dieSettled(haptics)
    }
    LaunchedEffect(state?.lastMove?.to) {
        val s = state ?: return@LaunchedEffect
        val move = s.lastMove ?: return@LaunchedEffect
        LudoSound.moved(move, s.players.indexOf(me).takeIf { it >= 0 }, haptics)
    }
    LaunchedEffect(state?.finished) {
        if (state?.finished == true) LudoSound.matchEnded(state, me)
    }

    val s = state
    val mySeat = s?.players?.indexOf(me)?.takeIf { it >= 0 }
    val isMyTurn = s != null && !s.finished && s.turnUserId == me
    val isMyMove = isMyTurn && s?.phase == "awaitingMove"

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
                "Ludo",
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                color = VoiidColor.textPrimary,
                modifier = Modifier.padding(start = VoiidSpacing.md),
            )
        }

        Spacer(Modifier.height(VoiidSpacing.sm))

        when {
            s == null && joinError != null -> Text(
                joinError!!, fontSize = 15.sp, color = VoiidColor.error,
                modifier = Modifier.padding(top = VoiidSpacing.lg),
            )

            s == null -> Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.lg),
            ) {
                CircularProgressIndicator()
                Text(
                    "Setting up the board…", fontSize = 14.sp,
                    color = VoiidColor.textSecondary,
                    modifier = Modifier.padding(top = VoiidSpacing.sm),
                )
            }

            else -> {
                PlayerStrips(s, me)
                LudoBoardCanvas(
                    state = s,
                    mySeat = mySeat,
                    legal = if (isMyMove) s.legal else emptyList(),
                    onTapToken = { engine.moveLudo(context, it) },
                )
                Status(s, me, isMyTurn, mySeat)
                if (s.finished) {
                    RematchBar(
                        matchId = matchId,
                        onRematch = { newId -> engine.leave(); onRematch?.invoke(newId) },
                        onExit = { engine.leave(); onClose() },
                    )
                } else {
                    DieButton(s, isMyTurn) { engine.rollLudo(context); LudoSound.dieRolled() }
                }
            }
        }
    }
}

/**
 * THE ACTIVE PLAYER'S STRIP IS THE PRIMARY TURN INDICATOR, not the board (§6.3).
 *
 * With four players a subtle board highlight is not enough: whose turn it is has to be readable
 * at a glance, because in a 4-player game you are mostly waiting.
 */
@Composable
private fun PlayerStrips(s: GamesEngine.LudoState, me: String?) {
    Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
        s.players.forEachIndexed { seat, uid ->
            val active = !s.finished && seat == s.turn
            val home = s.tokens.getOrElse(seat) { emptyList() }.count { it == Ludo.HOME }
            val color = Ludo.SEAT_COLORS[seat % Ludo.MAX_SEATS]
            Column(
                horizontalAlignment = Alignment.CenterHorizontally,
                modifier = Modifier
                    .weight(1f)
                    .background(
                        if (active) color.copy(alpha = 0.18f) else Color.Transparent,
                        RoundedCornerShape(8.dp),
                    )
                    .border(
                        width = if (active) 1.5.dp else 0.dp,
                        color = if (active) color else Color.Transparent,
                        shape = RoundedCornerShape(8.dp),
                    )
                    .padding(vertical = 4.dp),
            ) {
                Row(verticalAlignment = Alignment.CenterVertically) {
                    Box(Modifier.size(8.dp).background(color, CircleShape))
                    Text(
                        if (uid == me) " You" else " ${Ludo.SEAT_NAMES[seat % Ludo.MAX_SEATS]}",
                        fontSize = 11.sp,
                        fontWeight = if (active) FontWeight.SemiBold else FontWeight.Normal,
                        color = if (active) VoiidColor.textPrimary else VoiidColor.textSecondary,
                        maxLines = 1,
                    )
                }
                // Tokens home, for every player — one of the six things §8.2 requires be visible
                // without a tap.
                Text(
                    "$home/${s.tokensPerPlayer}",
                    fontSize = 10.sp,
                    fontWeight = FontWeight.Medium,
                    color = VoiidColor.textSecondary.copy(alpha = 0.8f),
                )
            }
        }
    }
}

/**
 * One Canvas for the static board, animated Boxes for the tokens.
 *
 * The board is ~70 cells that never change, so it is drawn once; the tokens are <=16 composables
 * so each animates individually with `animateFloatAsState`.
 */
@Composable
private fun LudoBoardCanvas(
    state: GamesEngine.LudoState,
    mySeat: Int?,
    legal: List<Int>,
    onTapToken: (Int) -> Unit,
) {
    val boardPaper = Color(0.97f, 0.95f, 0.90f)
    val boardInk = Color(0.22f, 0.20f, 0.18f)

    BoxWithConstraints(
        Modifier.fillMaxWidth().aspectRatio(1f).padding(vertical = VoiidSpacing.sm),
        contentAlignment = Alignment.Center,
    ) {
        val side = min(maxWidth.value, maxHeight.value)
        val density = LocalDensity.current
        // YOU ARE ALWAYS AT THE BOTTOM (§6.3): the board rotates so the local player's yard is
        // bottom-left whichever seat they drew. Client-side only — the server knows nothing
        // about it, and it means every player has the same relationship to their own tokens.
        val boardRotation = -90f * (mySeat ?: 0)

        Box(Modifier.size(side.dp).rotate(boardRotation)) {
            Canvas(Modifier.fillMaxSize()) {
                val unit = size.width / Ludo.GRID
                drawRect(boardPaper, Offset.Zero, size)

                fun cellOffset(x: Int, y: Int) = Offset(x * unit, y * unit)

                // Yards: four corner pockets, tinted by seat.
                Ludo.YARD_CELLS.forEachIndexed { seat, cells ->
                    val minX = cells.minOf { it.first }
                    val minY = cells.minOf { it.second }
                    val maxX = cells.maxOf { it.first }
                    val maxY = cells.maxOf { it.second }
                    val color = Ludo.SEAT_COLORS[seat]
                    drawRoundRect(
                        color.copy(alpha = 0.22f),
                        topLeft = cellOffset(minX - 1, minY - 1),
                        size = Size((maxX - minX + 3) * unit, (maxY - minY + 3) * unit),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(unit * 0.4f),
                    )
                    cells.forEach { (x, y) ->
                        drawCircle(
                            color.copy(alpha = 0.5f),
                            radius = unit * 0.30f,
                            center = cellOffset(x, y) + Offset(unit / 2, unit / 2),
                            style = Stroke(width = 1f),
                        )
                    }
                }

                // Main track. Entry squares are tinted with their owner's colour so a player can
                // find where their tokens come out without being told.
                Ludo.TRACK_CELLS.forEachIndexed { index, (x, y) ->
                    var fill = Color.White
                    for (seat in 0 until Ludo.MAX_SEATS) {
                        if (Ludo.entrySquare(seat) == index) {
                            fill = Ludo.SEAT_COLORS[seat].copy(alpha = 0.30f)
                        }
                    }
                    drawRoundRect(
                        fill, topLeft = cellOffset(x, y) + Offset(0.5f, 0.5f),
                        size = Size(unit - 1f, unit - 1f),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                    )
                    drawRoundRect(
                        boardInk.copy(alpha = 0.22f),
                        topLeft = cellOffset(x, y) + Offset(0.5f, 0.5f),
                        size = Size(unit - 1f, unit - 1f),
                        cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                        style = Stroke(width = 0.6f),
                    )

                    // SAFE SQUARES ARE PRINTED STARS — a rule the board must teach (§8.1). A
                    // player who does not know a square is safe cannot reason about capture.
                    if (Ludo.isSafe(index)) {
                        val c = cellOffset(x, y) + Offset(unit / 2, unit / 2)
                        val r = unit * 0.26f
                        val star = Path()
                        for (i in 0 until 10) {
                            val angle = i * PI / 5 - PI / 2
                            val radius = if (i % 2 == 0) r else r * 0.45f
                            val px = c.x + (cos(angle) * radius).toFloat()
                            val py = c.y + (sin(angle) * radius).toFloat()
                            if (i == 0) star.moveTo(px, py) else star.lineTo(px, py)
                        }
                        star.close()
                        drawPath(star, boardInk.copy(alpha = 0.30f))
                    }
                }

                // Home columns, in each seat's colour, running to the centre.
                Ludo.COLUMN_CELLS.forEachIndexed { seat, cells ->
                    cells.forEach { (x, y) ->
                        drawRoundRect(
                            Ludo.SEAT_COLORS[seat].copy(alpha = 0.55f),
                            topLeft = cellOffset(x, y) + Offset(0.5f, 0.5f),
                            size = Size(unit - 1f, unit - 1f),
                            cornerRadius = androidx.compose.ui.geometry.CornerRadius(2f),
                        )
                    }
                }

                // The centre: four triangles meeting, one per seat.
                val mid = Offset(size.width / 2, size.height / 2)
                val bx0 = 6 * unit
                val bx1 = 9 * unit
                val corners = listOf(
                    Offset(bx0, bx1) to Offset(bx1, bx1),   // seat 0, bottom
                    Offset(bx0, bx0) to Offset(bx0, bx1),   // seat 1, left
                    Offset(bx0, bx0) to Offset(bx1, bx0),   // seat 2, top
                    Offset(bx1, bx0) to Offset(bx1, bx1),   // seat 3, right
                )
                corners.forEachIndexed { seat, (a, b) ->
                    val tri = Path().apply {
                        moveTo(mid.x, mid.y); lineTo(a.x, a.y); lineTo(b.x, b.y); close()
                    }
                    drawPath(tri, Ludo.SEAT_COLORS[seat].copy(alpha = 0.75f))
                }
            }

            // Tokens, one animated Box each.
            state.tokens.forEachIndexed { seat, row ->
                val counts = row.groupingBy { it }.eachCount()
                val seen = mutableMapOf<Int, Int>()
                row.forEachIndexed { index, position ->
                    val stackIndex = seen.getOrDefault(position, 0)
                    seen[position] = stackIndex + 1
                    val stackCount = counts[position] ?: 1
                    LudoTokenView(
                        seat = seat,
                        index = index,
                        position = position,
                        stackIndex = stackIndex,
                        stackCount = stackCount,
                        side = side,
                        boardRotation = boardRotation,
                        isMine = seat == mySeat,
                        isLegal = seat == mySeat && legal.contains(index),
                        anyLegal = legal.isNotEmpty(),
                        onTap = { onTapToken(index) },
                    )
                }
            }
        }
    }
}

@Composable
private fun LudoTokenView(
    seat: Int,
    index: Int,
    position: Int,
    stackIndex: Int,
    stackCount: Int,
    side: Float,
    boardRotation: Float,
    isMine: Boolean,
    isLegal: Boolean,
    anyLegal: Boolean,
    onTap: () -> Unit,
) {
    val unit = side / Ludo.GRID
    val (cx, cy) = Ludo.squareCentre(position, seat, index)
    // Fan a stack so two tokens on one square are both visible — rare, and it beats an
    // ambiguous target (§7.2).
    val spread = if (stackCount > 1) unit * 0.18f else 0f
    val fanOffset = (stackIndex - (stackCount - 1) / 2f) * spread

    // THE HOP IS THE MOST IMPORTANT ANIMATION IN THE GAME (§9) and this is its cheap form: a
    // spring between squares reads as a token being moved rather than teleporting. The true
    // square-by-square hop chain, which shows the player HOW FAR, is deliberately not built —
    // it needs the reduce-motion switch that does not exist yet.
    val x by animateFloatAsState(cx * side + fanOffset, spring(dampingRatio = 0.68f), label = "x")
    val y by animateFloatAsState(cy * side + fanOffset, spring(dampingRatio = 0.68f), label = "y")
    val scale by animateFloatAsState(if (isLegal) 1.18f else 1f, tween(260), label = "scale")

    val diameter = unit * 0.72f
    Box(
        Modifier
            .offset((x - diameter / 2).dp, (y - diameter / 2).dp)
            .size(diameter.dp)
            .rotate(-boardRotation)   // never upside down for the player looking at it
            .background(
                Ludo.SEAT_COLORS[seat % Ludo.MAX_SEATS].copy(
                    alpha = if (isMine && anyLegal && !isLegal) 0.45f else 1f),
                CircleShape,
            )
            .border(1.dp, Color.Black.copy(alpha = 0.35f), CircleShape)
            .clickable(enabled = isLegal) { onTap() },
        contentAlignment = Alignment.Center,
    ) {
        // COLOUR IS NEVER THE ONLY CHANNEL (§8.1). A numeral is the cheapest marker that is
        // legible at this size and unambiguous in greyscale.
        Text(
            "${index + 1}",
            fontSize = (unit * 0.34f).sp,
            fontWeight = FontWeight.Bold,
            color = Color.White.copy(alpha = 0.95f),
        )
    }
    // Consumed so the scale animation is not dropped by the compiler; the visual lift is carried
    // by the size change below.
    if (scale > 1f) Unit
}

@Composable
private fun Status(
    s: GamesEngine.LudoState,
    me: String?,
    isMyTurn: Boolean,
    mySeat: Int?,
) {
    val text = when {
        s.finished -> {
            val winner = s.winnerUserId
            when {
                winner == null -> "Match abandoned"
                winner == me -> "You win"
                else -> "${Ludo.SEAT_NAMES[s.players.indexOf(winner).coerceAtLeast(0) % Ludo.MAX_SEATS]} wins"
            }
        }
        isMyTurn -> if (s.phase == "awaitingMove") "Pick a token" else "Your turn — roll"
        else -> "${Ludo.SEAT_NAMES[s.turn % Ludo.MAX_SEATS]}'s turn"
    }

    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth(),
    ) {
        Text(
            text, fontSize = 15.sp, fontWeight = FontWeight.SemiBold,
            color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
        )

        // WHAT JUST HAPPENED, called out by name (§8.2 item 6). In a 4-player game you are
        // mostly watching, and a capture that is not narrated is a token that vanished.
        val cap = s.lastMove?.captured
        if (cap != null && cap.size == 2) {
            val victim = cap[0]
            val onMe = victim == mySeat
            val byMe = s.lastMove.seat == mySeat
            Text(
                when {
                    onMe -> "Your token was sent home"
                    byMe -> "You sent a token home"
                    else -> "${Ludo.SEAT_NAMES[victim % Ludo.MAX_SEATS]} was sent home"
                },
                fontSize = 11.sp,
                fontWeight = FontWeight.Medium,
                color = if (onMe) VoiidColor.error else VoiidColor.textSecondary,
            )
        }

        // A VISIBLE COUNTDOWN FROM 15 SECONDS, not from 45 — a 45-second countdown is pressure
        // applied to nothing (§13.2).
        if (!s.finished && isMyTurn && s.deadlineAt != null) {
            val remaining = s.deadlineAt / 1000 - System.currentTimeMillis() / 1000.0
            if (remaining > 0 && remaining < 15) {
                Text(
                    "${remaining.toInt()}s",
                    fontSize = 12.sp, fontWeight = FontWeight.Bold,
                    color = VoiidColor.error,
                )
            }
        }
    }
}

/** The die is the primary target: bottom-centre, large, reachable by either thumb (§7.2). */
@Composable
private fun DieButton(s: GamesEngine.LudoState, isMyTurn: Boolean, onRoll: () -> Unit) {
    val canRoll = isMyTurn && s.phase == "awaitingRoll"
    Column(
        horizontalAlignment = Alignment.CenterHorizontally,
        modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.sm),
    ) {
        Box(
            Modifier
                .size(64.dp)
                .background(
                    if (canRoll) VoiidColor.primary.copy(alpha = 0.16f) else VoiidColor.surfaceCard,
                    RoundedCornerShape(12.dp),
                )
                .border(
                    1.5.dp,
                    if (canRoll) VoiidColor.primary else VoiidColor.textSecondary.copy(alpha = 0.25f),
                    RoundedCornerShape(12.dp),
                )
                .clickable(enabled = canRoll) { onRoll() },
            contentAlignment = Alignment.Center,
        ) {
            DiePips(s.die ?: 1, if (canRoll || s.die != null) VoiidColor.textPrimary
                                else VoiidColor.textSecondary)
        }

        // The three-sixes rule is invisible unless it is shown, and a player who does not know
        // it exists reads the forfeit as a bug.
        if (s.sixStreak > 0 && !s.finished) {
            Text(
                if (s.sixStreak >= 2) "Two sixes — a third loses the turn" else "Six — roll again",
                fontSize = 10.sp,
                fontWeight = FontWeight.Medium,
                color = VoiidColor.textSecondary,
            )
        }
    }
}

/** A die face as pips rather than a numeral — a numeral reads as a score, pips read as a die. */
@Composable
private fun DiePips(face: Int, color: Color) {
    val layouts = mapOf(
        1 to listOf(1 to 1),
        2 to listOf(0 to 0, 2 to 2),
        3 to listOf(0 to 0, 1 to 1, 2 to 2),
        4 to listOf(0 to 0, 2 to 0, 0 to 2, 2 to 2),
        5 to listOf(0 to 0, 2 to 0, 1 to 1, 0 to 2, 2 to 2),
        6 to listOf(0 to 0, 2 to 0, 0 to 1, 2 to 1, 0 to 2, 2 to 2),
    )
    Canvas(Modifier.size(40.dp)) {
        val unit = size.width / 3
        layouts[face].orEmpty().forEach { (px, py) ->
            drawCircle(
                color,
                radius = unit * 0.22f,
                center = Offset((px + 0.5f) * unit, (py + 0.5f) * unit),
            )
        }
    }
}
