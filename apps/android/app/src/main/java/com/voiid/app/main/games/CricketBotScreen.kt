package com.voiid.app.main.games

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.animation.core.tween
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.DisposableEffect
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
import androidx.compose.ui.draw.scale
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay

/**
 * Hand Cricket against the local bot (docs/GAMES_HAND_CRICKET.md).
 *
 * THE RULES LIVE HERE, deliberately, unlike the online screen. A bot match never reaches the
 * server, so there is no referee to defer to — this screen IS the referee for practice play.
 * It mirrors backend/games/src/engine/cricket exactly: same 0-6 picks, same 2 wickets, same
 * "matched number is out including 0 vs 0", same target = score + 1. If the two ever disagree
 * the bot game is teaching a rule the real game doesn't have, which is worse than no bot at all.
 *
 * OVERS ARE CHOSEN FIRST AND THEN LOCKED, matching how difficulty locks: a match length you can
 * change mid-innings is not a match length.
 *
 * Practice results are recorded locally per difficulty ([BotScoreStore]) and never reach the
 * friends leaderboard, which counts only refereed matches.
 *
 * Mirrors iOS `CricketBotView.swift`.
 */
private const val BALLS_PER_OVER = 6
private const val WICKETS = 2

@Composable
fun CricketBotScreen(level: BotDifficulty, skill: Float, onClose: () -> Unit) {
    val context = LocalContext.current
    val store = remember { BotScoreStore(context) }

    DisposableEffect(Unit) {
        GameAudio.preload(context, "cricket")
        onDispose { GameAudio.release("cricket") }
    }

    // Null until the player picks a length — the match cannot start without one.
    var overs by remember { mutableStateOf<Int?>(null) }

    var innings by remember { mutableIntStateOf(1) }
    var humanBatting by remember { mutableStateOf(true) }
    var humanScore by remember { mutableIntStateOf(0) }
    var botScore by remember { mutableIntStateOf(0) }
    var humanWickets by remember { mutableIntStateOf(0) }
    var botWickets by remember { mutableIntStateOf(0) }
    var ballsBowled by remember { mutableIntStateOf(0) }
    var target by remember { mutableStateOf<Int?>(null) }

    var lastEvent by remember { mutableStateOf<BallEvent?>(null) }
    var ballToken by remember { mutableIntStateOf(0) }
    var humanPick by remember { mutableStateOf<Int?>(null) }
    var botPick by remember { mutableStateOf<Int?>(null) }
    var resolving by remember { mutableStateOf(false) }
    var finished by remember { mutableStateOf(false) }
    var humanWon by remember { mutableStateOf<Boolean?>(null) }
    var paused by remember { mutableStateOf(false) }
    var recorded by remember { mutableStateOf(false) }

    // Kept per ROLE: how someone bats says little about how they bowl, so one mixed history
    // would blur the bot's model into noise.
    val humanBatHistory = remember { mutableStateListOf<Int>() }
    val humanBowlHistory = remember { mutableStateListOf<Int>() }

    fun finish(won: Boolean?) {
        finished = true
        humanWon = won
        if (won == true) GameAudio.play("match_end", gain = 0.7f)
        if (!recorded) {
            store.add(level, if (won == true) 1 else if (won == false) -1 else 0)
            recorded = true
        }
    }

    fun restart() {
        innings = 1; humanBatting = true
        humanScore = 0; botScore = 0
        humanWickets = 0; botWickets = 0
        ballsBowled = 0; target = null
        lastEvent = null; humanPick = null; botPick = null
        resolving = false; finished = false; humanWon = null
        paused = false; recorded = false
        humanBatHistory.clear(); humanBowlHistory.clear()
        overs = null
    }

    /** Score one ball, then advance the innings if this ball ended it. */
    fun resolve(mine: Int, theirs: Int) {
        val o = overs ?: return
        val batterPick = if (humanBatting) mine else theirs
        val wicket = CricketBot.isWicket(mine, theirs)
        val runs = if (wicket) 0 else batterPick

        if (wicket) {
            if (humanBatting) humanWickets++ else botWickets++
        } else {
            if (humanBatting) humanScore += runs else botScore += runs
        }
        ballsBowled++
        lastEvent = BallEvent.of(runs = runs, wicket = wicket, matchedPick = mine)
        ballToken++
        when {
            wicket -> GameAudio.play("wicket", gain = 0.75f)
            runs == 6 -> GameAudio.play("six", gain = 0.8f)
            runs == 4 -> GameAudio.play("four", gain = 0.7f)
            runs > 0 -> GameAudio.play("runs_$runs", gain = 0.55f)
        }

        // Record the human's pick AFTER resolving, so the model never sees the pick it was
        // predicting on this very ball.
        if (humanBatting) humanBatHistory.add(mine) else humanBowlHistory.add(mine)

        val battingScore = if (humanBatting) humanScore else botScore
        val battingWickets = if (humanBatting) humanWickets else botWickets

        // A chase that reaches the target ends immediately — no playing out the overs.
        val t = target
        if (innings == 2 && t != null && battingScore >= t) {
            finish(humanBatting)
            return
        }

        val inningsOver = battingWickets >= WICKETS || ballsBowled >= o * BALLS_PER_OVER
        if (!inningsOver) return

        if (innings == 1) {
            innings = 2
            humanBatting = !humanBatting
            ballsBowled = 0
            target = battingScore + 1
            GameAudio.play("innings", gain = 0.55f)
        } else {
            // Second innings ended short. Equal totals = tie.
            when {
                humanScore == botScore -> finish(null)
                else -> finish(humanScore > botScore)
            }
        }
    }

    // Counts TAPS, not resolutions. Keying the effect below on ballToken would re-enter it,
    // because resolve() bumps ballToken to replay the pitch animation — the effect would then
    // score a second phantom ball off one tap.
    var pickToken by remember { mutableIntStateOf(0) }

    // Resolve after a beat so the reveal has real elapsed time rather than landing in the same
    // frame as the tap — the same reason the RPS bot screen delays its shake.
    LaunchedEffect(pickToken) {
        if (!resolving) return@LaunchedEffect
        val mine = humanPick ?: return@LaunchedEffect
        val history = if (humanBatting) humanBatHistory else humanBowlHistory
        val theirs = CricketBot.choosePick(
            humanHistory = history.toList(),
            skill = skill,
            botIsBatting = !humanBatting,
        )
        botPick = theirs
        delay(260)
        resolve(mine, theirs)
        resolving = false
    }

    fun pick(n: Int) {
        if (resolving || finished || paused || overs == null) return
        GameAudio.play("pick", gain = 0.45f)
        humanPick = n
        botPick = null
        resolving = true
        pickToken++
    }

    Box(
        Modifier
            .fillMaxSize()
            .background(VoiidColor.background)
            .statusBarsPadding(),
    ) {
        Column(
            Modifier
                .fillMaxSize()
                .padding(horizontal = VoiidSpacing.lg),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(vertical = VoiidSpacing.sm),
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
                        .clickable(enabled = !finished && overs != null) { paused = true }
                        .padding(VoiidSpacing.sm),
                )
            }

            val o = overs
            if (o == null) {
                OversPicker { overs = it }
            } else {
                Spacer(Modifier.weight(1f))

                // Scoreboard. The batting side's score is the headline; the chase target sits
                // beside it, because a chase without a number is not a chase.
                val battingScore = if (humanBatting) humanScore else botScore
                val battingWickets = if (humanBatting) humanWickets else botWickets
                Text(
                    if (humanBatting) "You're batting" else "You're bowling",
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Row(
                    Modifier.fillMaxWidth().padding(top = 2.dp),
                    horizontalArrangement = Arrangement.Center,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    val bump by animateFloatAsState(
                        targetValue = 1f,
                        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
                        label = "score$battingScore",
                    )
                    Text(
                        "$battingScore-$battingWickets",
                        color = VoiidColor.textPrimary,
                        fontSize = 40.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.scale(bump),
                    )
                }
                Text(
                    buildString {
                        append(oversText(ballsBowled))
                        append(" / $o.0 ov")
                        target?.let { append("  ·  needs $it") }
                    },
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )

                CricketPitch(
                    event = lastEvent,
                    ballToken = ballToken,
                    modifier = Modifier.padding(vertical = VoiidSpacing.md),
                )

                // Both picks, revealed together once the ball resolves.
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    PickFace("You", humanPick, hidden = resolving)
                    PickFace("Bot", botPick, hidden = resolving)
                }

                Spacer(Modifier.weight(1f))

                if (finished) {
                    Text(
                        when (humanWon) {
                            true -> "You win!  $humanScore–$botScore"
                            false -> "You lose.  $humanScore–$botScore"
                            else -> "Tied.  $humanScore–$botScore"
                        },
                        color = VoiidColor.primary,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.md),
                        textAlign = TextAlign.Center,
                    )
                    Row(
                        Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.xl),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    ) {
                        CricketPill("Play again", filled = true, modifier = Modifier.weight(1f)) {
                            restart()
                        }
                        CricketPill("Exit", filled = false, modifier = Modifier.weight(1f)) {
                            onClose()
                        }
                    }
                } else {
                    Text(
                        if (humanBatting) "Pick your runs" else "Pick to bowl",
                        color = VoiidColor.textSecondary,
                        fontSize = 13.sp,
                        modifier = Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.sm),
                        textAlign = TextAlign.Center,
                    )
                    // 0-6 in two rows: seven buttons in one row are too narrow to hit.
                    Column(
                        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                        modifier = Modifier.padding(bottom = VoiidSpacing.xl),
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            (0..3).forEach { n ->
                                PickButton(n, enabled = !resolving, modifier = Modifier.weight(1f)) {
                                    pick(n)
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            (4..6).forEach { n ->
                                PickButton(n, enabled = !resolving, modifier = Modifier.weight(1f)) {
                                    pick(n)
                                }
                            }
                            // Keeps the second row's buttons the same width as the first.
                            Spacer(Modifier.weight(1f))
                        }
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
                    Text(
                        "Paused",
                        color = VoiidColor.textPrimary,
                        fontSize = 26.sp,
                        fontWeight = FontWeight.Bold,
                        modifier = Modifier.padding(bottom = VoiidSpacing.md),
                    )
                    CricketMenuButton("Resume", Icons.Filled.PlayArrow, filled = true) {
                        paused = false
                    }
                    CricketMenuButton("Restart", Icons.Filled.Refresh, filled = false) { restart() }
                    CricketMenuButton("Give up", Icons.Outlined.Flag, filled = false, danger = true) {
                        // Walking out mid-match is a loss, recorded — otherwise the local
                        // record would only ever contain wins and finished games.
                        if (!recorded) { store.add(level, -1); recorded = true }
                        onClose()
                    }
                }
            }
        }
    }
}

