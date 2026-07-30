package com.voiid.app.main.games

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.scaleIn
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
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
import androidx.compose.foundation.layout.statusBarsPadding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Pause
import androidx.compose.material.icons.filled.PlayArrow
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.outlined.Flag
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Rock Paper Scissors against the local bot. Best of 3, matching the server engine's
 * default so the online and offline games are the same game.
 *
 * THE SHAKE IS NOT DECORATION: both hands shake together for a beat before revealing, which
 * is what makes a simultaneous game feel simultaneous. Without it the bot's throw would
 * simply appear next to yours and it would look like it answered you — the same perception
 * problem the online engine solves by hiding throws until both are in.
 *
 * Mirrors iOS `RpsBotView.swift`.
 */
private const val TARGET = 3

@Composable
fun RpsBotScreen(level: BotDifficulty, skill: Float, onClose: () -> Unit) {
    var myWins by remember { mutableIntStateOf(0) }
    var botWins by remember { mutableIntStateOf(0) }
    var myThrow by remember { mutableStateOf<Int?>(null) }
    var botThrow by remember { mutableStateOf<Int?>(null) }
    var revealing by remember { mutableStateOf(false) }
    var paused by remember { mutableStateOf(false) }
    var roundToken by remember { mutableIntStateOf(0) }
    val history = remember { mutableStateListOf<Int>() }
    val scores = remember { mutableStateOf<BotScoreStore?>(null) }

    val context = androidx.compose.ui.platform.LocalContext.current
    val store = remember { BotScoreStore(context) }
    var recorded by remember { mutableStateOf(false) }

    val matchOver = myWins >= TARGET || botWins >= TARGET

    // Resolve the round after the shake. Kept in an effect (not the click) so the shake has
    // real elapsed time rather than resolving in the same frame as the tap.
    LaunchedEffect(roundToken) {
        if (roundToken == 0 || !revealing) return@LaunchedEffect
        delay(750)
        val mine = myThrow ?: return@LaunchedEffect
        val theirs = RpsBot.chooseThrow(history.toList(), skill)
        botThrow = theirs
        when (RpsBot.compare(mine, theirs)) {
            1 -> myWins++
            -1 -> botWins++
        }
        // Record AFTER resolving so the model never sees the throw it is predicting.
        history.add(mine)
        revealing = false
    }

    // Persist the match result once, when it ends.
    LaunchedEffect(myWins, botWins) {
        if (!recorded && (myWins >= TARGET || botWins >= TARGET)) {
            store.add(level, if (myWins > botWins) 1 else -1)
            recorded = true
        }
    }

    fun throwHand(choice: Int) {
        if (revealing || matchOver || paused) return
        myThrow = choice
        botThrow = null
        revealing = true
        roundToken++
    }

    fun restart() {
        myWins = 0; botWins = 0
        myThrow = null; botThrow = null
        revealing = false; paused = false; recorded = false
        history.clear()
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding(),
    ) {
        Column(
            Modifier.fillMaxSize().padding(horizontal = VoiidSpacing.lg),
            verticalArrangement = Arrangement.Center,
        ) {
            Row(
                Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.lg),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    level.label,
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier
                        .clip(CircleShape)
                        .background(VoiidColor.fieldFill)
                        .padding(horizontal = VoiidSpacing.md, vertical = 6.dp),
                )
                Spacer(Modifier.weight(1f))
                Icon(
                    Icons.Filled.Pause,
                    contentDescription = "Pause",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier
                        .clip(CircleShape)
                        .clickable(enabled = !matchOver) { paused = true }
                        .padding(VoiidSpacing.sm),
                )
            }

            // Score. Best of 3, so "first to 3" is the whole context a player needs.
            Row(
                Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.lg),
                horizontalArrangement = Arrangement.SpaceEvenly,
            ) {
                ScorePill("You", myWins)
                Text("first to $TARGET", color = VoiidColor.textSecondary, fontSize = 12.sp,
                    modifier = Modifier.align(Alignment.CenterVertically))
                ScorePill("Bot", botWins)
            }

            // The two hands.
            Row(
                Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
            ) {
                Hand(throwIdx = myThrow, shaking = revealing, modifier = Modifier.weight(1f))
                Hand(throwIdx = botThrow, shaking = revealing, mirrored = true,
                    modifier = Modifier.weight(1f))
            }

            val roundText = when {
                matchOver && myWins > botWins -> "You win the match"
                matchOver -> "Bot wins the match"
                revealing -> "Shoot!"
                myThrow != null && botThrow != null -> when (RpsBot.compare(myThrow!!, botThrow!!)) {
                    1 -> "You win the round"
                    -1 -> "Bot wins the round"
                    else -> "Tie"
                }
                else -> "Pick your throw"
            }
            val textScale by animateFloatAsState(
                targetValue = if (matchOver) 1.15f else 1f,
                animationSpec = spring(dampingRatio = 0.4f, stiffness = Spring.StiffnessLow),
                label = "roundText",
            )
            Text(
                roundText,
                color = if (matchOver) VoiidColor.primary else VoiidColor.textSecondary,
                fontSize = 18.sp,
                fontWeight = FontWeight.Bold,
                textAlign = TextAlign.Center,
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = VoiidSpacing.lg)
                    .scale(textScale),
            )

            if (!matchOver) {
                Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                    for (i in 0..2) {
                        ThrowButton(
                            index = i,
                            enabled = !revealing && !paused,
                            selected = myThrow == i && !revealing,
                            modifier = Modifier.weight(1f),
                        ) { throwHand(i) }
                    }
                }
            } else {
                AnimatedVisibility(
                    visible = true,
                    enter = fadeIn() + scaleIn(initialScale = 0.85f,
                        animationSpec = spring(dampingRatio = 0.5f)),
                ) {
                    Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                        RpsPill("Play again", filled = true, modifier = Modifier.weight(1f)) { restart() }
                        RpsPill("Exit", filled = false, modifier = Modifier.weight(1f)) { onClose() }
                    }
                }
            }
        }

        AnimatedVisibility(visible = paused, enter = fadeIn(tween(150)), exit = fadeOut(tween(150))) {
            Box(
                Modifier
                    .fillMaxSize()
                    .background(VoiidColor.background.copy(alpha = 0.94f))
                    .clickable(
                        interactionSource = remember { MutableInteractionSource() },
                        indication = null,
                    ) {},
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    Modifier.padding(horizontal = VoiidSpacing.xl),
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                ) {
                    Text("Paused", color = VoiidColor.textPrimary, fontSize = 26.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(bottom = VoiidSpacing.md))
                    RpsMenuButton("Resume", Icons.Filled.PlayArrow, filled = true) { paused = false }
                    RpsMenuButton("Restart", Icons.Filled.Refresh, filled = false) { restart() }
                    RpsMenuButton("Give up", Icons.Outlined.Flag, filled = false, danger = true) {
                        if (!recorded) { store.add(level, -1); recorded = true }
                        onClose()
                    }
                }
            }
        }
    }
}

