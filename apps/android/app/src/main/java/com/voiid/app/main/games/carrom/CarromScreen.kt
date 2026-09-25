package com.voiid.app.main.games.carrom

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.gestures.detectDragGestures
import androidx.compose.foundation.gestures.detectTapGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.layout.navigationBarsPadding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowLeft
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Bolt
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.EmojiEvents
import androidx.compose.material.icons.filled.Info
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.Slider
import androidx.compose.material3.SliderDefaults
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.runtime.withFrameNanos
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.shadow
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import androidx.compose.ui.graphics.drawscope.scale
import androidx.compose.ui.graphics.drawscope.translate
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.repeatOnLifecycle
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.components.VoiidDialog
import com.voiid.app.ui.components.softClickable
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidFont
import kotlin.math.PI
import kotlin.math.abs
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/** Port of iOS `CarromGameView.swift` + `CarromBoardView.swift`. You play white vs the bot. */
@Composable
fun CarromScreen(botDifficulty: Int = 2, onClose: () -> Unit) {
    val haptics = LocalVoiidHaptics.current
    val game = remember { CarromGame(haptics, botDifficulty) }
    var confirmQuit by remember { mutableStateOf(false) }
    val lifecycle = LocalLifecycleOwner.current

    // Physics and delayed turns run only while the screen is resumed and not paused by a dialog.
    LaunchedEffect(confirmQuit) {
        if (confirmQuit) { game.pauseClock(); return@LaunchedEffect }
        lifecycle.lifecycle.repeatOnLifecycle(Lifecycle.State.RESUMED) {
            try { while (true) withFrameNanos { game.stepFrame(it) } } finally { game.pauseClock() }
        }
    }
    BackHandler { confirmQuit = true }

    BoxWithConstraints(Modifier.fillMaxSize().background(VoiidColor.background)) {
        val boardSize = min(maxWidth.value - 32f, min(max(maxHeight.value, 620f) * 0.49f, 440f)).dp
        Column(
            Modifier.fillMaxSize().statusBarsPadding().navigationBarsPadding()
                .verticalScroll(rememberScrollState()).padding(horizontal = 10.dp, vertical = 6.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
        ) {
            TopBar(game, onBack = { confirmQuit = true })
            Scoreboard(game)
            Spacer(Modifier.height(4.dp))
            Box(Modifier.size(boardSize), contentAlignment = Alignment.TopCenter) {
                CarromBoard(game, boardSize.value)
                game.banner?.let { BannerToast(it) }
            }
            Spacer(Modifier.height(4.dp))
            BottomControls(game)
        }
        (game.phase as? CarromPhase.GameOver)?.let { GameOverOverlay(game, it.winner, onClose) }
    }

    if (confirmQuit) VoiidDialog(
        onDismissRequest = { confirmQuit = false },
        title = "Leave Carrom?",
        body = "Your current match progress will be lost.",
        confirmLabel = "Leave Game",
        onConfirm = { confirmQuit = false; onClose() },
        confirmDestructive = true,
        cancelLabel = "Keep Playing",
    )
}

@Composable
private fun CircleButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, tint: Color, onClick: () -> Unit) {
    Box(
        Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.surfaceCard)
            .border(1.dp, VoiidColor.divider, CircleShape).softClickable(onClick = onClick)
            .semantics { contentDescription = label },
        contentAlignment = Alignment.Center,
    ) { Icon(icon, null, tint = tint, modifier = Modifier.size(20.dp)) }
}

@Composable
private fun TopBar(game: CarromGame, onBack: () -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        CircleButton(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Leave Carrom", VoiidColor.textPrimary, onBack)
        Spacer(Modifier.weight(1f))
        Row(
            Modifier.clip(CircleShape).background(VoiidColor.surfaceCard).border(1.dp, VoiidColor.divider, CircleShape)
                .padding(horizontal = 8.dp, vertical = 6.dp),
            verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp),
        ) {
            Text("CLASSIC", style = VoiidFont.rounded(11, FontWeight.Bold), color = VoiidColor.textSecondary)
            Box(Modifier.size(4.dp).clip(CircleShape).background(VoiidColor.divider))
            when (val q = game.queenState) {
                QueenState.OnBoard -> Text("Queen: In Play", style = VoiidFont.rounded(11, FontWeight.SemiBold), color = Color(0xFFC62828))
                is QueenState.PendingCover -> Text("${if (q.by == CarromTurn.PLAYER1) "You" else "Bot"}: Cover Queen!",
                    style = VoiidFont.rounded(11, FontWeight.ExtraBold), color = Color(0xFFF59E0B))
                is QueenState.Covered -> Text("Queen: ${if (q.by == CarromTurn.PLAYER1) "You" else "Bot"}",
                    style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.textSecondary)
            }
        }
        Spacer(Modifier.weight(1f))
        CircleButton(Icons.Default.Refresh, "Restart Carrom", VoiidColor.textSecondary) { game.resetBoard() }
    }
}

