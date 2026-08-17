package com.voiid.app.main.games

import androidx.compose.animation.core.Animatable
import androidx.compose.animation.core.FastOutSlowInEasing
import androidx.compose.animation.core.LinearEasing
import androidx.compose.animation.core.LinearOutSlowInEasing
import androidx.compose.animation.core.tween
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.offset
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.animation.core.animateFloatAsState
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.height
import androidx.compose.ui.text.style.TextAlign
import com.voiid.app.ui.theme.VoiidSpacing
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.draw.rotate
import androidx.compose.ui.draw.scale
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.voiid.app.ui.components.LocalVoiidHaptics
import com.voiid.app.ui.theme.VoiidRadius
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.geometry.Offset
import androidx.compose.foundation.Canvas

/**
 * What just happened on a ball, in the vocabulary the pitch animates
 * (docs/GAMES_HAND_CRICKET.md §5).
 *
 * A sealed type rather than a bag of booleans: exactly one of these is true per ball, and the
 * compiler enforcing that is what stops a "six AND wicket" frame from ever being drawable.
 */
sealed interface BallEvent {
    /** A scoring shot, 1-6. Every one of these gets a bat strike; the MOTION scales with runs. */
    data class Runs(val runs: Int) : BallEvent
    /** 0 — bat played, ball goes nowhere. */
    data object Dot : BallEvent
    /** Matched on 0-2: a soft edge into hands. */
    data object Caught : BallEvent
    /** Matched on 3-6: a big swing that missed. */
    data object Bowled : BallEvent

    companion object {
        /**
         * Derive the event from a resolved ball. The single mapping used by BOTH the bot and
         * online screens, so the two can never drift into animating the same ball differently.
         */
        fun of(runs: Int, wicket: Boolean, matchedPick: Int): BallEvent = when {
            wicket && CricketBot.wicketIsCatch(matchedPick) -> Caught
            wicket -> Bowled
            runs == 0 -> Dot
            else -> Runs(runs)
        }
    }
}

/**
 * The pitch: a styled ground that animates what a ball did.
 *
 * WHY TRANSFORMS AND NOT A 3D ENGINE. The depth comes from layered gradients, shadows, scale and
 * rotation — the same trick the game cards use. A real engine would be a new dependency and a new
 * build surface for two seconds of motion per ball, and would still need art to look like anything.
 *
 * EVERY SCORING SHOT SWINGS THE BAT, and the motion is what separates them: a single is a short
 * push into the infield, a six is a full arc over the rope. Earlier this animated only 4s and 6s
 * on the theory that restraint made the big hits land — in practice it made most balls feel dead,
 * so the distinction now lives in the SCALE of the motion (distance, arc height, trail, haptic
 * strength) rather than in whether anything moves at all.
 *
 * Driven by [event] plus [ballToken]: the token changes on every resolved ball, so two consecutive
 * sixes replay the motion instead of the second being swallowed as "same state".
 *
 * Mirrors iOS `CricketPitch.swift`.
 */
