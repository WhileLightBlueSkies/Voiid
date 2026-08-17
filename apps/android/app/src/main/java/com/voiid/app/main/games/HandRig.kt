package com.voiid.app.main.games

import androidx.compose.ui.geometry.Offset
import kotlin.math.cos
import kotlin.math.sin

/**
 * A 2D skeletal hand for Rock Paper Scissors
 * (docs/games/VISUALS_AUDIO_AND_PARITY.md §3).
 *
 * WHAT THIS REPLACES: two emoji in a spotlit panel, rotated to fake a shake. The CHOREOGRAPHY was
 * already right — three beats at 110 ms with a rising fist-pump pitch — and it survives untouched.
 * The thing being choreographed was a glyph.
 *
 * A HAND IS A PALM PLUS FIVE FINGER CHAINS, and a pose is ONE CURL SCALAR PER FINGER. Every RPS
 * shape is a different vector of five numbers, so morphing between shapes is interpolating five
 * floats — which is what makes the transition read as fingers moving rather than as one picture
 * cross-fading into another. Four static hand images could not do that at any price.
 *
 * THIS FILE IS A LOOKUP TABLE, NOT DRAWING CODE, for the same reason `LudoBoard.kt` is: two rigs
 * that disagree by a few degrees is exactly the parity drift ANDROID_IOS_PARITY.md exists to
 * prevent, and a table is checkable where drawing code is not.
 *
 * Ported literally from iOS `HandRig.swift`. Every number below is a parity surface.
 */
object HandRig {

    // ---- skeleton ---------------------------------------------------------------------------

    /**
     * Bone lengths as fractions of total finger length. Anatomically real ratios — they matter
     * more than they sound, because a hand with even segments reads as a cartoon claw.
     */
    const val PROXIMAL = 0.42f
    const val MIDDLE = 0.32f
    const val DISTAL = 0.26f

    /**
     * Maximum flexion per joint, in degrees, at `curl = 1`. The actual angle is
     * `curl * maxFlexion`, so ONE scalar drives a whole finger and a half-curl looks like a
     * half-curl rather than a straight finger at an angle.
     */
    const val MCP_MAX = 88.0     // knuckle
    const val PIP_MAX = 100.0
    const val DIP_MAX = 70.0

    /**
     * Finger lengths relative to palm width (1.0), and the rest angles they fan out at from the
     * knuckle line. Index 0 = index finger ... 3 = pinky.
     */
    val FINGER_LENGTH = listOf(1.00f, 1.08f, 0.98f, 0.80f)
    val REST_SPLAY = listOf(-13.0, -2.0, 9.0, 21.0)

    /** Where each knuckle sits along the top of the palm, in palm-width units from its centre. */
    val KNUCKLE_X = listOf(-0.30f, -0.06f, 0.17f, 0.38f)

    // ---- poses ------------------------------------------------------------------------------

    /**
     * A hand pose: four finger curls plus the thumb's own two degrees of freedom.
     *
     * THE THUMB IS NOT A FIFTH FINGER and must not be treated as one. It rotates ACROSS the palm
     * rather than curling in plane, which is why it gets [thumbAdduction] — the swing from out
     * (paper) to folded over the fingers (rock) — on top of its own curl.
     */
    data class Pose(
        /** index, middle, ring, pinky. 0 = straight, 1 = fully curled. */
        val curls: List<Double>,
        val thumbCurl: Double,
        /** Degrees. Negative swings the thumb away from the palm, positive across it. */
        val thumbAdduction: Double,
        /** Scales [REST_SPLAY]. 1 fans paper's fingers wide, 0 packs rock's together. */
        val splay: Double,
    )

    fun lerp(a: Pose, b: Pose, t: Double): Pose {
        val k = t.coerceIn(0.0, 1.0)
        return Pose(
            curls = a.curls.zip(b.curls) { x, y -> x + (y - x) * k },
            thumbCurl = a.thumbCurl + (b.thumbCurl - a.thumbCurl) * k,
            thumbAdduction = a.thumbAdduction + (b.thumbAdduction - a.thumbAdduction) * k,
            splay = a.splay + (b.splay - a.splay) * k,
        )
    }

    /**
     * Between rounds, and throughout the three pumps. A relaxed hand, not a fist — the fist forms
     * on the way down into the reveal, which is what makes the reveal an event.
     */
    val NEUTRAL = Pose(listOf(0.34, 0.30, 0.32, 0.38), 0.28, -6.0, 0.30)

