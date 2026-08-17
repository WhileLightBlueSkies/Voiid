package com.voiid.app.main.games

import androidx.compose.ui.graphics.Color

/**
 * A rigged batter and bowler for the pitch
 * (docs/games/VISUALS_AUDIO_AND_PARITY.md §4).
 *
 * WHAT THIS REPLACES: the batter was ONE rounded rectangle and the bat was another, and there was
 * no bowler at all — on a bowled the ball simply appeared at x = 0.86 and travelled left.
 *
 * SAME TECHNIQUE AS THE HAND (§3): a skeleton of bones, a pose is one angle per bone, and a shot
 * is three keyframes interpolated across the ball's own flight. Tapered capsules, one dark
 * outline over the silhouette, two-colour fill. At the 210 dp pitch height these run at, the
 * SILHOUETTE is everything and internal detail is wasted.
 *
 * WHAT DRIVES IT IS THE EXISTING TABLE, NOT A NEW ONE. `BallEvent.reach`, `.arc` and
 * `.flightDuration` already encode that a six travels 0.88 of the frame with 0.66 arc over 0.90 s
 * while a four stays deliberately flat — these figures are driven BY that.
 *
 * DELIBERATELY NOT 3D (§4.5). A well-drawn 2D side-on figure with real weight transfer reads
 * better at 210 dp than a low-poly 3D one, and it ships on both platforms from one spec — the
 * same call the repo already made for the coin.
 *
 * Ported from iOS `CricketFigures.swift`. Every angle is a parity surface.
 */
object CricketFigures {

    /** Seven bones, in degrees. 0 is the rest stance; positive rotates toward the bowler. */
    data class BatterPose(
        val torso: Double = 0.0,
        val head: Double = 0.0,
        val frontArm: Double = 0.0,
        val backArm: Double = 0.0,
        /** The bat's own angle, which is what the eye actually tracks. */
        val bat: Double = 24.0,
        val frontLeg: Double = 0.0,
        val backLeg: Double = 0.0,
        /** How far the front foot strides down the pitch, in figure heights. */
        val stride: Double = 0.0,
    )

    fun lerp(a: BatterPose, b: BatterPose, t: Double): BatterPose {
        val k = t.coerceIn(0.0, 1.0)
        fun m(x: Double, y: Double) = x + (y - x) * k
        return BatterPose(
            m(a.torso, b.torso), m(a.head, b.head),
            m(a.frontArm, b.frontArm), m(a.backArm, b.backArm),
            m(a.bat, b.bat),
            m(a.frontLeg, b.frontLeg), m(a.backLeg, b.backLeg),
            m(a.stride, b.stride),
        )
    }

    val STANCE = BatterPose()

    // ---- the shot table (§4.3) --------------------------------------------------------------
    //
    // Backlift -> contact -> follow-through, per event. Contact stays pinned at the existing
    // 170 ms bat strike, so the bat still meets the ball on the frame it does now.