@Composable
fun CricketPitch(
    event: BallEvent?,
    ballToken: Int,
    modifier: Modifier = Modifier,
    /**
     * A match announcement to deliver ON THE PITCH — the innings changing, your role changing.
     *
     * IN HERE RATHER THAN OVER THE SCREEN. Delivered as a card on a dimmed scrim these looked
     * exactly like what they were: a system alert dropped on a game. The pitch is already the
     * thing the player watches for "what just happened", so the announcement belongs in that
     * same window — the players fade, the grass stays, the message is delivered where the ball
     * would be, and play resumes. Same surface, same place to look, no modal.
     */
    announcement: CricketAnnouncement? = null,
) {
    val haptics = LocalVoiidHaptics.current

    // Animatables (not animateFloatAsState) because they must RE-RUN on an unchanged value — a
    // second six is a new event, not a no-op.
    val strike = remember { Animatable(0f) }
    // 0..1 through the bowler's run-up and delivery, ahead of the ball's own flight.
    val delivery = remember { Animatable(0f) }
    // A full run-up only on the FIRST ball of an over; after that the bowler is already at the
    // crease (§4.4). A full run-up before all six balls gets old by the third.
    val fullRunUp = remember { mutableStateOf(true) }
    val flight = remember { Animatable(0f) }
    val bannerPop = remember { Animatable(0f) }
    var shown by remember { mutableStateOf<BallEvent?>(null) }
    var banner by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(ballToken) {
        val e = event ?: return@LaunchedEffect
        shown = e
        banner = null
        strike.snapTo(0f)
        delivery.snapTo(0f)
        flight.snapTo(0f)
        bannerPop.snapTo(0f)

        // THE BOWLER RUNS IN FIRST, and CONCURRENTLY: everything below this uses suspending
        // `animateTo`, so a sequential run-up would finish before the bat even started. The
        // run-up is launched on its own coroutine and the batter waits only for the release.
        val runUpMs = if (fullRunUp.value) 500 else 260
        val releaseMs = (runUpMs * CricketFigures.RELEASE_AT).toInt()
        launch { delivery.animateTo(1f, tween(runUpMs, easing = FastOutSlowInEasing)) }
        kotlinx.coroutines.delay(releaseMs.toLong())
        // After the first ball the bowler is already at the crease (§4.4). Set AFTER the two
        // timings above are captured, or this ball gets the next one's pacing.
        fullRunUp.value = false

        // Haptics are graded by how big the event is: a mini tick for small runs, a light knock
        // for a four, a rising thump for a six. A wicket gets its own signature so it never
        // feels like a reward.
        when (e) {
            is BallEvent.Runs -> {
                // Bat first, ball after contact — in that order, or the ball appears to move
                // before it was hit.
                strike.animateTo(1f, tween(170, easing = FastOutSlowInEasing))
                when {
                    e.runs >= 6 -> haptics.boundary()
                    e.runs == 4 -> haptics.soft()
                    else -> haptics.tap()
                }
                banner = bannerFor(e)
                bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing))
                flight.animateTo(1f, tween(flightMs(e.runs), easing = LinearEasing))
            }
            BallEvent.Dot -> {
                strike.animateTo(1f, tween(150, easing = FastOutSlowInEasing))
                haptics.tap()
                banner = "Dot ball"
                bannerPop.animateTo(1f, tween(200, easing = LinearOutSlowInEasing))
                flight.animateTo(1f, tween(280, easing = FastOutSlowInEasing))
            }
            BallEvent.Caught -> {
                strike.animateTo(1f, tween(160, easing = FastOutSlowInEasing))
                flight.animateTo(1f, tween(520, easing = FastOutSlowInEasing))
                haptics.rigid()
                banner = "Caught!"
                bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing))
            }
            BallEvent.Bowled -> {
                // A BOWLED SWINGS TOO. The old code played no swing at all, so a player watched
                // their batter stand perfectly still while the stumps fell over. A batter who is
                // bowled DID play a shot; they missed it, and the miss is the drama (§4.3).
                launch { strike.animateTo(1f, tween(170, easing = FastOutSlowInEasing)) }
                flight.animateTo(1f, tween(400, easing = LinearEasing))
                haptics.rigid()
                banner = "Bowled!"
                bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing))
            }
        }
        delay(650)
    }

    BoxWithConstraints(
        modifier
            .fillMaxWidth()
            .height(210.dp)
            .clip(RoundedCornerShape(VoiidRadius.lg))
            .background(
                // Sky over outfield over pitch — three bands, so the strip reads as ground
                // receding rather than a flat green rectangle.
                Brush.verticalGradient(
                    0f to Color(0xFF123C6B),
                    0.30f to Color(0xFF17512F),
                    0.62f to Color(0xFF248049),
                    1f to Color(0xFF14472A),
                )
            ),
    ) {
        val w = maxWidth
        val h = maxHeight
        val e = shown

        // THE PLAYERS FADE FOR AN ANNOUNCEMENT, THE GROUND STAYS. Everything that moves is
        // gated on this one value, so nothing the pitch happened to be animating can show
        // through the message. The grass itself is deliberately left up: this is a message ON
        // the pitch, not a panel replacing it.
        val clear by animateFloatAsState(
            targetValue = if (announcement == null) 0f else 1f,
            animationSpec = tween(300),
            label = "clear",
        )
        val playAlpha = 1f - clear

        // Drains linearly over the announcement's own lifetime, so the bar can never disagree
        // with when the message actually leaves. Keyed on the id, so a second announcement
        // restarts it rather than continuing the first one's countdown.
        val countdown = remember(announcement?.id) { Animatable(1f) }
        LaunchedEffect(announcement?.id) {
            val a = announcement ?: return@LaunchedEffect
            countdown.snapTo(1f)
            countdown.animateTo(0f, tween(a.durationMs.toInt(), easing = LinearEasing))
        }

        // Crowd band: a dotted strip along the skyline. Cheap, but it stops the top of the
        // frame reading as empty sky.
        Box(
            Modifier
                .fillMaxWidth()
                .height(h * 0.16f)
                .background(
                    Brush.horizontalGradient(
                        0f to Color(0xFF0E2E52),
                        0.5f to Color(0xFF14406E),
                        1f to Color(0xFF0E2E52),
                    )
                )
        )

        // The pitch strip itself, in perspective — narrower at the far end.
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .offset(x = w * 0.06f, y = h * 0.10f)
                .size(width = w * 0.72f, height = h * 0.26f)
                .clip(RoundedCornerShape(topStartPercent = 12, bottomStartPercent = 30))
                .background(Color(0xFFC9A97A).copy(alpha = 0.55f))
        )

        // Boundary rope — the thing a shot travels toward, so the motion has a target.
        Box(
            Modifier
                .align(Alignment.CenterEnd)
                .offset(x = -(w * 0.01f))
                .size(width = 4.dp, height = h * 0.62f)
                .clip(RoundedCornerShape(2.dp))
                .background(Color.White.copy(alpha = 0.40f))
        )

        // EVERY MOVING ELEMENT LIVES IN THIS ONE BOX, so clearing the pitch for an
        // announcement is a single alpha. Applying it per element would work until somebody
        // added a ninth and forgot, and a lone stump floating over the message is exactly the
        // kind of bug nobody notices until it ships.
        Box(Modifier.fillMaxSize().alpha(playAlpha)) {
        // Stumps. Knocked over on a bowled.
        val tilt = if (e == BallEvent.Bowled) 68f * flight.value else 0f
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .offset(x = w * 0.11f, y = h * 0.02f)
                .rotate(tilt)
                .size(width = 7.dp, height = 48.dp)
                .clip(RoundedCornerShape(2.dp))
                .background(Color(0xFFF6EBD2))
        )

        // THE BATTER, RIGGED (§4). Seven bones driven by the shot table in CricketFigures,
        // which is itself driven by the SAME flightMs numbers the ball uses — so a six's pose
        // and a six's flight cannot disagree.
        //
        // THE BOWLER, below it, did not exist at all: the ball used to appear at x = 0.86 with
        // nothing to have bowled it.
        Canvas(Modifier.fillMaxSize()) {
            e?.let { drawBatter(it, strike.value) }
            if (e != null && delivery.value > 0f) drawBowler(delivery.value, fullRunUp.value)
        }

        val p = flight.value
        val (bx, by) = ballPosition(e, p, w, h)

        // Motion trail — a few fading echoes behind the ball. Sells speed on the big hits and
        // is invisible on a push, because it scales with the same distance the ball travels.
        if (e is BallEvent.Runs && e.runs >= 3) {
            val trailCount = if (e.runs >= 6) 4 else 2
            repeat(trailCount) { i ->
                val lag = (i + 1) * 0.07f
                val tp = (p - lag).coerceAtLeast(0f)
                val (tx, ty) = ballPosition(e, tp, w, h)
                Box(
                    Modifier
                        .offset(x = tx, y = ty)
                        .size((13 - i * 2).dp)
                        .clip(CircleShape)
                        .alpha(0.28f * (1f - i / trailCount.toFloat()))
                        .background(Color(0xFFFF7A5C))
                )
            }
        }

        if (e != null) {
            Box(
                Modifier
                    .offset(x = bx, y = by)
                    .size(15.dp)
                    .clip(CircleShape)
                    .background(
                        Brush.radialGradient(
                            0f to Color(0xFFFF8A6B),
                            1f to Color(0xFFC62828),
                        )
                    )
            )
        }

        // A fielder's hands where a catch ends, so "Caught" has something to be caught by.
        if (e == BallEvent.Caught) {
            Box(
                Modifier
                    .offset(x = w * 0.60f, y = h * 0.30f)
                    .scale(0.75f + 0.45f * flight.value)
                    .size(30.dp)
                    .clip(CircleShape)
                    .background(Color.White.copy(alpha = 0.9f))
            )
        }

        banner?.let { text ->
            val isBig = e is BallEvent.Runs && (e.runs >= 4)
            val isWicket = e == BallEvent.Caught || e == BallEvent.Bowled
            Box(Modifier.fillMaxSize(), contentAlignment = Alignment.Center) {
                Text(
                    text,
                    color = Color.White,
                    fontSize = if (isBig) 40.sp else if (isWicket) 26.sp else 22.sp,
                    fontWeight = FontWeight.Black,
                    modifier = Modifier
                        // Overshoots then settles — the pop is what makes a six feel loud.
                        .scale(0.7f + 0.45f * bannerPop.value)
                        .alpha(bannerPop.value.coerceIn(0f, 1f))
                        .background(
                            if (isWicket) Color(0xFF8E1B1B).copy(alpha = 0.85f)
                            else Color.Black.copy(alpha = 0.32f),
                            RoundedCornerShape(VoiidRadius.md),
                        )
                        .padding(horizontal = 16.dp, vertical = 7.dp),
                )
            }
        }
        }   // end of the play-elements box

        // The announcement, drawn on the cleared ground. Plain type on the grass — no card, no
        // panel, no scrim. A container here would put a rectangle inside a rectangle and undo
        // the whole point of moving this into the pitch.
        announcement?.let { a ->
            Box(
                Modifier.fillMaxSize().alpha(clear),
                contentAlignment = Alignment.Center,
            ) {
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    modifier = Modifier.padding(horizontal = VoiidSpacing.lg),
                ) {
                    Text(
                        a.title,
                        color = Color.White,
                        fontSize = 25.sp,
                        fontWeight = FontWeight.Black,
                        textAlign = TextAlign.Center,
                    )
                    Spacer(Modifier.height(6.dp))
                    Text(
                        a.detail,
                        color = Color.White.copy(alpha = 0.92f),
                        fontSize = 14.sp,
                        fontWeight = FontWeight.Medium,
                        textAlign = TextAlign.Center,
                    )

                    // HOW LONG IS LEFT. A message that vanishes with no warning reads as a
                    // glitch — the player is mid-sentence and the screen changes under them. A
                    // bar draining to empty says "this is going, and here is how long you
                    // have", which turns a disappearance into an expected end.
                    //
                    // A thin line rather than a ring or a number: it has to be legible in
                    // peripheral vision while the eye is on the words, and a countdown you have
                    // to READ defeats the purpose of a countdown.
                    Spacer(Modifier.height(VoiidSpacing.sm))
                    Box(
                        Modifier
                            .width(132.dp)
                            .height(3.dp)
                            .clip(RoundedCornerShape(2.dp))
                            .background(Color.White.copy(alpha = 0.22f)),
                    ) {
                        Box(
                            Modifier
                                .fillMaxHeight()
                                .fillMaxWidth(countdown.value)
                                .clip(RoundedCornerShape(2.dp))
                                .background(Color.White.copy(alpha = 0.85f)),
                        )
                    }
                }
            }
        }
    }
}

