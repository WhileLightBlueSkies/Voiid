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
    val flight = remember { Animatable(0f) }
    val bannerPop = remember { Animatable(0f) }
    var shown by remember { mutableStateOf<BallEvent?>(null) }
    var banner by remember { mutableStateOf<String?>(null) }

    LaunchedEffect(ballToken) {
        val e = event ?: return@LaunchedEffect
        shown = e
        banner = null
        strike.snapTo(0f)
        flight.snapTo(0f)
        bannerPop.snapTo(0f)

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
                // No connecting swing — the stumps take it instead.
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

        // The batter: a simple figure that leans into the shot. Reads as a person at a glance
        // without needing art.
        val lean = 10f * strike.value
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .offset(x = w * 0.155f, y = h * 0.0f)
                .rotate(lean)
                .size(width = 13.dp, height = 40.dp)
                .clip(RoundedCornerShape(6.dp))
                .background(Color(0xFFEDE7F6))
        )

        // The bat. Swings through on any shot; stays down on a bowled.
        val swing = -78f * strike.value
        Box(
            Modifier
                .align(Alignment.CenterStart)
                .offset(x = w * 0.205f, y = h * 0.03f)
                .rotate(24f + swing)
                .size(width = 11.dp, height = 56.dp)
                .clip(RoundedCornerShape(3.dp))
                .background(
                    Brush.verticalGradient(
                        0f to Color(0xFFE8BE76),
                        1f to Color(0xFFB9822F),
                    )
                )
        )

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

/** Bigger hits travel longer, so the ball is in the air proportionally longer. */
private fun flightMs(runs: Int): Int = when (runs) {
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