@Composable
private fun Scoreboard(game: CarromGame) {
    Row(Modifier.fillMaxWidth().padding(horizontal = 4.dp), verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(12.dp)) {
        PlayerCard("You", "White", CarromTheme.whiteMain, game.player1Score, game.turn == CarromTurn.PLAYER1, VoiidColor.accent, Modifier.weight(1f))
        Text("VS", style = VoiidFont.rounded(11, FontWeight.Bold), color = VoiidColor.textSecondary)
        PlayerCard("Bot", "Black", CarromTheme.blackMain, game.player2Score, game.turn == CarromTurn.PLAYER2, Color(0xFFE0503F), Modifier.weight(1f))
    }
}

@Composable
private fun PlayerCard(name: String, colour: String, disc: Color, score: Int, active: Boolean, tint: Color, modifier: Modifier) {
    val shape = RoundedCornerShape(14.dp)
    Row(
        modifier.clip(shape).background(VoiidColor.surfaceCard)
            .border(if (active) 1.5.dp else 1.dp, if (active) tint else VoiidColor.divider, shape)
            .padding(horizontal = 12.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(name, style = VoiidFont.rounded(12.5f, FontWeight.SemiBold),
                color = if (active) VoiidColor.textPrimary else VoiidColor.textSecondary)
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(4.dp)) {
                Box(Modifier.size(12.dp).clip(CircleShape).background(disc)
                    .border(1.dp, VoiidColor.textSecondary.copy(alpha = 0.5f), CircleShape))
                Text(colour, style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.textSecondary)
            }
        }
        Text("$score/9", style = VoiidFont.rounded(18, FontWeight.ExtraBold),
            color = if (active) VoiidColor.textPrimary else VoiidColor.textSecondary)
    }
}

@Composable
private fun BannerToast(b: CarromBanner) {
    Row(
        Modifier.padding(top = 14.dp).shadow(10.dp, CircleShape).clip(CircleShape)
            .background(Color.Black.copy(alpha = 0.88f)).padding(horizontal = 16.dp, vertical = 9.dp),
        verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        val (icon, tint) = when (b.type) {
            CarromBannerType.SUCCESS -> Icons.Default.CheckCircle to Color(0xFF34C759)
            CarromBannerType.FOUL -> Icons.Default.Warning to Color(0xFFFF3B30)
            CarromBannerType.INFO -> Icons.Default.Info to Color(0xFFFFCC00)
        }
        Icon(icon, null, tint = tint, modifier = Modifier.size(16.dp))
        Text(b.text, style = VoiidFont.rounded(13, FontWeight.Bold), color = Color.White)
    }
}