private fun bannerFor(e: BallEvent.Runs): String = when (e.runs) {
    6 -> "SIX!"
    4 -> "FOUR!"
    else -> "${e.runs}"
}

/**
 * Bigger hits travel longer, so the ball is in the air proportionally longer.
 *
 * Not private: [CricketFigures] derives the batter's contact point from the same numbers, and a
 * second copy is how the bat stops meeting the ball.
 */
fun flightMs(runs: Int): Int = when (runs) {
    6 -> 900
    5 -> 780
    4 -> 640
    3 -> 540
    2 -> 460
    else -> 380
}

/**
 * Where the ball is at progress [p].
 *
 * ONE FUNCTION FOR BALL AND TRAIL, deliberately: the trail is the same path sampled slightly in
 * the past, so if the two were computed separately they could drift apart and the echoes would
 * stop lining up with the ball.
 */
private fun ballPosition(
    e: BallEvent?,
    p: Float,
    w: androidx.compose.ui.unit.Dp,
    h: androidx.compose.ui.unit.Dp,
): Pair<androidx.compose.ui.unit.Dp, androidx.compose.ui.unit.Dp> = when (e) {
    is BallEvent.Runs -> {
        // Distance and arc both scale with runs: a 1 is a push into the infield, a 6 clears
        // the rope. 4 stays deliberately FLAT — along the ground, unlike the airborne six.
        val reach = when (e.runs) {
            6 -> 0.88f
            5 -> 0.74f
            4 -> 0.80f
            3 -> 0.55f
            2 -> 0.42f
            else -> 0.30f
        }
        val arc = when (e.runs) {
            6 -> 0.66f
            5 -> 0.44f
            4 -> 0.10f      // flat and fast, the whole point of a four
            3 -> 0.26f
            2 -> 0.20f
            else -> 0.14f
        }
        val x = w * (0.24f + reach * p)
        val lift = -(h * arc) * (4f * p * (1f - p))
        x to (h * 0.46f + lift)
    }
    BallEvent.Dot -> {
        // Trickles a few pixels and stops — played, but going nowhere.
        (w * (0.24f + 0.05f * p)) to (h * 0.58f)
    }
    BallEvent.Caught -> {
        // Stops around 0.6 of the way out — caught in the deep, short of the rope.
        val x = w * (0.24f + 0.40f * p)
        val lift = -(h * 0.42f) * (4f * p * (1f - p))
        x to (h * 0.44f + lift)
    }
    BallEvent.Bowled -> {
        // Comes from the bowler's end INTO the stumps.
        (w * (0.86f - 0.74f * p)) to (h * 0.50f)
    }
    null -> (w * 0.24f) to (h * 0.52f)
}

