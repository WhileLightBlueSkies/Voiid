package com.voiid.app.main.games

import androidx.compose.animation.core.Spring
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.animation.core.spring
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.aspectRatio
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
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
import androidx.compose.runtime.mutableIntStateOf
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
import com.voiid.app.net.GamesEngine
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing

/**
 * Rock Paper Scissors against a FRIEND, refereed by the server (docs/GAMES.md §4).
 *
 * WHY THIS SCREEN EXISTS SEPARATELY FROM TicTacToeScreen: the online board used to render a
 * 3x3 grid for every match regardless of slug, so an RPS invite opened a tic-tac-toe board.
 * The server has refereed RPS all along — only the renderer was missing.
 *
 * THE SHAKE HAS ONE HONEST WINDOW, AND ONLY ONE. While a single player has thrown, the reveal
 * arrives whenever the opponent taps — which may be minutes later — so a wind-up there would be a
 * lie about timing, and there is none. But once BOTH `hasThrown` flags are true the resolved frame
 * is imminent AND KNOWN TO BE IMMINENT, so the client may run the three-beat wind-up and reveal at
 * the end of it. A safety release stops it after ~600 ms if the frame has not arrived, so a
 * wind-up can never outlive its own justification.
 *
 * THE OPPONENT'S HAND IS NOT DRAWN MID-ROUND, AND CANNOT BE. The server sends `hasThrown`
 * booleans while a round is open and never the throw itself, because RPS is simultaneous:
 * leaking the first throw would let whoever moves second win every time. So this shows a
 * covered hand plus "they've thrown" — that is the entire truth available, and faking a hand
 * here would be inventing state the client was deliberately not given.
 *
 * No shake animation either, for the same honest reason: the bot screen shakes because it
 * knows when both throws exist and can time the reveal. Here the reveal arrives whenever the
 * opponent taps, which may be minutes later, so a shake would be a lie about timing.
 *
 * Mirrors iOS `RpsMatchView.swift`.
 */