    fun keyframes(event: BallEvent): Triple<BatterPose, BatterPose, BatterPose> = when {
        // LOFTED. The front leg plants, the torso rotates, the head tilts up and the bat sweeps
        // over the shoulder — the whole body goes.
        event is BallEvent.Runs && event.runs >= 5 -> Triple(
            BatterPose(-14.0, -6.0, -40.0, -30.0, 72.0, -6.0, 4.0, 0.02),
            BatterPose(18.0, -12.0, 30.0, 22.0, -30.0, 16.0, -8.0, 0.16),
            BatterPose(30.0, -16.0, 66.0, 54.0, -156.0, 18.0, -12.0, 0.18),
        )
        // ALONG THE GROUND. A FLAT bat and high bat speed, head still — this is the one shot
        // whose arc table says 0.10, and the pose has to agree with that.
        event is BallEvent.Runs && event.runs == 4 -> Triple(
            BatterPose(-10.0, -2.0, -34.0, -26.0, 58.0, -4.0, 2.0, 0.02),
            BatterPose(12.0, -2.0, 26.0, 18.0, -8.0, 12.0, -6.0, 0.14),
            BatterPose(20.0, -4.0, 52.0, 40.0, -124.0, 14.0, -8.0, 0.16),
        )
        // A DRIVE. Full extension, front leg strides.
        event is BallEvent.Runs && event.runs == 3 -> Triple(
            BatterPose(-9.0, -2.0, -30.0, -22.0, 52.0, -3.0, 2.0, 0.02),
            BatterPose(10.0, -3.0, 22.0, 16.0, -14.0, 11.0, -5.0, 0.13),
            BatterPose(16.0, -5.0, 40.0, 30.0, -100.0, 12.0, -6.0, 0.14),
        )
        // A PUSH. Short backlift, weight stays back, nothing past vertical.
        event is BallEvent.Runs -> Triple(
            BatterPose(-5.0, 0.0, -18.0, -12.0, 28.0, -1.0, 1.0, 0.01),
            BatterPose(5.0, -1.0, 12.0, 8.0, -16.0, 6.0, -2.0, 0.07),
            BatterPose(6.0, -1.0, 16.0, 10.0, -2.0, 6.0, -2.0, 0.07),
        )
        // A DEFENSIVE BLOCK. Bat straight down, soft hands, no follow-through at all.
        event is BallEvent.Dot -> Triple(
            BatterPose(-3.0, 0.0, -10.0, -8.0, 20.0, 0.0, 0.0, 0.01),
            BatterPose(2.0, 0.0, 4.0, 2.0, 2.0, 4.0, -1.0, 0.05),
            BatterPose(2.0, 0.0, 4.0, 2.0, 4.0, 4.0, -1.0, 0.05),
        )
        // A LEADING EDGE. Bat face open, the shot truncated.
        event is BallEvent.Caught -> Triple(
            BatterPose(-8.0, -2.0, -26.0, -20.0, 44.0, -2.0, 1.0, 0.02),
            BatterPose(8.0, -4.0, 18.0, 12.0, 20.0, 9.0, -4.0, 0.11),
            BatterPose(10.0, -6.0, 24.0, 16.0, -60.0, 9.0, -4.0, 0.11),
        )
        // A SWING AND A MISS — and the miss is the drama. The old pitch skipped the swing
        // entirely on a bowled, so a player watched their batter stand perfectly still while the
        // stumps fell over. A batter who is bowled DID play a shot; they missed it.
        else -> Triple(
            BatterPose(-12.0, -4.0, -36.0, -28.0, 62.0, -5.0, 3.0, 0.02),
            BatterPose(14.0, -6.0, 28.0, 20.0, -20.0, 13.0, -7.0, 0.15),
            BatterPose(24.0, -10.0, 58.0, 46.0, -140.0, 15.0, -9.0, 0.16),
        )
    }

    /**
     * The pose at progress [t] through a ball, blending backlift -> contact -> follow-through.
     *
     * Contact lands at `contactAt`, matching the pitch's existing 170 ms bat strike against the
     * event's own flight duration — so the bat meets the ball, not a moment either side.
     */
    fun pose(event: BallEvent, t: Double): BatterPose {
        val (backlift, contact, follow) = keyframes(event)
        // Android stores flight durations in `flightMs(runs)` rather than on the event, so the
        // contact point is derived from there. Same numbers as iOS's `flightDuration`.
        val durationS = when (event) {
            is BallEvent.Runs -> flightMs(event.runs) / 1000.0
            BallEvent.Dot -> 0.28
            BallEvent.Caught -> 0.52
            BallEvent.Bowled -> 0.40
        }
        val contactAt = minOf(0.55, 0.17 / maxOf(durationS, 0.2))
        if (t <= 0) return STANCE
        if (t < contactAt) {
            // Into the backlift, then down into contact. Two halves, so the bat visibly goes UP
            // before it comes down — a single blend would slide it sideways.
            val local = t / contactAt
            return if (local < 0.5) lerp(STANCE, backlift, local * 2)
                   else lerp(backlift, contact, (local - 0.5) * 2)
        }
        val local = minOf(1.0, (t - contactAt) / maxOf(1 - contactAt, 0.01))
        return lerp(contact, follow, local)
    }

    // ---- the bowler (§4.4) ------------------------------------------------------------------

    /**
     * RELEASE IS AT THE TOP OF THE ARM'S ARC, which is what makes the ball look bowled rather
     * than spawned. `CricketPitch` starts the ball at the release frame.
     */
    const val RELEASE_AT = 0.72

    /** One full rotation, accelerating into release. */
    fun bowlerArm(t: Double): Double {
        val eased = t * t * (3 - 2 * t)
        return -90 + eased * 360
    }

    /** A full run-up crosses from off-frame; a shortened one starts at the crease. */
    fun bowlerRun(t: Double, full: Boolean): Double {
        val from = if (full) 1.25 else 0.94
        return from + (0.86 - from) * minOf(1.0, t / RELEASE_AT)
    }

    // ---- palette ----------------------------------------------------------------------------

    val Kit = Color(0.94f, 0.94f, 0.96f)
    val Skin = Color(0.80f, 0.60f, 0.46f)
    val Ink = Color(0.10f, 0.12f, 0.14f)
    val BatFace = Color(0.91f, 0.75f, 0.46f)
    val BatEdge = Color(0.73f, 0.51f, 0.18f)
    val BowlerKit = Color(0.90f, 0.91f, 0.94f)
}