// ---- the figures (§4) ------------------------------------------------------------------------
//
// Same limb construction on both platforms: tapered capsules with a dark outline stroked under a
// lighter fill, walked out from the feet. At this size the SILHOUETTE is everything.

/** One bone: an outlined capsule from [from] at [angle] degrees, returning its far end. */
private fun DrawScope.limb(
    from: Offset,
    angle: Double,
    length: Float,
    width: Float,
    colour: Color,
): Offset {
    val rad = Math.toRadians(angle - 90)
    val to = Offset(
        from.x + (kotlin.math.cos(rad) * length).toFloat(),
        from.y + (kotlin.math.sin(rad) * length).toFloat(),
    )
    drawLine(CricketFigures.Ink, from, to, strokeWidth = width + 2.2f, cap = StrokeCap.Round)
    drawLine(colour, from, to, strokeWidth = width, cap = StrokeCap.Round)
    return to
}

/** The batter, posed for [event] at progress [strike] through the shot. */
private fun DrawScope.drawBatter(event: BallEvent, strike: Float) {
    val pose = CricketFigures.pose(event, strike.toDouble())
    val scale = size.height * 0.30f
    // Feet on the batting crease, which is where the old rectangles stood.
    val feet = Offset(size.width * (0.175f + pose.stride.toFloat() * 0.35f), size.height * 0.62f)

    // Legs first — they sit behind the torso.
    limb(feet, 180 + pose.backLeg, scale * 0.34f, scale * 0.13f, CricketFigures.Kit)
    val hip = Offset(feet.x, feet.y - scale * 0.34f)
    limb(feet, 180 - pose.frontLeg, scale * 0.34f, scale * 0.13f, CricketFigures.Kit)

    // Torso and head.
    val shoulder = limb(hip, pose.torso, scale * 0.40f, scale * 0.19f, CricketFigures.Kit)
    val headR = scale * 0.11f
    drawCircle(CricketFigures.Ink, headR, Offset(shoulder.x, shoulder.y - headR * 1.1f))
    drawCircle(CricketFigures.Skin, headR * 0.82f, Offset(shoulder.x, shoulder.y - headR * 1.1f))

    // Arms, then the bat from the hands. The bat is what the eye tracks, so it is drawn last
    // and widest.
    val hands = limb(shoulder, 150 + pose.frontArm, scale * 0.30f, scale * 0.10f,
        CricketFigures.Skin)
    limb(shoulder, 160 + pose.backArm, scale * 0.28f, scale * 0.10f, CricketFigures.Skin)

    val batRad = Math.toRadians(pose.bat - 90)
    val batTip = Offset(
        hands.x + (kotlin.math.cos(batRad) * scale * 0.52f).toFloat(),
        hands.y + (kotlin.math.sin(batRad) * scale * 0.52f).toFloat(),
    )
    drawLine(CricketFigures.Ink, hands, batTip, strokeWidth = scale * 0.15f, cap = StrokeCap.Round)
    drawLine(
        Brush.linearGradient(listOf(CricketFigures.BatFace, CricketFigures.BatEdge),
            start = hands, end = batTip),
        hands, batTip, strokeWidth = scale * 0.11f, cap = StrokeCap.Round,
    )
}