@Composable
private fun BottomControls(game: CarromGame) {
    Column(Modifier.fillMaxWidth().padding(horizontal = 6.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
        val shape = RoundedCornerShape(14.dp)
        Column(
            Modifier.fillMaxWidth().clip(shape).background(VoiidColor.surfaceCard).border(1.dp, VoiidColor.divider, shape)
                .padding(horizontal = 14.dp, vertical = 6.dp),
        ) {
            Row(Modifier.fillMaxWidth()) {
                Text("Baseline Position", style = VoiidFont.rounded(11, FontWeight.SemiBold), color = VoiidColor.textSecondary)
                Spacer(Modifier.weight(1f))
                if (!game.isPlacementValid) Text("Blocked (Overlap)", style = VoiidFont.rounded(11, FontWeight.Bold), color = Color.Red)
                else Text("Aim & Strike", style = VoiidFont.rounded(11, FontWeight.Medium), color = VoiidColor.accent)
            }
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                NudgeButton(Icons.AutoMirrored.Filled.KeyboardArrowLeft, "Move striker left", game.canControl) { game.nudgeBaseline(-0.04f) }
                Slider(
                    value = game.baselineNormX, onValueChange = { game.updateBaselineSlider(it) },
                    enabled = game.canControl, modifier = Modifier.weight(1f),
                    colors = SliderDefaults.colors(
                        thumbColor = if (game.isPlacementValid) VoiidColor.accent else Color.Red,
                        activeTrackColor = if (game.isPlacementValid) VoiidColor.accent else Color.Red,
                        inactiveTrackColor = VoiidColor.fieldFill, inactiveTickColor = Color.Transparent, activeTickColor = Color.Transparent),
                )
                NudgeButton(Icons.AutoMirrored.Filled.KeyboardArrowRight, "Move striker right", game.canControl) { game.nudgeBaseline(0.04f) }
            }
        }

        if (game.turn == CarromTurn.PLAYER1) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(10.dp)) {
                val s12 = RoundedCornerShape(12.dp)
                Column(Modifier.weight(1f).clip(s12).background(VoiidColor.surfaceCard).border(1.dp, VoiidColor.divider, s12)
                    .padding(horizontal = 12.dp, vertical = 6.dp)) {
                    Row(Modifier.fillMaxWidth()) {
                        Text("POWER", style = VoiidFont.rounded(9.5f, FontWeight.Bold), color = VoiidColor.textSecondary)
                        Spacer(Modifier.weight(1f))
                        Text("${(max(game.shotPower, 0.20f) * 100).toInt()}%", style = VoiidFont.rounded(11, FontWeight.ExtraBold), color = VoiidColor.textPrimary)
                    }
                    Slider(value = max(game.shotPower, 0.20f), onValueChange = { game.changeShotPower(it) }, valueRange = 0.20f..1f,
                        enabled = game.canControl,
                        colors = SliderDefaults.colors(thumbColor = VoiidColor.accent, activeTrackColor = VoiidColor.accent,
                            inactiveTrackColor = VoiidColor.fieldFill, inactiveTickColor = Color.Transparent, activeTickColor = Color.Transparent))
                }
                val live = game.isPlacementValid && game.canControl
                Row(
                    Modifier.width(106.dp).height(48.dp).clip(CircleShape)
                        .background(if (live) Brush.linearGradient(listOf(VoiidColor.accent, Color(0xFF0EA5E9)))
                            else Brush.linearGradient(listOf(VoiidColor.surfaceRaised, VoiidColor.surfaceRaised)))
                        .softClickable(enabled = live) { game.fireStrike() },
                    horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically,
                ) {
                    val c = if (live) VoiidColor.textOnAccent else Color.Gray
                    Icon(Icons.Default.Bolt, null, tint = c, modifier = Modifier.size(16.dp))
                    Spacer(Modifier.width(6.dp))
                    Text("STRIKE", style = VoiidFont.rounded(14, FontWeight.ExtraBold), color = c)
                }
            }
        } else {
            Row(Modifier.fillMaxWidth().height(48.dp).clip(RoundedCornerShape(12.dp)).background(VoiidColor.surfaceCard),
                horizontalArrangement = Arrangement.Center, verticalAlignment = Alignment.CenterVertically) {
                CircularProgressIndicator(color = Color(0xFFE0503F), strokeWidth = 2.dp, modifier = Modifier.size(18.dp))
                Spacer(Modifier.width(8.dp))
                Text(if (game.phase == CarromPhase.InMotion) "Pieces in motion..." else "Carrom Bot is calculating angle...",
                    style = VoiidFont.rounded(12, FontWeight.Medium), color = VoiidColor.textSecondary)
            }
        }
    }
}

@Composable
private fun NudgeButton(icon: androidx.compose.ui.graphics.vector.ImageVector, label: String, enabled: Boolean, onClick: () -> Unit) {
    Box(Modifier.size(44.dp).clip(CircleShape).background(VoiidColor.surfaceRaised)
        .softClickable(enabled = enabled, onClick = onClick).semantics { contentDescription = label },
        contentAlignment = Alignment.Center) {
        Icon(icon, null, tint = VoiidColor.textPrimary, modifier = Modifier.size(20.dp))
    }
}