@Composable
fun RpsMatchScreen(
    matchId: String,
    onClose: () -> Unit,
    /**
     * Open a freshly-minted rematch. Null hides the Rematch button — a caller that cannot
     * navigate to a new match must not offer one.
     */
    onRematch: ((String) -> Unit)? = null,
) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    val state by engine.rps.collectAsState()
    val joinError by engine.joinError.collectAsState()
    val me = engine.myUserId

    DisposableEffect(Unit) {
        GameAudio.preload(context, "rps")
        onDispose { GameAudio.release("rps") }
    }

    /**
     * True while the shared wind-up is running — see the header for the one condition that makes
     * it honest. Drives the forearm swing on BOTH hands.
     */
    var winding by remember { mutableStateOf(false) }

    // BOTH PLAYERS HAVE THROWN: the resolved frame is imminent and known to be, so the wind-up
    // may run. This is the ONLY condition under which it does.
    val bothCommitted = state?.let { st ->
        !st.finished && st.hasThrown.size >= 2 && st.hasThrown.all { it }
    } ?: false
    LaunchedEffect(bothCommitted) {
        if (!bothCommitted) return@LaunchedEffect
        winding = true
        repeat(HandRig.PUMP_COUNT * 2) { i ->
            kotlinx.coroutines.delay(HandRig.PUMP_BEAT_MS)
            if (i % 2 == 0) {
                GameAudio.play("hand_pump", pitch = PUMP_PITCHES[i / 2], gain = 0.5f)
            }
        }
        winding = false
    }
    // A SAFETY RELEASE. If the server's frame has not arrived by the time the wind-up would have
    // finished plus a margin, stop pretending and let the reveal happen on arrival — a wind-up
    // that outlives its own justification is the lie the header rules out.
    LaunchedEffect(bothCommitted) {
        if (!bothCommitted) return@LaunchedEffect
        kotlinx.coroutines.delay(600)
        winding = false
    }

    // A new resolved round appeared: the reveal just happened. History only grows, so a count
    // increase is unambiguous — a round is atomic (both throws resolve together), unlike Tic
    // Tac Toe where individual cells need diffing. Mirrors iOS RpsMatchView's identical hook.
    var lastHistoryCount by remember { mutableIntStateOf(0) }
    LaunchedEffect(state?.history?.size) {
        val s = state
        val newCount = s?.history?.size ?: 0
        if (newCount > lastHistoryCount && s != null) {
            GameAudio.play("hand_reveal", gain = 0.7f)
            val mySeat = s.players.indexOf(me).let { if (it < 0) 0 else it }
            val round = s.history.last()
            when (round.winner) {
                null -> GameAudio.play("round_tie", gain = 0.5f)
                mySeat -> GameAudio.play("round_win", gain = 0.65f)
                else -> {
                    GameAudio.play("round_lose", gain = 0.65f)
                    // THE SHARED SOUND (§3): your throw was COUNTERED. Layered under the round
                    // stinger, never instead of it.
                    GameAudio.play(GameAudio.CATCH, gain = 0.5f)
                }
            }
        }
        lastHistoryCount = newCount
    }
    // No dedicated RPS match-end sound in the catalogue (docs/GAMES_AUDIO.md §9) — the final
    // round's own round_win/round_lose/round_tie above already carries the outcome.

    LaunchedEffect(matchId) { engine.open(matchId) }

    // A Box, not the bare Column: the end screen is a SIBLING that sits OVER the
    // board (§9.2). Inside the Column it would be laid out in flow and push the
    // board up the screen instead of covering it.
    Box(Modifier.fillMaxSize()) {
        Column(
            Modifier
                .fillMaxSize()
                .background(VoiidColor.background)
                .statusBarsPadding()
                .padding(horizontal = VoiidSpacing.lg),
        ) {
            Row(
                Modifier.fillMaxWidth().padding(top = VoiidSpacing.md),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Icon(
                    Icons.AutoMirrored.Filled.ArrowBack,
                    contentDescription = "Back",
                    tint = VoiidColor.textPrimary,
                    modifier = Modifier.clickable { engine.leave(); onClose() },
                )
                Text(
                    "Rock Paper Scissors",
                    color = VoiidColor.textPrimary,
                    fontSize = 17.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.weight(1f),
                    textAlign = TextAlign.Center,
                )
                Box(Modifier.size(24.dp))
            }

            val s = state
            when {
                s != null -> {
                    // My seat decides which half of every by-seat array is mine. Derived once —
                    // a wrong seat would silently swap the whole scoreboard.
                    val mySeat = s.players.indexOf(me).coerceAtLeast(0)
                    val theirSeat = if (mySeat == 0) 1 else 0

                    val myWins = s.wins.getOrElse(mySeat) { 0 }
                    val theirWins = s.wins.getOrElse(theirSeat) { 0 }
                    val iThrew = s.hasThrown.getOrElse(mySeat) { false }
                    val theyThrew = s.hasThrown.getOrElse(theirSeat) { false }
                    val lastRound = s.history.lastOrNull()
                    val bothThrown = !s.finished && iThrew && theyThrew

                    Spacer(Modifier.weight(1f))

                    Row(
                        Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.lg),
                        horizontalArrangement = Arrangement.SpaceEvenly,
                    ) {
                        ScoreBlock("You", myWins)
                        Text(
                            "first to ${s.target}",
                            color = VoiidColor.textSecondary,
                            fontSize = 12.sp,
                            modifier = Modifier.align(Alignment.CenterVertically),
                        )
                        ScoreBlock("Them", theirWins)
                    }

                    // The two hands. Mid-round mine is known and theirs is not; once a round
                    // resolves, the last entry in history reveals both.
                    Row(
                        Modifier.fillMaxWidth(),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.md),
                    ) {
                        val roundOpen = lastRound == null || iThrew || theyThrew
                        MatchHand(
                            throwName = if (iThrew && roundOpen) null
                                        else lastRound?.throws?.getOrNull(mySeat),
                            covered = iThrew && roundOpen,
                            modifier = Modifier.weight(1f),
                            winding = winding,
                        )
                        MatchHand(
                            throwName = if (theyThrew && roundOpen) null
                                        else lastRound?.throws?.getOrNull(theirSeat),
                            covered = theyThrew && roundOpen,
                            modifier = Modifier.weight(1f),
                            mirrored = true,
                            winding = winding,
                        )
                    }

                    val status = when {
                        s.finished && s.winnerUserId == null -> "Tie"
                        s.finished && s.winnerUserId == me -> "You win the match"
                        s.finished -> "You lose the match"
                        iThrew && !theyThrew -> "Waiting for them…"
                        !iThrew && theyThrew -> "They've thrown — your turn"
                        iThrew -> "Revealing…"
                        lastRound != null -> when (lastRound.winner) {
                            null -> "Tied round — throw again"
                            mySeat -> "You won the round"
                            else -> "They won the round"
                        }
                        else -> "Throw to begin"
                    }
                    Text(
                        status,
                        color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
                        fontSize = 16.sp,
                        fontWeight = FontWeight.SemiBold,
                        modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.lg),
                        textAlign = TextAlign.Center,
                    )

                    // The end screen is an OVERLAY over the hands (§9.2).

                    Spacer(Modifier.weight(1f))

                    // Throw buttons. Disabled once I've thrown this round or the match is over —
                    // the server rejects both anyway, this only avoids a pointless frame.
                    Row(
                        Modifier.fillMaxWidth().padding(bottom = VoiidSpacing.xl),
                        horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                    ) {
                        THROWS.forEach { (name, glyph) ->
                            ThrowButton(
                                glyph = glyph,
                                enabled = !s.finished && !iThrew,
                                modifier = Modifier.weight(1f),
                            ) { engine.throwRps(context, name) }
                        }
                    }
                }

                joinError != null -> Text(
                    joinError ?: "",
                    color = VoiidColor.error,
                    fontSize = 15.sp,
                    modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.xl),
                    textAlign = TextAlign.Center,
                )

                else -> Column(
                    Modifier.fillMaxWidth().padding(top = VoiidSpacing.xl),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    CircularProgressIndicator(color = VoiidColor.primary)
                    Text(
                        "Setting up the match…",
                        color = VoiidColor.textSecondary,
                        fontSize = 14.sp,
                        modifier = Modifier.padding(top = VoiidSpacing.sm),
                    )
                }
            }
        }

        // THE HANDS STAY VISIBLE BEHIND THE VERDICT (§9.2).
        val done = state
        if (done != null && done.finished) {
            MatchEndOverlay(
                result = rpsResult(done, me),
                onExit = { engine.leave(); onClose() },
                matchId = matchId,
                onRematch = onRematch?.let { cb -> { newId: String -> engine.leave(); cb(newId) } },
            )
        }
    }

}

