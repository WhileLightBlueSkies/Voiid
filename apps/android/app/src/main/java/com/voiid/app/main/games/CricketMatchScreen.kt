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
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.statusBarsPadding
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
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.net.GamesEngine
import com.voiid.app.store.UserDirectory
import com.voiid.app.ui.theme.VoiidColor
import com.voiid.app.ui.theme.VoiidRadius
import com.voiid.app.ui.theme.VoiidSpacing
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * Hand Cricket against a FRIEND, refereed by the server (docs/GAMES_HAND_CRICKET.md).
 *
 * A DUMB VIEW, unlike [CricketBotScreen]. It computes no runs, takes no wickets and decides no
 * innings — every one of those is answered by backend/games/src/engine/cricket, and duplicating
 * any of them here is how the two sides drift apart. The bot screen referees because a practice
 * match never reaches a server; this one never does.
 *
 * THE OPPONENT'S PICK IS NOT DRAWN WHILE THE BALL IS OPEN, AND CANNOT BE. The server sends
 * `hasPicked` booleans and never the pick, because hand cricket is simultaneous: leaking the
 * batter's number would let the bowler match it at will (a guaranteed wicket) and leaking the
 * bowler's would let the batter dodge forever. So a pending pick renders as a covered face —
 * the entire truth available.
 *
 * Mirrors iOS `CricketMatchView.swift`.
 */