@Composable
private fun GameOverOverlay(game: CarromGame, winner: String, onExit: () -> Unit) {
    Box(Modifier.fillMaxSize().background(Color.Black.copy(alpha = 0.72f)), contentAlignment = Alignment.Center) {
        val shape = RoundedCornerShape(24.dp)
        Column(
            Modifier.padding(horizontal = 28.dp).clip(shape).background(VoiidColor.surfaceCard)
                .border(1.dp, VoiidColor.divider, shape).padding(26.dp),
            horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(14.dp),
        ) {
            Icon(Icons.Default.EmojiEvents, null, tint = Color(0xFFF59E0B), modifier = Modifier.size(48.dp))
            Text(if (winner == "You") "You Win!" else "$winner Wins!", style = VoiidFont.rounded(26, FontWeight.Bold), color = VoiidColor.textPrimary)
            Text("Pocketed: ${game.player1Score} white · ${game.player2Score} black",
                style = VoiidFont.rounded(15, FontWeight.SemiBold), color = VoiidColor.textSecondary)
            Row(Modifier.padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(12.dp)) {
                Box(Modifier.weight(1f).height(46.dp).clip(CircleShape).background(VoiidColor.accent)
                    .softClickable { game.resetBoard() }, contentAlignment = Alignment.Center) {
                    Text("Play Again", style = VoiidFont.rounded(15, FontWeight.Bold), color = VoiidColor.textOnAccent)
                }
                Box(Modifier.weight(1f).height(46.dp).clip(CircleShape).background(VoiidColor.surfaceRaised)
                    .softClickable(onClick = onExit), contentAlignment = Alignment.Center) {
                    Text("Exit", style = VoiidFont.rounded(15, FontWeight.Bold), color = VoiidColor.textPrimary)
                }
            }
        }
    }
}

// ─────────────────────────────── Board ───────────────────────────────

@Composable
private fun CarromBoard(game: CarromGame, sizeDp: Float) {
    var dragStart by remember { mutableStateOf<Vec?>(null) }
    var slingshot by remember { mutableStateOf(false) }
    val total = CarromTheme.TOTAL
    val ft = CarromTheme.FRAME

    Canvas(
        Modifier.size(sizeDp.dp)
            .shadow(20.dp, RoundedCornerShape((22 * sizeDp / total).dp))
            .clip(RoundedCornerShape((22 * sizeDp / total).dp))
            .pointerInput(game) {
                fun toSurface(o: Offset): Vec {
                    val s = size.width / total
                    return Vec(o.x / s - ft, o.y / s - ft)
                }
                fun handle(pt: Vec, first: Boolean) {
                    if (!game.canControl) return
                    val strikerPos = game.world.pieces.first { it.type == CarromPieceType.STRIKER }.position
                    val baseY = CarromEngine.baselineY(game.turn)
                    if (first) {
                        dragStart = pt
                        val nearBaseline = abs(pt.y - baseY) < 28f
                        slingshot = if (pt.distance(strikerPos) < CarromTheme.STRIKER_RADIUS * 2.2f || nearBaseline) false
                        else if (pt.y > strikerPos.y && game.turn == CarromTurn.PLAYER1) true
                        else { game.setAimPoint(pt); false }
                    }
                    val draggingBaseline = abs(pt.y - baseY) < 30f && !slingshot
                    when {
                        draggingBaseline -> game.updateBaselineSlider(
                            (pt.x - CarromEngine.BASELINE_MIN_X) / (CarromEngine.BASELINE_MAX_X - CarromEngine.BASELINE_MIN_X))
                        pt.y > strikerPos.y + 12f && game.turn == CarromTurn.PLAYER1 -> {
                            slingshot = true
                            game.updateAimGesture(pt.x - strikerPos.x, pt.y - strikerPos.y)
                        }
                        else -> { slingshot = false; game.setAimPoint(pt) }
                    }
                }
                detectDragGestures(
                    onDragStart = { handle(toSurface(it), first = true) },
                    onDrag = { change, _ -> handle(toSurface(change.position), first = false) },
                    onDragEnd = {
                        val was = slingshot
                        dragStart = null; slingshot = false
                        if (was && game.phase == CarromPhase.Aiming && game.shotPower > 0.15f) game.releaseStrike()
                    },
                    onDragCancel = { dragStart = null; slingshot = false },
                )
            }
            .pointerInput(game) {
                // A plain tap aims straight at the finger, as the iOS minimum-distance-0 drag does.
                detectTapGestures { o: Offset ->
                    val s = size.width / total
                    if (game.canControl) game.setAimPoint(Vec(o.x / s - ft, o.y / s - ft))
                }
            },
    ) {
        @Suppress("UNUSED_VARIABLE") val t = game.tick   // redraw each simulated frame
        val s = size.width / total
        scale(s, s, pivot = Offset.Zero) {
            drawFrame()
            drawSurface()
            drawMarkings()
            drawPockets(game)
            val aim = game.aimResult
            if ((game.phase == CarromPhase.Aiming || game.phase == CarromPhase.Placement) && aim != null) drawAim(game, aim)
            drawPieces(game)
        }
    }
}