/** "2.3" — two overs and three balls. Cricket's own notation, not a raw ball count. */
private fun oversText(balls: Int): String = "${balls / BALLS_PER_OVER}.${balls % BALLS_PER_OVER}"

/**
 * Match length, chosen before anything starts and then locked.
 *
 * Its own step rather than a row on the setup sheet: the sheet already asks who you're playing,
 * and stacking a second unrelated question onto it made that sheet the place where every
 * decision goes.
 */
@Composable
private fun OversPicker(onPick: (Int) -> Unit) {
    Column(
        Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Text(
            "How many overs?",
            color = VoiidColor.textPrimary,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(
            "6 balls each. 2 wickets. Locked once you start.",
            color = VoiidColor.textSecondary,
            fontSize = 13.sp,
            modifier = Modifier.padding(top = 4.dp, bottom = VoiidSpacing.lg),
        )
        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
            (1..5).forEach { n ->
                Box(
                    Modifier
                        .size(54.dp)
                        .clip(CircleShape)
                        .background(VoiidColor.fieldFill)
                        .clickable { onPick(n) },
                    contentAlignment = Alignment.Center,
                ) {
                    Text(
                        "$n",
                        color = VoiidColor.textPrimary,
                        fontSize = 20.sp,
                        fontWeight = FontWeight.Bold,
                    )
                }
            }
        }
    }
}