/** The bowler: a figure running in with a rotating arm. Off-frame until a ball begins. */
private fun DrawScope.drawBowler(delivery: Float, full: Boolean) {
    val t = delivery.toDouble()
    val scale = size.height * 0.28f
    val feet = Offset(
        size.width * CricketFigures.bowlerRun(t, full).toFloat(),
        size.height * 0.60f,
    )

    // Legs stride as they run — a two-phase alternation, enough at this size.
    val phase = kotlin.math.sin(t * 18) * 14
    // The arm carries the ball over the top and releases at the apex.
    val arm = CricketFigures.bowlerArm(t)

    limb(feet, 180 - phase, scale * 0.34f, scale * 0.12f, CricketFigures.BowlerKit)
    val hip = Offset(feet.x, feet.y - scale * 0.34f)
    limb(feet, 180 + phase, scale * 0.34f, scale * 0.12f, CricketFigures.BowlerKit)

    val shoulder = limb(hip, -6.0, scale * 0.38f, scale * 0.18f, CricketFigures.BowlerKit)
    drawCircle(CricketFigures.Skin, scale * 0.10f,
        Offset(shoulder.x, shoulder.y - scale * 0.11f))

    limb(shoulder, arm - 150, scale * 0.32f, scale * 0.09f, CricketFigures.Skin)
    limb(shoulder, arm - 330, scale * 0.30f, scale * 0.09f, CricketFigures.Skin)
}
