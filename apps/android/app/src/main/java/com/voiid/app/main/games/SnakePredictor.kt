package com.voiid.app.main.games

import androidx.compose.ui.geometry.Offset
import kotlin.math.PI
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin

/**
 * Movement constants, mirrored from the server's TUNING
 * (backend/games/src/engine/snake/index.ts).
 *
 * Duplicated deliberately rather than sent over the wire: they change rarely, and threading
 * them through every frame would cost bandwidth to tell the client something it can hold as a
 * constant. The cost is that a tuning change must be made in both places.
 */
object SnakeMotion {
    const val BASE_SPEED = 300.0
    const val BOOST_SPEED = 510.0
    val TURN_RATE = 500.0 * PI / 180.0
    val TURN_RATE_BOOST = 540.0 * PI / 180.0
    /** Speed multiplier inside a slick. Mirrors HAZARD_TUNING.SLICK_SPEED on the server. */
    const val SLICK_SPEED = 0.62

    /**
     * Below this mass the engine IGNORES a boost input entirely (snake/index.ts
     * MIN_BOOST_MASS). Mirrored here so the HUD's fuel ring can say so — a button that does
     * nothing when pressed reads as broken unless the UI explains why. Identical to iOS
     * `SnakeMotion.minBoostMass`.
     */
    const val MIN_BOOST_MASS = 12.0
}

/**
 * Client-side prediction for the LOCAL player's snake only.
 *
 * WHY THIS EXISTS. Every other snake is interpolated ~150 ms in the past, which is correct:
 * we cannot know where someone else is going. But applying that to your OWN snake means your
 * thumb moves and the head answers a fifth of a second later, and no amount of smoothing
 * fixes a control that lags — it just makes a laggy control smooth.
 *
 * So the local head is simulated here, immediately, using the same movement maths the server
 * runs (constant forward speed, heading clamped to a turn rate). When the authoritative
 * position arrives it is blended in rather than snapped to, so a correction reads as a small
 * drift instead of a teleport.
 *
 * THIS IS NOT AUTHORITY. The server still decides collisions, growth, death and everything
 * else; prediction only answers "where would my head be by now?" between frames. If the
 * server disagrees, the server wins — the blend just makes losing gracefully invisible.
 *
 * Mirrors iOS `SnakePredictor.swift`.
 */
class SnakePredictor {
    /**
     * Server time this snake stays slowed by a slick until, and the server clock it is compared
     * against. Both are pushed in by the renderer each frame from the newest frame — the
     * predictor has no clock of its own, and comparing a server deadline against a local
     * timestamp would be meaningless.
     */
    private var slickUntil = 0.0
    private var serverTime = 0.0

    /** Called each frame with the newest server frame's clock and this snake's slick deadline. */
    fun setSlick(until: Double, now: Double) {
        slickUntil = until
        serverTime = now
    }

    var position = Offset.Zero
        private set
    var heading = 0.0
        private set

    /** What the player is currently asking for. Written by the joystick, read every frame. */
    @Volatile var desiredHeading: Double? = null
    @Volatile var boosting = false

    private var started = false
    private var lastStepNanos = 0L

    private var correction = Offset.Zero
    private var correctionRemaining = 0.0

    /** Discard everything. A stale prediction surviving a respawn would draw the snake at
     *  its previous corpse. */
    fun reset(pos: Offset, h: Double) {
        position = pos
        heading = h
        correction = Offset.Zero
        correctionRemaining = 0.0
        started = true
        lastStepNanos = System.nanoTime()
    }

    /**
     * Fold in the server's authoritative position.
     *
     * The delta between where we thought we were and where the server says we are becomes a
     * correction that decays over [CORRECTION_TIME] rather than being applied at once.
     */
    fun reconcile(serverPos: Offset, serverHeading: Double, alive: Boolean) {
        if (!alive) { started = false; return }
        if (!started) { reset(serverPos, serverHeading); return }

        val dx = serverPos.x - position.x
        val dy = serverPos.y - position.y

        // Too far to be a prediction error — a death, a respawn, a teleport. Easing toward it
        // would draw a long wrong line across the arena.
        if (hypot(dx, dy) > HARD_SNAP_DISTANCE) {
            reset(serverPos, serverHeading)
            return
        }

        correction = Offset(dx, dy)
        correctionRemaining = CORRECTION_TIME

        // The server's heading is authoritative too, but it is a fifth of a second old — so
        // it is folded in gently rather than assigned, or every frame would yank the head
        // back toward where the player was aiming two frames ago.
        var delta = serverHeading - heading
        while (delta > PI) delta -= 2 * PI
        while (delta < -PI) delta += 2 * PI
        heading += delta * 0.2
    }

    /** Advance one render frame. Returns the position to draw the local head at, or null. */
    fun step(): Offset? {
        if (!started) return null

        val now = System.nanoTime()
        // Clamp: a stall must not teleport the snake across the arena on resume.
        val dt = min((now - lastStepNanos) / 1_000_000_000.0, 0.05)
        lastStepNanos = now
        if (dt <= 0) return position

        // Turn toward the desired heading at the legal rate — the same clamp the server
        // applies, which is what keeps the two simulations agreeing.
        desiredHeading?.let { want ->
            val rate = if (boosting) SnakeMotion.TURN_RATE_BOOST else SnakeMotion.TURN_RATE
            var delta = want - heading
            while (delta > PI) delta -= 2 * PI
            while (delta < -PI) delta += 2 * PI
            heading += max(-rate * dt, min(rate * dt, delta))
        }

        // SLICKS SLOW THE PREDICTION TOO. The server multiplies speed by SLICK_SPEED while a
        // snake is in one; if the predictor did not, the local head would run ahead at full
        // speed and be dragged back every frame for as long as the player stayed in the slick —
        // a rubber-band exactly where the game is asking them to steer carefully.
        var speed = if (boosting) SnakeMotion.BOOST_SPEED else SnakeMotion.BASE_SPEED
        if (serverTime < slickUntil) speed *= SnakeMotion.SLICK_SPEED
        position = Offset(
            position.x + (cos(heading) * speed * dt).toFloat(),
            position.y + (sin(heading) * speed * dt).toFloat(),
        )

        // Absorb any outstanding correction a slice at a time.
        if (correctionRemaining > 0) {
            val slice = min(dt / correctionRemaining, 1.0).toFloat()
            position = Offset(
                position.x + correction.x * slice,
                position.y + correction.y * slice,
            )
            correction = Offset(correction.x * (1 - slice), correction.y * (1 - slice))
            correctionRemaining -= dt
        }

        return position
    }

    private companion object {
        /**
         * How wrong the prediction may be before we stop blending and accept the server. A
         * bigger correction means something prediction cannot model happened.
         */
        const val HARD_SNAP_DISTANCE = 260f

        /**
         * Seconds to fold a correction in over. Long enough to be invisible, short enough
         * that the prediction cannot stay meaningfully wrong.
         */
        const val CORRECTION_TIME = 0.15
    }
}