/** One side's pick for the current ball. Hidden while the ball is resolving. */
@Composable
private fun PickFace(label: String, pick: Int?, hidden: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.surfaceCard),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                if (hidden || pick == null) "—" else "$pick",
                color = VoiidColor.textPrimary,
                fontSize = 28.sp,
                fontWeight = FontWeight.Bold,
            )
        }
        Text(
            label,
            color = VoiidColor.textSecondary,
            fontSize = 12.sp,
            modifier = Modifier.padding(top = 4.dp),
        )
    }
}

@Composable
private fun PickButton(
    n: Int,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .clip(RoundedCornerShape(VoiidRadius.md))
            .background(
                if (enabled) VoiidColor.fieldFill else VoiidColor.fieldFill.copy(alpha = 0.4f)
            )
            .clickable(enabled = enabled) { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            "$n",
            color = VoiidColor.textPrimary,
            fontSize = 22.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun CricketPill(
    label: String,
    filled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            label,
            color = if (filled) VoiidColor.textOnPrimary else VoiidColor.textPrimary,
            fontSize = 15.sp,
            fontWeight = FontWeight.Bold,
        )
    }
}

@Composable
private fun CricketMenuButton(
    label: String,
    icon: androidx.compose.ui.graphics.vector.ImageVector,
    filled: Boolean,
    danger: Boolean = false,
    onClick: () -> Unit,
) {
    Row(
        Modifier
            .fillMaxWidth()
            .clip(CircleShape)
            .background(if (filled) VoiidColor.primary else VoiidColor.fieldFill)
            .clickable { onClick() }
            .padding(vertical = VoiidSpacing.md),
        horizontalArrangement = Arrangement.Center,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Icon(
            icon,
            contentDescription = null,
            tint = when {
                danger -> VoiidColor.error
                filled -> VoiidColor.textOnPrimary
                else -> VoiidColor.textPrimary
            },
            modifier = Modifier.size(18.dp),
        )
        Text(
            label,
            color = when {
                danger -> VoiidColor.error
                filled -> VoiidColor.textOnPrimary
                else -> VoiidColor.textPrimary
            },
            fontSize = 16.sp,
            fontWeight = FontWeight.SemiBold,
            modifier = Modifier.padding(start = VoiidSpacing.sm),
        )
    }
}