@Composable
fun CricketMatchScreen(matchId: String, onClose: () -> Unit) {
    val context = LocalContext.current
    val engine = GamesEngine.get(context)
    val state by engine.cricket.collectAsState()
    val joinError by engine.joinError.collectAsState()
    val me = engine.myUserId

    DisposableEffect(Unit) {
        GameAudio.preload(context, "cricket")
        // The stadium comes up with the screen and stays up for the whole match. It is
        // ambience, not an event — nothing else in the game starts or stops it.
        CricketSound.startBed(context)
        onDispose {
            CricketSound.stopBed()
            GameAudio.release("cricket")
        }
    }

    LaunchedEffect(matchId) { engine.open(matchId) }

    // Replays the pitch animation when a NEW ball resolves. Derived from history length rather
    // than from the ball itself, so two identical balls in a row still animate twice.
    var ballToken by remember { mutableIntStateOf(0) }
    var lastCount by remember { mutableIntStateOf(0) }
    val s = state
    val mySeat = s?.players?.indexOf(me)?.coerceAtLeast(0) ?: 0
    LaunchedEffect(s?.history?.size ?: 0) {
        val n = s?.history?.size ?: 0
        if (n > lastCount && s != null) {
            ballToken++
            val ball = s.history.last()
            // `mine` decides which way the crowd reacts: the same wicket is a roar for the
            // bowling side and a groan for the batting one.
            CricketSound.ball(ball.runs, ball.wicket, mine = ball.battingSeat == mySeat)
            // The chase tightened (or did not) — push the bed's gain either way.
            CricketSound.updateIntensity(s)
        }
        lastCount = n
    }

    // Announcements waiting to be delivered on the pitch. Same queue-and-chain model as the bot
    // screen, so the two modes announce identically.
    val announcements = remember { mutableStateListOf<CricketAnnouncement>() }
    var announcementSeq by remember { mutableIntStateOf(0) }
    // The role last announced, so a change is noticed ONCE rather than on every server frame.
    var lastAnnouncedBatting by remember { mutableStateOf<Boolean?>(null) }
    val scope = rememberCoroutineScope()

    fun nextAnnouncementId(): Int {
        announcementSeq += 1
        return announcementSeq
    }

    fun scheduleDismiss(a: CricketAnnouncement) {
        scope.launch {
            delay(a.durationMs)
            if (announcements.firstOrNull()?.id != a.id) return@launch
            announcements.removeAt(0)
            announcements.firstOrNull()?.let { scheduleDismiss(it) }
        }
    }

    // Only the first starts the drain; the rest are pulled by the one ahead. Concurrent timers
    // would clear the whole queue at once and the second message would never show.
    fun announce(a: CricketAnnouncement) {
        val wasIdle = announcements.isEmpty()
        announcements.add(a)
        if (wasIdle) scheduleDismiss(a)
    }

    var lastInnings by remember { mutableIntStateOf(1) }
    LaunchedEffect(s?.innings) {
        val innings = s?.innings ?: 1
        if (innings > lastInnings && s != null) {
            CricketSound.inningsBreak()
            // `target` is the first innings' score plus one, so it is the honest source for both
            // numbers — reading the scoreboard here would race the frame that changed it.
            val firstScore = (s.target ?: 1) - 1
            announce(
                CricketAnnouncements.inningsBreak(
                    id = nextAnnouncementId(),
                    firstInningsScore = firstScore,
                    target = s.target ?: 0,
                    iChase = s.battingSeat == mySeat,
                    opponent = opponentName(s, me),
                )
            )
        }
        lastInnings = innings
    }

    // ROLE CHANGES, wherever they come from. Online, this fires for BOTH the toss resolving and
    // the innings switch — the server just reports a new battingSeat and does not say why.
    // Keying on the value rather than the cause means one hook covers both and neither can be
    // missed. `phase == "play"` gates it: during the toss battingSeat is still provisional, and
    // announcing a role before anyone has elected would be a guess.
    LaunchedEffect(s?.phase, s?.battingSeat) {
        val st = s ?: return@LaunchedEffect
        if (st.phase != "play") return@LaunchedEffect
        val batting = st.battingSeat == mySeat
        if (batting == lastAnnouncedBatting) return@LaunchedEffect
        lastAnnouncedBatting = batting
        announce(CricketAnnouncements.role(nextAnnouncementId(), batting = batting))
    }

    var lastFinished by remember { mutableStateOf(false) }
    LaunchedEffect(s?.finished) {
        val finished = s?.finished == true
        if (finished && !lastFinished) {
            CricketSound.stopBed()
            CricketSound.matchEnd(won = s?.winnerUserId == me)
        }
        lastFinished = finished
    }

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
                "Hand Cricket",
                color = VoiidColor.textPrimary,
                fontSize = 17.sp,
                fontWeight = FontWeight.SemiBold,
                modifier = Modifier.weight(1f),
                textAlign = TextAlign.Center,
            )
            Box(Modifier.size(24.dp))
        }

        when {
            s != null && s.phase != "play" -> {
                // THE TOSS OWNS THE SCREEN UNTIL IT RESOLVES. Not a sheet over the scoreboard:
                // there is no score yet, and showing 0-0 behind a coin invites a tap on a pick
                // pad the server would only reject.
                val mySeat = s.players.indexOf(me).coerceAtLeast(0)
                CricketToss(
                    phase = s.phase,
                    iCall = s.toss.callerSeat == mySeat,
                    iElect = s.toss.wonSeat == mySeat,
                    coin = s.toss.coin,
                    called = s.toss.called,
                    opponentName = opponentName(s, me),
                    onCall = { engine.callToss(context, it) },
                    onElect = { engine.electToss(context, it) },
                )
            }

            s != null -> {
                // My seat decides which half of every by-seat array is mine. A wrong seat
                // would silently swap the whole scoreboard.
                val mySeat = s.players.indexOf(me).coerceAtLeast(0)
                val theirSeat = if (mySeat == 0) 1 else 0
                val iAmBatting = s.battingSeat == mySeat
                val iPicked = s.hasPicked.getOrElse(mySeat) { false }
                val theyPicked = s.hasPicked.getOrElse(theirSeat) { false }
                val last = s.history.lastOrNull()
                val ballOpen = iPicked || theyPicked

                val battingScore = s.scores.getOrElse(s.battingSeat) { 0 }
                val battingWickets = s.wickets.getOrElse(s.battingSeat) { 0 }

                val event = last?.let {
                    BallEvent.of(
                        runs = it.runs,
                        wicket = it.wicket,
                        // Both picks are equal on a wicket, so either index gives the matched
                        // number the animation choice depends on.
                        matchedPick = it.picks.firstOrNull() ?: 0,
                    )
                }

                Spacer(Modifier.weight(1f))

                Text(
                    if (iAmBatting) "You're batting" else "You're bowling",
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    fontWeight = FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Text(
                    "$battingScore-$battingWickets",
                    color = VoiidColor.textPrimary,
                    fontSize = 40.sp,
                    fontWeight = FontWeight.Bold,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )
                Text(
                    buildString {
                        append("${s.ballsBowled / 6}.${s.ballsBowled % 6}")
                        append(" / ${s.ballsTotal / 6}.0 ov")
                        s.target?.let { append("  ·  needs $it") }
                    },
                    color = VoiidColor.textSecondary,
                    fontSize = 13.sp,
                    modifier = Modifier.fillMaxWidth(),
                    textAlign = TextAlign.Center,
                )

                CricketPitch(
                    event = event,
                    ballToken = ballToken,
                    modifier = Modifier.padding(vertical = VoiidSpacing.md),
                    announcement = announcements.firstOrNull(),
                )

                // Picks. Mine is known to me the moment I tap; theirs is genuinely unavailable
                // until the ball resolves.
                Row(
                    Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceEvenly,
                ) {
                    MatchPickFace(
                        "You",
                        pick = if (ballOpen && iPicked) null else last?.picks?.getOrNull(mySeat),
                        covered = iPicked && ballOpen,
                    )
                    MatchPickFace(
                        "Them",
                        pick = if (ballOpen && theyPicked) null else last?.picks?.getOrNull(theirSeat),
                        covered = theyPicked && ballOpen,
                    )
                }

                val status = when {
                    s.finished && s.winnerUserId == null -> "Tied  ${s.scores.getOrElse(mySeat) { 0 }}–${s.scores.getOrElse(theirSeat) { 0 }}"
                    s.finished && s.winnerUserId == me -> "You win!  ${s.scores.getOrElse(mySeat) { 0 }}–${s.scores.getOrElse(theirSeat) { 0 }}"
                    s.finished -> "You lose.  ${s.scores.getOrElse(mySeat) { 0 }}–${s.scores.getOrElse(theirSeat) { 0 }}"
                    iPicked && !theyPicked -> "Waiting for them…"
                    !iPicked && theyPicked -> "They've picked — your turn"
                    iPicked -> "Revealing…"
                    else -> if (iAmBatting) "Pick your runs" else "Pick to bowl"
                }
                Text(
                    status,
                    color = if (s.finished) VoiidColor.primary else VoiidColor.textSecondary,
                    fontSize = if (s.finished) 20.sp else 14.sp,
                    fontWeight = if (s.finished) FontWeight.Bold else FontWeight.SemiBold,
                    modifier = Modifier.fillMaxWidth().padding(top = VoiidSpacing.md),
                    textAlign = TextAlign.Center,
                )

                Spacer(Modifier.weight(1f))

                if (!s.finished) {
                    // 0-6 in two rows: seven buttons in one row are too narrow to hit.
                    Column(
                        verticalArrangement = Arrangement.spacedBy(VoiidSpacing.sm),
                        modifier = Modifier.padding(bottom = VoiidSpacing.xl),
                    ) {
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            (0..3).forEach { n ->
                                MatchPickButton(n, enabled = !iPicked, Modifier.weight(1f)) {
                                    GameAudio.play("pick", gain = 0.45f)
                                    engine.pickCricket(context, n)
                                }
                            }
                        }
                        Row(horizontalArrangement = Arrangement.spacedBy(VoiidSpacing.sm)) {
                            (4..6).forEach { n ->
                                MatchPickButton(n, enabled = !iPicked, Modifier.weight(1f)) {
                                    GameAudio.play("pick", gain = 0.45f)
                                    engine.pickCricket(context, n)
                                }
                            }
                            Spacer(Modifier.weight(1f))
                        }
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
}

@Composable
private fun MatchPickFace(label: String, pick: Int?, covered: Boolean) {
    Column(horizontalAlignment = Alignment.CenterHorizontally) {
        Box(
            Modifier
                .size(64.dp)
                .clip(RoundedCornerShape(VoiidRadius.md))
                .background(VoiidColor.surfaceCard),
            contentAlignment = Alignment.Center,
        ) {
            Text(
                // A covered face is not "no pick" — it is a pick this client isn't allowed to
                // see yet, and the lock says so rather than implying nothing happened.
                if (covered) "🔒" else pick?.toString() ?: "—",
                color = VoiidColor.textPrimary,
                fontSize = 26.sp,
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
private fun MatchPickButton(
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

/**
 * The opponent's display name, for announcement and toss copy.
 *
 * Only this device knows what it calls its own contacts, so the name is resolved locally rather
 * than trusted from the wire — the same reasoning as [labelFor] in the Snake screen.
 */
private fun opponentName(s: GamesEngine.CricketState, me: String?): String {
    val mySeat = s.players.indexOf(me).coerceAtLeast(0)
    val theirSeat = if (mySeat == 0) 1 else 0
    val id = s.players.getOrNull(theirSeat) ?: return "They"
    return UserDirectory.displayName(id, "They")
}