    val ROCK = Pose(listOf(1.00, 1.00, 1.00, 1.00), 0.55, 34.0, 0.00)

    val PAPER = Pose(listOf(0.00, 0.00, 0.00, 0.00), 0.05, -38.0, 1.00)

    /**
     * Index and middle out, ring and pinky curled, thumb folded across them. The 0.55 splay is
     * what gives the V its opening — at 0 the two extended fingers touch and it reads as a
     * two-finger point rather than as scissors.
     */
    val SCISSORS = Pose(listOf(0.00, 0.00, 1.00, 1.00), 0.70, 22.0, 0.55)

    /** Wire index -> pose. 0 rock, 1 paper, 2 scissors, matching [RpsBot]'s ordering. */
    fun pose(index: Int?): Pose = when (index) {
        RpsBot.ROCK -> ROCK
        RpsBot.PAPER -> PAPER
        RpsBot.SCISSORS -> SCISSORS
        else -> NEUTRAL
    }

    // ---- choreography (§3.5) ----------------------------------------------------------------

    /**
     * The three fist-pump beats. Unchanged from the emoji version — already tuned, and the sound
     * files are already generated against this cadence.
     */
    const val PUMP_BEAT_MS = 110L
    const val PUMP_COUNT = 3

    /** Forearm rotation at the top and bottom of a pump, in degrees. */
    const val PUMP_UP = -24f
    const val PUMP_DOWN = 9f

    /**
     * THE HAND LAGS THE FOREARM. One extra interpolation with a delayed target, and it is the
     * single detail that makes this look human rather than mechanical: a real hand is dragged by
     * the wrist, it does not rotate in lockstep with it.
     */
    const val WRIST_FOLLOW = 0.72f

    /** Neutral -> thrown, on the third downstroke. */
    const val REVEAL_MS = 130

    /** Rock's knuckles pop on reveal. Overshoot is what stops it reading as a cut. */
    const val ROCK_KNUCKLE_POP = 1.04f

    // ---- joint solve ------------------------------------------------------------------------

    /**
     * The joint positions of one finger, in palm-width units from its knuckle.
     *
     * Walks the chain accumulating rotation, which is what makes a curl BEND rather than shrink.
     * [direction] is -1 for a mirrored (right-hand) draw.
     */
    fun fingerJoints(finger: Int, curl: Double, splay: Double, direction: Float = 1f): List<Offset> {
        val length = FINGER_LENGTH[finger.coerceAtMost(FINGER_LENGTH.size - 1)]
        val splayAngle = REST_SPLAY[finger.coerceAtMost(REST_SPLAY.size - 1)] * splay

        // Fingers point UP the screen at rest, so the base angle is -90 degrees.
        var angle = Math.toRadians(-90.0 + splayAngle)
        var x = KNUCKLE_X[finger.coerceAtMost(KNUCKLE_X.size - 1)] * direction
        var y = 0f
        val joints = mutableListOf(Offset(x, y))

        val maxes = listOf(MCP_MAX, PIP_MAX, DIP_MAX)
        listOf(PROXIMAL, MIDDLE, DISTAL).forEachIndexed { index, fraction ->
            angle += Math.toRadians(maxes[index] * curl) * direction
            val segment = length * fraction
            x += (cos(angle) * segment).toFloat() * direction
            y += (sin(angle) * segment).toFloat()
            joints.add(Offset(x, y))
        }
        return joints
    }

    /** The thumb: two bones, swinging across the palm rather than curling in plane. */
    fun thumbJoints(curl: Double, adduction: Double, direction: Float = 1f): List<Offset> {
        var angle = Math.toRadians(-152.0 + adduction)
        var x = -0.46f * direction
        var y = 0.30f
        val joints = mutableListOf(Offset(x, y))
        listOf(0.40f, 0.30f).forEachIndexed { index, segment ->
            angle += Math.toRadians((if (index == 0) 52.0 else 44.0) * curl) * direction
            x += (cos(angle) * segment).toFloat() * direction
            y += (sin(angle) * segment).toFloat()
            joints.add(Offset(x, y))
        }
        return joints
    }

    /**
     * Stroke width along a finger: thicker at the knuckle, tapering to the tip. Three widths beat
     * one, because the taper is most of what makes it read as a finger.
     */
    fun segmentWidth(index: Int): Float = listOf(0.30f, 0.26f, 0.21f)[index.coerceAtMost(2)]
}