@Composable
private fun ScorePill(label: String, value: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        // The number pops on change, so a won round registers without reading the text.
        val scale by animateFloatAsState(
            targetValue = 1f,
            animationSpec = spring(dampingRatio = 0.35f),
            label = "score$value",
        )
        Text("$value", color = VoiidColor.textPrimary, fontSize = 26.sp,
            fontWeight = FontWeight.Bold, modifier = Modifier.scale(scale))
        Text(label, color = VoiidColor.textSecondary, fontSize = 12.sp)
    }
}

/** One hand: shakes while the round resolves, then lands on its throw. */
@Composable
private fun Hand(
    throwIdx: Int?,
    shaking: Boolean,
    mirrored: Boolean = false,
    modifier: Modifier = Modifier,
) {
    // Tilt oscillates while shaking. animateFloatAsState toggling between two targets keeps
    // it a spring rather than a linear wobble, which reads as a hand, not a metronome.
    val tilt by animateFloatAsState(
        targetValue = if (shaking) 18f else 0f,
        animationSpec = spring(dampingRatio = 0.25f, stiffness = Spring.StiffnessLow),
        label = "tilt",
    )
    val pop by animateFloatAsState(
        targetValue = if (throwIdx != null && !shaking) 1f else 0.82f,
        animationSpec = spring(dampingRatio = 0.42f, stiffness = Spring.StiffnessMediumLow),
        label = "pop",
    )

    Box(
        modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            when {
                shaking || throwIdx == null -> "✊"
                throwIdx == RpsBot.ROCK -> "✊"
                throwIdx == RpsBot.PAPER -> "✋"
                else -> "✌️"
            },
            fontSize = 56.sp,
            modifier = Modifier
                .rotate(if (mirrored) -tilt else tilt)
                .scale(pop),
        )
    }
}

@Composable
private fun ThrowButton(
    index: Int,
    enabled: Boolean,
    selected: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    val scale by animateFloatAsState(
        targetValue = if (selected) 1.08f else 1f,
        animationSpec = spring(dampingRatio = 0.45f),
        label = "throwBtn",
    )
    Box(
        modifier
            .scale(scale)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(if (selected) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable(enabled = enabled) { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            when (index) {
                RpsBot.ROCK -> "✊"
                RpsBot.PAPER -> "✋"
                else -> "✌️"
            },
            fontSize = 30.sp,
        )
    }
}

@Composable
private fun RpsPill(text: String, filled: Boolean, modifier: Modifier = Modifier, onClick: () -> Unit) {
    Box(
        modifier
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(text, color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
            fontSize = 14.sp, fontWeight = FontWeight.SemiBold)
    }
}

@Composable
private fun RpsMenuButton(
    text: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    val fg = when {
        filled -> VoiidColor.textOnPrimary
        danger -> VoiidColor.error
        else -> VoiidColor.textPrimary
    }
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md, horizontal = VoiidSpacing.lg),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.Center,
    ) {
        Icon(icon, contentDescription = null, tint = fg, modifier = Modifier.size(18.dp))
        Spacer(Modifier.size(VoiidSpacing.sm))
        Text(text, color = fg, fontSize = 15.sp, fontWeight = FontWeight.SemiBold)
    }
}
