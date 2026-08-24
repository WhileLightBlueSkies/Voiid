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
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
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
import androidx.compose.ui.geometry.CornerRadius
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
        // THE SWING RUNS CONCURRENTLY WITH THE BALL, and it is LINEAR — two changes.
        //
        // Linear because `strike` is a clock, not a position. CricketFigures.pose() now shapes
        // the swing itself: ease out into the backlift, hold at the top, accelerate into
        // contact, decelerate through the follow-through. A FastOutSlowInEasing tween on TOP of
        // that curve double-eases it, flattening the differences between shots back into one
        // generic ramp — exactly the "toy on a key" motion this is meant to stop.
        //
        // Concurrent because three of these branches used to AWAIT the full swing before
        // starting the ball, so the bat finished its follow-through before the ball had left
        // the middle. The bat still leads (the ball is delayed past contact); it just no longer
        // blocks. The swing also runs for the ball's OWN duration rather than a fixed 170 ms, so
        // a six's follow-through takes as long as a six's flight.
        val flightDurMs = when (e) {
            is BallEvent.Runs -> flightMs(e.runs)
            BallEvent.Dot -> 280
            BallEvent.Caught -> 520
            BallEvent.Bowled -> 400
        }
        val swingMs = 170 + (flightDurMs * 0.75f).toInt()
        launch { strike.animateTo(1f, tween(swingMs, easing = LinearEasing)) }

        // Haptics are graded by how big the event is: a mini tick for small runs, a light knock
        // for a four, a rising thump for a six. A wicket gets its own signature so it never
        // feels like a reward.
        when (e) {
            is BallEvent.Runs -> {
                when {
                    e.runs >= 6 -> haptics.boundary()
                    e.runs == 4 -> haptics.soft()
                    else -> haptics.tap()
                }
                banner = bannerFor(e)
                launch { bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing)) }
                // Delayed past contact, so the ball is struck rather than seen to move first.
                kotlinx.coroutines.delay(120)
                flight.animateTo(1f, tween(flightDurMs, easing = LinearEasing))
            }
            BallEvent.Dot -> {
                haptics.tap()
                banner = "Dot ball"
                launch { bannerPop.animateTo(1f, tween(200, easing = LinearOutSlowInEasing)) }
                kotlinx.coroutines.delay(120)
                flight.animateTo(1f, tween(flightDurMs, easing = LinearEasing))
            }
            BallEvent.Caught -> {
                haptics.rigid()
                banner = "Caught!"
                launch { bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing)) }
                kotlinx.coroutines.delay(120)
                flight.animateTo(1f, tween(flightDurMs, easing = LinearEasing))
            }
            BallEvent.Bowled -> {
                // A BOWLED SWINGS TOO. The old code played no swing at all, so a player watched
                // their batter stand perfectly still while the stumps fell over. A batter who is
                // bowled DID play a shot; they missed it, and the miss is the drama (§4.3). No
                // contact delay here — nothing was hit, so the ball never waits on the bat.
                haptics.rigid()
                banner = "Bowled!"
                launch { bannerPop.animateTo(1f, tween(220, easing = LinearOutSlowInEasing)) }
                flight.animateTo(1f, tween(flightDurMs, easing = LinearEasing))
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
                // UNDER THE FEET, NOT THROUGH THE WAIST. At +0.10h with 0.55 alpha this rode
                // up into the batter's body and read as a translucent bar laid over the pitch
                // rather than as ground the players stand on. It belongs below the figures.
                .offset(x = w * 0.06f, y = h * 0.17f)
                .size(width = w * 0.72f, height = h * 0.22f)
                .clip(RoundedCornerShape(topStartPercent = 12, bottomStartPercent = 30))
                .background(Color(0xFFC9A97A).copy(alpha = 0.32f))
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
            // MORE ECHOES, CLOSER TOGETHER. Four widely-spaced dots read as four dots; a denser
            // tail reads as one blurred streak, which is the point of a trail.
            val trailCount = if (e.runs >= 6) 7 else 5
            repeat(trailCount) { i ->
                val lag = (i + 1) * 0.035f
                val tp = p - lag
                // Nothing until the ball has a past — otherwise the whole tail stacks up on the
                // bat at the moment of contact.
                if (tp > 0f) {
                    val (tx, ty) = ballPosition(e, tp, w, h)
                    val fade = 1f - i / trailCount.toFloat()
                    Box(
                        Modifier
                            .offset(x = tx, y = ty)
                            .size((14f * fade).dp)
                            .clip(CircleShape)
                            .alpha(0.34f * fade * fade)
                            .background(Color(0xFFFF7A5C))
                    )
                }
            }
        }

        if (e != null) {
            // A ball in the air is FURTHER AWAY, so it reads smaller. Without this the six's
            // apex looks like the ball is sliding up a wall rather than going over the field.
            val arcOf = when (e) {
                is BallEvent.Runs -> when (e.runs) {
                    6 -> 0.66f; 5 -> 0.44f; 4 -> 0.10f; 3 -> 0.26f; 2 -> 0.20f; else -> 0.14f
                }
                BallEvent.Caught -> 0.42f
                else -> 0f
            }
            val baseY = if (e == BallEvent.Dot) h * 0.58f else if (e == BallEvent.Caught) h * 0.44f else h * 0.46f
            val height = ((baseY - by) / maxOf(h * arcOf, 1.dp)).coerceAtLeast(0f)
            val depth = 1f - 0.22f * minOf(1f, height)
            Box(
                Modifier
                    .offset(x = bx, y = by)
                    .size(15.dp)
                    .scale(depth)
                    // The seam, which is the only thing that can show the ball SPINNING. A plain
                    // disc rotating is indistinguishable from a disc standing still.
                    .rotate(p * 900f)
                    .clip(CircleShape)
                    .background(
                        Brush.radialGradient(
                            0f to Color(0xFFFF8A6B),
                            1f to Color(0xFFC62828),
                        )
                    ),
                contentAlignment = Alignment.Center,
            ) {
                Canvas(Modifier.fillMaxSize()) {
                    drawOval(
                        Color.White.copy(alpha = 0.65f),
                        topLeft = Offset(size.width * 0.07f, size.height * 0.30f),
                        size = androidx.compose.ui.geometry.Size(size.width * 0.86f, size.height * 0.40f),
                        style = Stroke(width = 1.2.dp.toPx()),
                    )
                }
            }
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
            // OUT OF THE FLIGHT CORRIDOR. This used to sit dead centre, which is exactly where
            // the ball travels (baseY is 0.46h and the arc lifts from there) — so on the two
            // shots that matter most, a four and a six, the banner covered the entire flight
            // from the bat to the rope. The animation ran correctly and could not be seen.
            //
            // Up here it reads as a scoreboard call over the ground rather than a label pinned
            // on top of the action, and the whole corridor stays clear.
            Box(
                Modifier.fillMaxSize().padding(top = 10.dp),
                contentAlignment = Alignment.TopCenter,
            ) {
                Text(
                    text,
                    color = Color.White,
                    fontSize = if (isBig) 34.sp else if (isWicket) 24.sp else 20.sp,
                    fontWeight = FontWeight.Black,
                    modifier = Modifier
                        // Overshoots then settles — the pop is what makes a six feel loud.
                        .scale(0.7f + 0.45f * bannerPop.value)
                        .alpha(bannerPop.value.coerceIn(0f, 1f))
                        .background(
                            if (isWicket) Color(0xFF8E1B1B).copy(alpha = 0.85f)
                            else Color.Black.copy(alpha = 0.38f),
                            RoundedCornerShape(VoiidRadius.md),
                        )
                        .padding(horizontal = 14.dp, vertical = 6.dp),
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
        // WHY THE EASING LIVES HERE AND NOT IN THE ANIMATION. `flight` is driven linearly on
        // purpose — it is a clock, not a position. A hit ball does not travel at a constant
        // rate: it leaves the bat fast and is dragged down by air the whole way, so the
        // horizontal component decays while the vertical follows a real parabola against it.
        // Easing the ANIMATION instead eases both axes together, which bends the arc itself and
        // is what made the flight look like a tweened sprite rather than a struck ball.
        val ease = 1f - Math.pow((1f - p).toDouble(), 2.2).toFloat()
        val x = w * (0.24f + reach * ease)
        val lift = -(h * arc) * (4f * ease * (1f - ease))
        x to (h * 0.46f + lift)
    }
    BallEvent.Dot -> {
        // Trickles a few pixels and stops — played, but going nowhere.
        (w * (0.24f + 0.05f * p)) to (h * 0.58f)
    }
    BallEvent.Caught -> {
        // Stops around 0.6 of the way out — caught in the deep, short of the rope.
        val ease = 1f - Math.pow((1f - p).toDouble(), 2.2).toFloat()
        val x = w * (0.24f + 0.40f * ease)
        val lift = -(h * 0.42f) * (4f * ease * (1f - ease))
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

/**
 * The batter, posed for [event] at progress [strike] through the shot.
 *
 * JOINTS SHARE COORDINATES, which is what closes the gaps. The previous version drew each bone
 * from a point it computed independently — the torso rect started at `shoulder.y` while the hip
 * sat a third of a figure below it, and the arms rooted at a bare `shoulder` point whose covering
 * ellipse was thinner than the arm strokes themselves. At rest that reads as one body; at a six's
 * +66° arm and +30° torso the limbs swing clear of the mass they are supposed to grow out of and
 * the figure comes apart at the neck and shoulder.
 *
 * So: the torso is a QUAD between the actual hip and the actual shoulder (it leans with the bone
 * instead of staying an upright rectangle), the head rides the torso's own direction, and every
 * joint gets a cap disc sized to the THICKER of the two bones it joins. A cap smaller than its
 * limb is not a joint, it is a hole.
 */
private fun DrawScope.drawBatter(event: BallEvent, strike: Float) {
    val pose = CricketFigures.pose(event, strike.toDouble())
    val scale = size.height * 0.30f
    val feet = Offset(size.width * (0.175f + pose.stride.toFloat() * 0.35f), size.height * 0.62f)
    drawOval(Color.Black.copy(alpha = 0.20f),
        topLeft = Offset(feet.x - scale * 0.36f, feet.y - scale * 0.035f),
        size = androidx.compose.ui.geometry.Size(scale * 0.72f, scale * 0.14f))

    // The skeleton is solved BEFORE anything is drawn, so every part is placed against the same
    // joint positions rather than against its own guess at them.
    val hip = Offset(feet.x, feet.y - scale * 0.34f)
    val torsoRad = Math.toRadians(pose.torso - 90)
    val torsoLen = scale * 0.40f
    val shoulder = Offset(
        hip.x + (kotlin.math.cos(torsoRad) * torsoLen).toFloat(),
        hip.y + (kotlin.math.sin(torsoRad) * torsoLen).toFloat(),
    )
    val upX = (shoulder.x - hip.x) / torsoLen
    val upY = (shoulder.y - hip.y) / torsoLen
    val sideX = -upY
    val sideY = upX

    // Legs first — they sit behind the torso, and both are rooted at the same hip.
    val legW = scale * 0.13f
    val backFoot = limb(hip, 180 + pose.backLeg, scale * 0.34f, legW, CricketFigures.Kit)
    val frontFoot = limb(hip, 180 - pose.frontLeg, scale * 0.34f, legW, CricketFigures.Kit)
    // Pads along each shin, oriented with the leg rather than as a fixed upright box.
    for ((f, ang) in listOf(backFoot to 180 + pose.backLeg, frontFoot to 180 - pose.frontLeg)) {
        val r = Math.toRadians(ang - 90)
        drawLine(
            Color.White,
            Offset(f.x - (kotlin.math.cos(r) * scale * 0.22f).toFloat(),
                   f.y - (kotlin.math.sin(r) * scale * 0.22f).toFloat()),
            Offset(f.x - (kotlin.math.cos(r) * scale * 0.02f).toFloat(),
                   f.y - (kotlin.math.sin(r) * scale * 0.02f).toFloat()),
            strokeWidth = scale * 0.14f, cap = StrokeCap.Round,
        )
    }
    // Shoes at the ACTUAL foot positions. These used to be pinned to `feet`, so a striding front
    // leg left its shoe behind at the crease.
    for (f in listOf(backFoot, frontFoot)) {
        drawOval(CricketFigures.Shoe, topLeft = Offset(f.x - scale * 0.14f, f.y - scale * 0.05f),
            size = androidx.compose.ui.geometry.Size(scale * 0.28f, scale * 0.10f))
    }
    joint(hip, legW * 1.35f, CricketFigures.Kit)

    // TORSO AS A QUAD between the two real joints. A rectangle pinned to `shoulder.y` (what was
    // here) cannot lean, so any torso rotation tore it open at the hip.
    val hipHalf = scale * 0.15f
    val shHalf = scale * 0.19f
    fun quad(hh: Float, sh: Float) = Path().apply {
        moveTo(hip.x + sideX * hh, hip.y + sideY * hh)
        lineTo(shoulder.x + sideX * sh, shoulder.y + sideY * sh)
        lineTo(shoulder.x - sideX * sh, shoulder.y - sideY * sh)
        lineTo(hip.x - sideX * hh, hip.y - sideY * hh)
        close()
    }
    drawPath(quad(hipHalf, shHalf), CricketFigures.Ink)
    drawPath(
        quad(hipHalf - 1.6f, shHalf - 1.6f),
        Brush.linearGradient(listOf(CricketFigures.Jersey, CricketFigures.JerseyShadow),
            start = shoulder, end = hip),
    )

    joint(shoulder, shHalf * 2f, CricketFigures.Jersey)

    // Head, riding the torso's own direction so the neck stays closed at any rotation. It used to
    // hang at a fixed offset below `shoulder`, which opened a gap the moment the body turned.
    val headR = scale * 0.11f
    drawLine(CricketFigures.Ink, shoulder,
        Offset(shoulder.x + upX * headR * 0.9f, shoulder.y + upY * headR * 0.9f),
        strokeWidth = scale * 0.11f + 2.2f, cap = StrokeCap.Round)
    drawLine(CricketFigures.Skin, shoulder,
        Offset(shoulder.x + upX * headR * 0.9f, shoulder.y + upY * headR * 0.9f),
        strokeWidth = scale * 0.11f, cap = StrokeCap.Round)

    val headC = Offset(shoulder.x + upX * headR * 1.90f, shoulder.y + upY * headR * 1.90f)
    drawCircle(CricketFigures.Ink, headR + 1.4f, headC)
    drawCircle(CricketFigures.Skin, headR, headC)
    // Helmet shell over the top half, rotated with the head so it never floats off.
    rotate(pose.head.toFloat(), headC) {
        drawOval(CricketFigures.Helmet,
            topLeft = Offset(headC.x - headR * 1.14f, headC.y - headR * 1.30f),
            size = androidx.compose.ui.geometry.Size(headR * 2.28f, headR * 1.70f))
    }
    // The grille, which is what makes it read as a batter rather than a bare head.
    drawLine(CricketFigures.Ink,
        Offset(headC.x - headR * 1.05f, headC.y + headR * 0.10f),
        Offset(headC.x - headR * 0.20f, headC.y + headR * 0.62f),
        strokeWidth = maxOf(1.4f, scale * 0.035f), cap = StrokeCap.Round)

    // ARMS, rooted at the shoulder joint that now has a cap wide enough to cover them. Front arm
    // last so the hands land on top.
    // THE HANDS TRAVEL, AND THE ARMS FOLLOW THEM. The arm is no longer a fixed-length spoke
    // whose tip happens to be the grip — the grip is placed first (shoulder, plus the shot's own
    // drop/drive along the torso's axes) and the arms are then drawn TO it. That is what moves
    // the pivot, and a moving pivot is the difference between a swing and a rotation.
    val armW = scale * 0.10f
    val frontRad = Math.toRadians(150 + pose.frontArm - 90)
    val hands = Offset(
        shoulder.x + sideX * pose.handDrive.toFloat() * scale * 2.2f -
            upX * pose.handDrop.toFloat() * scale * 2.2f +
            (kotlin.math.cos(frontRad) * scale * 0.30f).toFloat(),
        shoulder.y + sideY * pose.handDrive.toFloat() * scale * 2.2f -
            upY * pose.handDrop.toFloat() * scale * 2.2f +
            (kotlin.math.sin(frontRad) * scale * 0.30f).toFloat(),
    )
    // Back arm reaches the same grip from a slightly different shoulder point, so the two arms
    // converge on the bat instead of splaying off it.
    val backShoulder = Offset(shoulder.x - sideX * scale * 0.05f, shoulder.y - sideY * scale * 0.05f)
    bone(backShoulder, hands, armW, CricketFigures.Skin)
    bone(shoulder, hands, armW, CricketFigures.Skin)
    // Gloves, covering the arm ends — the joint the bat grows out of.
    joint(hands, armW * 1.55f, Color.White)

    // The bat, from inside the gloves so the handle is never seen to start in mid-air. Handle and
    // blade are two widths: a bat is not a uniform stick, and the taper is most of what reads as
    // "bat" at this size.
    val batRad = Math.toRadians(pose.bat - 90)
    fun along(d: Float) = Offset(
        hands.x + (kotlin.math.cos(batRad) * d).toFloat(),
        hands.y + (kotlin.math.sin(batRad) * d).toFloat(),
    )
    val grip = along(-scale * 0.05f)
    val batShoulder = along(scale * 0.20f)
    val batTip = along(scale * 0.54f)
    drawLine(CricketFigures.Ink, grip, batShoulder,
        strokeWidth = scale * 0.075f + 2.2f, cap = StrokeCap.Round)
    drawLine(CricketFigures.Ink.copy(alpha = 0.85f), grip, batShoulder,
        strokeWidth = scale * 0.075f, cap = StrokeCap.Round)
    drawLine(CricketFigures.Ink, batShoulder, batTip,
        strokeWidth = scale * 0.155f, cap = StrokeCap.Round)
    drawLine(
        Brush.linearGradient(listOf(CricketFigures.BatFace, CricketFigures.BatEdge),
            start = batShoulder, end = batTip),
        batShoulder, batTip, strokeWidth = scale * 0.115f, cap = StrokeCap.Round,
    )
}

/**
 * A joint cap: outline disc under a fill disc, at least as wide as the widest bone meeting here.
 * This is the piece that was missing, and its absence is every gap in the figure.
 */
private fun DrawScope.bone(from: Offset, to: Offset, width: Float, colour: Color) {
    drawLine(CricketFigures.Ink, from, to, strokeWidth = width + 2.2f, cap = StrokeCap.Round)
    drawLine(colour, from, to, strokeWidth = width, cap = StrokeCap.Round)
}

/**
 * A joint cap: outline disc under a fill disc, at least as wide as the widest bone meeting here.
 * This is the piece that was missing, and its absence is every gap in the figure.
 */
private fun DrawScope.joint(at: Offset, width: Float, colour: Color) {
    drawCircle(CricketFigures.Ink, width * 0.5f + 1.1f, at)
    drawCircle(colour, width * 0.5f, at)
}

/** The bowler: a figure running in with a rotating arm. Off-frame until a ball begins. */
private fun DrawScope.drawBowler(delivery: Float, full: Boolean) {
    val t = delivery.toDouble()
    val scale = size.height * 0.28f
    val feet = Offset(
        size.width * CricketFigures.bowlerRun(t, full).toFloat(),
        size.height * 0.60f,
    )
    drawOval(Color.Black.copy(alpha = 0.20f),
        topLeft = Offset(feet.x - scale * 0.36f, feet.y - scale * 0.035f),
        size = androidx.compose.ui.geometry.Size(scale * 0.72f, scale * 0.14f))

    // Legs stride as they run — a two-phase alternation, enough at this size.
    val phase = kotlin.math.sin(t * 18) * 14
    // The arm carries the ball over the top and releases at the apex.
    val arm = CricketFigures.bowlerArm(t)

    // Same joint-closing skeleton as the batter.
    val hip = Offset(feet.x, feet.y - scale * 0.34f)
    val torsoRad = Math.toRadians(-6.0 - 90)
    val torsoLen = scale * 0.38f
    val shoulder = Offset(
        hip.x + (kotlin.math.cos(torsoRad) * torsoLen).toFloat(),
        hip.y + (kotlin.math.sin(torsoRad) * torsoLen).toFloat(),
    )
    val upX = (shoulder.x - hip.x) / torsoLen
    val upY = (shoulder.y - hip.y) / torsoLen
    val sideX = -upY
    val sideY = upX

    val legW = scale * 0.12f
    val backFoot = limb(hip, 180 - phase, scale * 0.34f, legW, CricketFigures.BowlerKit)
    val frontFoot = limb(hip, 180 + phase, scale * 0.34f, legW, CricketFigures.BowlerKit)
    for (f in listOf(backFoot, frontFoot)) {
        drawOval(CricketFigures.Shoe, topLeft = Offset(f.x - scale * 0.14f, f.y - scale * 0.05f),
            size = androidx.compose.ui.geometry.Size(scale * 0.28f, scale * 0.10f))
    }
    joint(hip, legW * 1.35f, CricketFigures.BowlerKit)

    val hipHalf = scale * 0.14f
    val shHalf = scale * 0.18f
    fun quad(hh: Float, sh: Float) = Path().apply {
        moveTo(hip.x + sideX * hh, hip.y + sideY * hh)
        lineTo(shoulder.x + sideX * sh, shoulder.y + sideY * sh)
        lineTo(shoulder.x - sideX * sh, shoulder.y - sideY * sh)
        lineTo(hip.x - sideX * hh, hip.y - sideY * hh)
        close()
    }
    drawPath(quad(hipHalf, shHalf), CricketFigures.Ink)
    drawPath(
        quad(hipHalf - 1.5f, shHalf - 1.5f),
        Brush.linearGradient(listOf(CricketFigures.BowlerKit, CricketFigures.JerseyShadow),
            start = shoulder, end = hip),
    )

    joint(shoulder, shHalf * 2f, CricketFigures.BowlerKit)

    val headR = scale * 0.10f
    drawLine(CricketFigures.Ink, shoulder,
        Offset(shoulder.x + upX * headR * 0.9f, shoulder.y + upY * headR * 0.9f),
        strokeWidth = scale * 0.10f + 2.0f, cap = StrokeCap.Round)
    drawLine(CricketFigures.Skin, shoulder,
        Offset(shoulder.x + upX * headR * 0.9f, shoulder.y + upY * headR * 0.9f),
        strokeWidth = scale * 0.10f, cap = StrokeCap.Round)

    val headC = Offset(shoulder.x + upX * headR * 1.85f, shoulder.y + upY * headR * 1.85f)
    drawCircle(CricketFigures.Ink, headR + 1.3f, headC)
    drawCircle(CricketFigures.Skin, headR, headC)
    drawOval(CricketFigures.Hair,
        topLeft = Offset(headC.x - headR * 1.02f, headC.y - headR * 1.20f),
        size = androidx.compose.ui.geometry.Size(headR * 2.04f, headR * 1.30f))

    val armW = scale * 0.09f
    val back = limb(shoulder, arm - 330, scale * 0.30f, armW, CricketFigures.Skin)
    val front = limb(shoulder, arm - 150, scale * 0.32f, armW, CricketFigures.Skin)
    joint(back, armW * 1.1f, CricketFigures.Skin)
    joint(front, armW * 1.1f, CricketFigures.Skin)
}