/** Wire name to glyph. The name is what the server's engine validates against. */
private val THROWS = listOf(
    "rock" to "✊",
    "paper" to "✋",
    "scissors" to "✌️",
)

private fun glyphFor(throwName: String?): String = when (throwName) {
    "rock" -> "✊"
    "paper" -> "✋"
    "scissors" -> "✌️"
    else -> "✊"
}

@Composable
private fun ScoreBlock(label: String, wins: Int) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Text(
            "$wins",
            color = VoiidColor.textPrimary,
            fontSize = 34.sp,
            fontWeight = FontWeight.Bold,
        )
        Text(label, color = VoiidColor.textSecondary, fontSize = 13.sp)
    }
}

/**
 * One hand, drawn from the rig (§3). [covered] means "thrown, but not revealed" — the honest
 * rendering of a throw the client is not allowed to know yet, drawn as a closed fist rather
 * than a real shape.
 *
 * [winding] runs the shared wind-up, and ONLY once both players have thrown — see this file's
 * header for why that window and no other.
 */
@Composable
private fun MatchHand(
    throwName: String?,
    covered: Boolean,
    modifier: Modifier = Modifier,
    mirrored: Boolean = false,
    winding: Boolean = false,
) {
    val forearm by animateFloatAsState(
        targetValue = if (winding) HandRig.PUMP_UP else 0f,
        animationSpec = spring(dampingRatio = 0.25f, stiffness = Spring.StiffnessLow),
        label = "forearm",
    )
    val settle by animateFloatAsState(
        targetValue = if (!covered && !winding && throwName != null) 1f else 0f,
        animationSpec = spring(dampingRatio = Spring.DampingRatioMediumBouncy),
        label = "reveal",
    )

    val pose = if (covered || winding || throwName == null) {
        HandRig.NEUTRAL
    } else {
        HandRig.lerp(HandRig.NEUTRAL, HandRig.pose(indexFor(throwName)), settle.toDouble())
    }

    Box(
        modifier
            .aspectRatio(1f)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(VoiidColor.surfaceCard),
        contentAlignment = Alignment.Center,
    ) {
        HandView(
            pose = pose,
            modifier = Modifier.padding(VoiidSpacing.sm),
            forearm = forearm,
            wrist = forearm * HandRig.WRIST_FOLLOW,
            mirrored = mirrored,
        )
    }
}

/** Wire name -> rig pose index, matching [RpsBot]'s ordering. */
private fun indexFor(name: String?): Int? = when (name) {
    "rock" -> RpsBot.ROCK
    "paper" -> RpsBot.PAPER
    "scissors" -> RpsBot.SCISSORS
    else -> null
}

@Composable
private fun ThrowButton(
    glyph: String,
    enabled: Boolean,
    modifier: Modifier = Modifier,
    onClick: () -> Unit,
) {
    Box(
        modifier
            .clip(CircleShape)
            .background(
                if (enabled) VoiidColor.fieldFill
                else VoiidColor.fieldFill.copy(alpha = 0.4f)
            )
            .clickable(enabled = enabled) { onClick() }
            .padding(vertical = VoiidSpacing.md),
        contentAlignment = Alignment.Center,
    ) {
        Text(glyph, fontSize = 34.sp)
    }
}

/**
 * The three fist-pump beats rise slightly in pitch, so the wind-up climbs toward the reveal
 * instead of repeating. Identical to iOS `RpsBotView.pumpPitches`.
 */
private val PUMP_PITCHES = floatArrayOf(0.94f, 1.0f, 1.08f)
