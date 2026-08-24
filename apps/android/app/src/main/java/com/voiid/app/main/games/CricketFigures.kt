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
        /**
         * WHERE THE HANDS ARE, in figure heights, relative to the shoulder socket.
         *
         * THE PIVOT HAS TO MOVE OR IT IS NOT A SWING. The bat used to be a line from a hand
         * position that barely travelled, so whatever the bat angle did, it swept a circle
         * around a fixed point — a clock hand, not a bat. In a real shot the hands DROP out of
         * the backlift and DRIVE forward through the line of the ball; the bat's head speed is
         * mostly that translation, not the rotation.
         */
        val handDrop: Double = 0.0,
        val handDrive: Double = 0.0,
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
            m(a.handDrop, b.handDrop), m(a.handDrive, b.handDrive),
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
        event is BallEvent.Runs && event.runs == 6 -> Triple(
            BatterPose(-14.0, -6.0, -40.0, -30.0, 72.0, -6.0, 4.0, 0.02, -0.06, -0.04),
            BatterPose(18.0, -12.0, 30.0, 22.0, -30.0, 16.0, -8.0, 0.16, 0.05, 0.14),
            BatterPose(30.0, -16.0, 66.0, 54.0, -156.0, 18.0, -12.0, 0.18, -0.1, 0.2),
        )
        event is BallEvent.Runs && event.runs == 5 -> Triple(
            BatterPose(-12.0, -4.0, -36.0, -28.0, 64.0, -5.0, 3.0, 0.02, -0.05, -0.03),
            BatterPose(16.0, -8.0, 28.0, 20.0, -20.0, 15.0, -7.0, 0.15, 0.05, 0.12),
            BatterPose(24.0, -10.0, 54.0, 42.0, -138.0, 16.0, -10.0, 0.17, -0.08, 0.17),
        )
        // ALONG THE GROUND. A FLAT bat and high bat speed, head still — this is the one shot
        // whose arc table says 0.10, and the pose has to agree with that.
        event is BallEvent.Runs && event.runs == 4 -> Triple(
            BatterPose(-10.0, -2.0, -34.0, -26.0, 58.0, -4.0, 2.0, 0.02, -0.04, -0.03),
            BatterPose(12.0, -2.0, 26.0, 18.0, -8.0, 12.0, -6.0, 0.14, 0.02, 0.13),
            BatterPose(20.0, -4.0, 52.0, 40.0, -124.0, 14.0, -8.0, 0.16, -0.03, 0.19),
        )
        // A DRIVE. Full extension, front leg strides.
        event is BallEvent.Runs && event.runs == 3 -> Triple(
            BatterPose(-9.0, -2.0, -30.0, -22.0, 52.0, -3.0, 2.0, 0.02, -0.04, -0.02),
            BatterPose(10.0, -3.0, 22.0, 16.0, -14.0, 11.0, -5.0, 0.13, 0.03, 0.1),
            BatterPose(16.0, -5.0, 40.0, 30.0, -100.0, 12.0, -6.0, 0.14, -0.05, 0.14),
        )
        // WRISTY CLIP. A two is a controlled shot into space with a compact rotation.
        event is BallEvent.Runs && event.runs == 2 -> Triple(
            BatterPose(-7.0, 1.0, -24.0, -16.0, 38.0, -2.0, 2.0, 0.02, -0.03, -0.02),
            BatterPose(8.0, 0.0, 16.0, 10.0, -20.0, 8.0, -3.0, 0.10, 0.02, 0.07),
            BatterPose(12.0, -1.0, 28.0, 20.0, -46.0, 10.0, -5.0, 0.11, -0.03, 0.1),
        )
        // A PUSH. Short backlift, weight stays back, nothing past vertical.
        //
        // WAS `else`, WHICH MADE EVERY BRANCH BELOW IT UNREACHABLE — a dot ball, a catch and a
        // bowled all resolved to this push, and Kotlin rejects the file outright because `else`
        // must come last. It is the ONE-RUN case: the comment already says so, and the real
        // fallback is the swing-and-miss at the bottom.
        event is BallEvent.Runs && event.runs == 1 -> Triple(
            BatterPose(-5.0, 0.0, -18.0, -12.0, 28.0, -1.0, 1.0, 0.01, -0.02, -0.01),
            BatterPose(5.0, -1.0, 12.0, 8.0, -16.0, 6.0, -2.0, 0.07, 0.01, 0.05),
            BatterPose(6.0, -1.0, 16.0, 10.0, -2.0, 6.0, -2.0, 0.07, -0.01, 0.06),
        )
        // A DEFENSIVE BLOCK. Bat straight down, soft hands, no follow-through at all.
        event is BallEvent.Dot -> Triple(
            BatterPose(-3.0, 0.0, -10.0, -8.0, 20.0, 0.0, 0.0, 0.01, -0.01, 0.0),
            BatterPose(2.0, 0.0, 4.0, 2.0, 2.0, 4.0, -1.0, 0.05, 0.01, 0.02),
            BatterPose(2.0, 0.0, 4.0, 2.0, 4.0, 4.0, -1.0, 0.05, 0.01, 0.02),
        )
        // A LEADING EDGE. Bat face open, the shot truncated.
        event is BallEvent.Caught -> Triple(
            BatterPose(-8.0, -2.0, -26.0, -20.0, 44.0, -2.0, 1.0, 0.02, -0.03, -0.02),
            BatterPose(8.0, -4.0, 18.0, 12.0, 20.0, 9.0, -4.0, 0.11, 0.03, 0.08),
            BatterPose(10.0, -6.0, 24.0, 16.0, -60.0, 9.0, -4.0, 0.11, -0.04, 0.11),
        )
        // A SWING AND A MISS — and the miss is the drama. The old pitch skipped the swing
        // entirely on a bowled, so a player watched their batter stand perfectly still while the
        // stumps fell over. A batter who is bowled DID play a shot; they missed it.
        else -> Triple(
            BatterPose(-12.0, -4.0, -36.0, -28.0, 62.0, -5.0, 3.0, 0.02, -0.05, -0.03),
            BatterPose(14.0, -6.0, 28.0, 20.0, -20.0, 13.0, -7.0, 0.15, 0.05, 0.13),
            BatterPose(24.0, -10.0, 58.0, 46.0, -140.0, 15.0, -9.0, 0.16, -0.09, 0.18),
        )
    }

    /**
     * The pose at progress [t] through a ball, blending backlift -> contact -> follow-through.
     *
     * Contact lands at `contactAt`, matching the pitch's existing 170 ms bat strike against the
     * event's own flight duration — so the bat meets the ball, not a moment either side.
     */
    fun pose(event: BallEvent, t: Double): BatterPose {
        val p = armPose(event, t)

        // WRIST LAG, FROM THE ACTUAL ARM VELOCITY. The bat angle in the keyframes is the
        // ARM-DRIVEN target; the real bat sits behind it while the arms accelerate and ahead of
        // it once they brake. Without this the bat and arms move in lockstep and there is no snap
        // anywhere — every frame is the same rigid triangle rotating.
        //
        // MEASURED, NOT AUTHORED. An earlier version wrote an `armSpeed` term per phase by hand,
        // and the phases disagreed at their seams: the lag flipped sign between two adjacent
        // frames and the bat jumped ~170° through the batter's body. Sampling the real derivative
        // of the arm angle makes the lag continuous by construction.
        val dt = 0.012
        val a0 = armPose(event, maxOf(0.0, t - dt)).frontArm
        val a1 = armPose(event, minOf(1.0, t + dt)).frontArm
        val velocity = (a1 - a0) / (2 * dt)

        // SATURATING, NOT LINEAR. A wrist has a physical limit — it cocks to some maximum and
        // stops, no matter how hard the arms are thrown. A raw `velocity * k` term does not: the
        // downswing's cubic reaches an enormous slope over a very short window, which produced a
        // 239° "lag" and a 168° jump between adjacent frames — the bat teleporting through the
        // batter's body. tanh bounds the lag to ±wristiness by construction, which is also what
        // a real wrist does at full cock.
        val cocked = kotlin.math.tanh(velocity / 260)

        // The lag OPPOSES the arm motion (the bat is being dragged). It ramps IN over the first
        // few frames and fades OUT as the shot finishes, so the bat starts from the stance at
        // rest and settles on the authored pose rather than beside it. Without the ramp the
        // backlift is already at full velocity on frame one and the bat visibly jerks 33° off the
        // stance the instant a ball begins.
        val onset = smoothstep(t / 0.08)
        val settle = 1 - smoothstep(maxOf(0.0, (t - 0.55) / 0.45))

        return p.copy(bat = p.bat - cocked * wristiness(event) * onset * settle)
    }

    /** The pose WITHOUT wrist lag — the arm-driven skeleton the lag is measured against. */
    private fun armPose(event: BallEvent, t: Double): BatterPose {
        val (backlift, contact, follow) = keyframes(event)
        val contactAt = minOf(0.55, 0.17 / maxOf(flightSeconds(event), 0.2))
        if (t <= 0) return STANCE

        if (t < contactAt) {
            // TWO PHASES WITH DIFFERENT CURVES, which is the whole difference between a bat and
            // a clock hand. The backlift is a LIFT — it eases out, the way a real player takes
            // the bat up and holds it at the top. The downswing is the opposite: it eases IN.
            val local = t / contactAt
            val lift = minOf(1.0, local / 0.45)
            if (local < 0.55) return lerp(STANCE, backlift, easeOut(lift))
            return lerp(backlift, contact, easeIn((local - 0.55) / 0.45))
        }

        // FOLLOW-THROUGH DECELERATES. Momentum carries the bat past the ball fast, then the
        // player's own body brakes it.
        val local = minOf(1.0, (t - contactAt) / maxOf(1 - contactAt, 0.01))
        return lerp(contact, follow, easeOutStrong(local))
    }

    private fun smoothstep(t: Double): Double {
        val k = t.coerceIn(0.0, 1.0)
        return k * k * (3 - 2 * k)
    }

    /**
     * How much wrist a shot has, in degrees of lag per unit arm speed.
     *
     * A six is thrown with everything; a block is played with the forearms and dead hands. This
     * is the single number that separates "whip" from "push", and it is derived from the shot,
     * not authored per keyframe.
     */
    private fun wristiness(event: BallEvent): Double = when (event) {
        is BallEvent.Runs -> when (event.runs) {
            6 -> 34.0; 5 -> 30.0; 4 -> 28.0; 3 -> 22.0; 2 -> 15.0; else -> 9.0
        }
        BallEvent.Dot -> 4.0
        BallEvent.Caught -> 20.0
        BallEvent.Bowled -> 32.0
    }

    /** How long this event's ball is in the air, in seconds — mirrors `flightMs` in the pitch. */
    private fun flightSeconds(event: BallEvent): Double = when (event) {
        is BallEvent.Runs -> when (event.runs) {
            6 -> 0.90; 5 -> 0.78; 4 -> 0.64; 3 -> 0.54; 2 -> 0.46; else -> 0.38
        }
        BallEvent.Dot -> 0.28
        BallEvent.Caught -> 0.52
        BallEvent.Bowled -> 0.40
    }

    /** Decelerating: fast off the mark, settling into the pose. Backlift and follow-through. */
    private fun easeOut(t: Double): Double {
        val k = t.coerceIn(0.0, 1.0)
        return 1.0 - Math.pow(1.0 - k, 3.0)
    }

    /** Accelerating: the downswing, where bat speed builds all the way into contact. */
    private fun easeIn(t: Double): Double {
        val k = t.coerceIn(0.0, 1.0)
        return k * k * k
    }

    /** The hardest deceleration of the three — the body braking a bat already moving. */
    private fun easeOutStrong(t: Double): Double {
        val k = t.coerceIn(0.0, 1.0)
        return 1.0 - Math.pow(1.0 - k, 4.0)
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
    val Jersey = Color(0.17f, 0.42f, 0.72f)
    val JerseyShadow = Color(0.08f, 0.22f, 0.43f)
    val Helmet = Color(0.12f, 0.16f, 0.22f)
    val Hair = Color(0.12f, 0.07f, 0.05f)
    val Shoe = Color(0.16f, 0.17f, 0.20f)
}