private fun v(x: Float, y: Float) = Offset(x, y)

private fun DrawScope.drawFrame() {
    val t = CarromTheme.TOTAL
    drawRoundRect(Brush.linearGradient(listOf(CarromTheme.frameWoodLight, CarromTheme.frameWoodDark), v(0f, 0f), v(t, t)),
        size = Size(t, t), cornerRadius = CornerRadius(22f))
    drawRoundRect(CarromTheme.frameWoodLight.copy(alpha = 0.6f), size = Size(t, t), cornerRadius = CornerRadius(22f), style = Stroke(1.5f))
    listOf(v(16f, 16f) to 0f, v(t - 16, 16f) to 90f, v(t - 16, t - 16) to 180f, v(16f, t - 16) to -90f).forEach { (c, deg) ->
        translate(c.x, c.y) {
            rotate(deg, pivot = Offset.Zero) {
                val p = Path().apply {
                    moveTo(-8f, -8f); lineTo(14f, -8f); lineTo(14f, -4f); lineTo(-4f, -4f); lineTo(-4f, 14f); lineTo(-8f, 14f); close()
                }
                drawPath(p, Brush.linearGradient(listOf(CarromTheme.brassHighlight, CarromTheme.brassBase, CarromTheme.brassShadow), v(-8f, -8f), v(14f, 14f)))
            }
        }
    }
}

private fun DrawScope.drawSurface() {
    val ft = CarromTheme.FRAME; val s = CarromTheme.SURFACE
    drawRoundRect(
        Brush.radialGradient(listOf(CarromTheme.woodLight, CarromTheme.woodMid, CarromTheme.woodDark), v(ft + s / 2, ft + s / 2), s * 0.72f),
        topLeft = v(ft, ft), size = Size(s, s), cornerRadius = CornerRadius(4f))
    drawRoundRect(CarromTheme.cushionRubber, topLeft = v(ft, ft), size = Size(s, s), cornerRadius = CornerRadius(4f), style = Stroke(2f))
}

private fun DrawScope.drawMarkings() {
    val ft = CarromTheme.FRAME
    val c = v(ft + CarromTheme.SURFACE / 2, ft + CarromTheme.SURFACE / 2)
    drawCircle(CarromTheme.boardLine, CarromTheme.CENTER_OUTER, c, style = Stroke(1.2f))
    drawCircle(CarromTheme.baseCircleRed.copy(alpha = 0.2f), CarromTheme.CENTER_INNER, c)
    drawCircle(CarromTheme.baseCircleRed, CarromTheme.CENTER_INNER, c, style = Stroke(1.5f))
    for (i in 0 until 8) {
        val a = (i * PI / 4).toFloat()
        drawLine(CarromTheme.boardLineLo, c + Offset(cos(a), sin(a)) * CarromTheme.CENTER_INNER,
            c + Offset(cos(a), sin(a)) * CarromTheme.CENTER_OUTER, 1f)
    }
    val t = CarromTheme.TOTAL
    listOf(0f, 180f, 90f, -90f).forEach { deg ->
        rotate(deg, pivot = v(t / 2, t / 2)) {
            val minX = ft + CarromEngine.BASELINE_MIN_X; val maxX = ft + CarromEngine.BASELINE_MAX_X
            val y = ft + CarromEngine.baselineY(CarromTurn.PLAYER1)
            val hw = CarromTheme.BASELINE_WIDTH / 2
            drawLine(CarromTheme.boardLine, v(minX, y - hw), v(maxX, y - hw), 1.2f)
            drawLine(CarromTheme.boardLine, v(minX, y + hw), v(maxX, y + hw), 1.2f)
            val cr = CarromTheme.BASELINE_CIRCLE_RADIUS
            for (x in listOf(minX, maxX)) {
                drawCircle(CarromTheme.baseCircleRed, cr, v(x, y))
                drawCircle(CarromTheme.boardLine, cr, v(x, y), style = Stroke(1f))
            }
        }
    }
    listOf(-0.75f, -0.25f, 0.25f, 0.75f).forEach { f ->
        val a = (PI * f).toFloat()
        val p1 = c + Offset(cos(a), sin(a)) * (CarromTheme.CENTER_OUTER + 14f)
        val p2 = c + Offset(cos(a), sin(a)) * (CarromTheme.SURFACE * 0.52f)
        drawLine(CarromTheme.boardLineLo, p1, p2, 1f)
        drawCircle(CarromTheme.boardLine, 4f, p2, style = Stroke(1f))
    }
}

private fun DrawScope.drawPockets(game: CarromGame) {
    val ft = CarromTheme.FRAME
    for (p in game.world.pocketCenters) {
        val c = v(ft + p.x, ft + p.y)
        drawCircle(CarromTheme.pocketWell, CarromTheme.POCKET_RADIUS, c)
        drawCircle(Color.Black.copy(alpha = 0.9f), CarromTheme.POCKET_RADIUS, c, style = Stroke(2f))
    }
}

private fun DrawScope.drawPieces(game: CarromGame) {
    val ft = CarromTheme.FRAME
    for (piece in game.world.pieces) {
        if (piece.isPocketed) continue
        val cx = ft + piece.position.x; val cy = ft + piece.position.y
        val r = piece.radius * (1f - piece.sinkProgress * 0.6f)
        val alpha = 1f - piece.sinkProgress
        val c = v(cx, cy)
        val hl = v(cx - r * 0.25f, cy - r * 0.25f)
        if (piece.sinkProgress == 0f) drawCircle(Color.Black.copy(alpha = 0.28f), r, v(cx, cy + 3f))
        when (piece.type) {
            CarromPieceType.WHITE -> {
                drawCircle(Brush.radialGradient(listOf(CarromTheme.whiteMain, CarromTheme.whiteRing, CarromTheme.whiteCore), hl, r), r, c, alpha)
                drawCircle(CarromTheme.whiteCore.copy(alpha = 0.8f), r * 0.55f, c, alpha, Stroke(1f))
            }
            CarromPieceType.BLACK -> {
                drawCircle(Brush.radialGradient(listOf(CarromTheme.blackRing, CarromTheme.blackMain, CarromTheme.blackCore), hl, r), r, c, alpha)
                drawCircle(Color.White.copy(alpha = 0.18f), r * 0.55f, c, alpha, Stroke(1f))
            }
            CarromPieceType.QUEEN -> {
                drawCircle(Brush.radialGradient(listOf(CarromTheme.queenRing, CarromTheme.queenMain), hl, r), r, c, alpha)
                drawCircle(CarromTheme.queenStar, r * 0.42f, c, alpha)
                drawCircle(Color.White.copy(alpha = 0.6f), r * 0.42f, c, alpha, Stroke(0.8f))
            }
            CarromPieceType.STRIKER -> {
                val glow = if (game.isPlacementValid) CarromTheme.strikerGlow else CarromTheme.baseCircleRed
                drawCircle(Brush.radialGradient(listOf(CarromTheme.strikerCore, CarromTheme.strikerRing, CarromTheme.strikerBody), hl, r), r, c, alpha)
                drawCircle(glow, r, c, alpha, Stroke(1.6f))
                if (game.phase == CarromPhase.Aiming && game.shotPower > 0) {
                    drawCircle(glow.copy(alpha = game.shotPower.coerceIn(0f, 1f)), r + 4f, c, style = Stroke(2f))
                }
            }
        }
    }
}

private fun DrawScope.drawAim(game: CarromGame, aim: CarromAimResult) {
    val ft = CarromTheme.FRAME
    fun o(p: Vec) = v(ft + p.x, ft + p.y)
    drawLine(CarromTheme.aimLaser, o(aim.rayStart), o(aim.rayEnd), 2f, StrokeCap.Round,
        PathEffect.dashPathEffect(floatArrayOf(6f, 4f)))
    if (aim.hasWallHit && aim.wallBounceEnd != null) {
        drawLine(CarromTheme.aimBounceLaser, o(aim.rayEnd), o(aim.wallBounceEnd), 1.5f, StrokeCap.Round,
            PathEffect.dashPathEffect(floatArrayOf(4f, 4f)))
    }
    aim.ghostStrikerPos?.let { g ->
        drawCircle(CarromTheme.aimGhostDisc, CarromTheme.STRIKER_RADIUS, o(g))
        drawCircle(CarromTheme.aimLaser, CarromTheme.STRIKER_RADIUS, o(g), style = Stroke(1.2f))
        val target = game.world.pieces.firstOrNull { it.id == aim.targetPieceId }
        if (target != null && aim.targetDeflectionEnd != null) {
            drawLine(CarromTheme.aimLaser, o(target.position), o(aim.targetDeflectionEnd), 1.6f, StrokeCap.Round,
                PathEffect.dashPathEffect(floatArrayOf(3f, 3f)))
        }
    }
}
