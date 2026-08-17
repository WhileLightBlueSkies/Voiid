package com.voiid.app.main.games

import androidx.compose.ui.geometry.Offset
import kotlin.math.cos
import kotlin.math.sin

/**
 * Shapes for the arena's rocks, spikes and slicks
 * (docs/games/VISUALS_AUDIO_AND_PARITY.md §7).
 *
 * WHAT WAS WRONG. Every hazard was three stacked flat circles — a rock, a retracted spike and a
 * slick were the same shape in three colours, so "I don't know what those obstacles are" was the
 * expected outcome. The INTENT was already right and is preserved here: a rock is opaque because
 * it kills like the wall, a spike's state is the whole point, and a slick must never read as a
 * wall because a player who steers around one has paid for nothing.
 *
 * DETERMINISM IS A HARD REQUIREMENT, NOT A NICETY (§7.6). Every shape below is a pure function of
 * data both clients already have — the hazard's index and its (x, y) — computed through
 * [GameSurface.noise], which iOS implements identically. If a rock were a different shape on two
 * devices, two players in the same match would see different cover and different escape routes,
 * and Snake's entire netcode design rests on both clients agreeing about the world (SNAKE.md §2).
 * NEVER use `Random` in this file.
 *
 * Ported literally from iOS `SnakeHazardArt.swift`. Every constant below is a parity surface.
 */
object SnakeHazardArt {

    // ---- shared constants (the parity surface) ---------------------------------------------

    /** One light direction for the whole app, top-left, shared with `GameSurface.inset`. */
    const val LIGHT_X = -0.6
    const val LIGHT_Y = -0.8

    /**
     * FOUR ROCK SILHOUETTES, chosen by `index % 4`. A field of eight identical boulders reads as
     * UI; four shapes is enough that it reads as terrain, and four is cheap.
     */
    const val ROCK_VARIANTS = 4
    /**
     * A rock's outline has CORNERS. Nine of them — smooth enough to be a boulder, angular enough
     * never to be mistaken for the circle it used to be.
     */
    const val ROCK_SIDES = 9
    /** Oil does not have a radius, so a slick's boundary wanders. */
    const val SLICK_SIDES = 12
    /** Six teeth around a socket. */
    const val SPIKE_TEETH = 6

    /**
     * How long a spike takes to rise and to drop. The old renderer cut between the two states in
     * a single frame, which is what made a spike death read as bad luck rather than a mistake.
     */
    const val SPIKE_RISE = 0.18
    const val SPIKE_FALL = 0.14
    /**
     * The socket brightens over the last quarter-second before the teeth come up. The phase is
     * already known client-side (it is a pure function of simulation time), so this costs nothing
     * and converts a surprise into a mistake the player can own.
     */
    const val SPIKE_TELL = 0.25

    // ---- outlines ---------------------------------------------------------------------------

    /**
     * A rock's outline in unit space (radius 1), as a closed loop of points.
     *
     * Radius jitter in 0.78..1.18 and angular jitter of +/-0.12 rad. The two together are what
     * stop it reading as a polygon-approximated circle.
     */
    fun rockOutline(variant: Int): List<Offset> = (0 until ROCK_SIDES).map { i ->
        val base = i.toDouble() / ROCK_SIDES * 2 * Math.PI
        val angle = base + (GameSurface.noise(i, variant, 41) - 0.5) * 0.24
        val radius = 0.78 + GameSurface.noise(i, variant, 42) * 0.40
        Offset((cos(angle) * radius).toFloat(), (sin(angle) * radius).toFloat())
    }

    /**
     * A slick's boundary in unit space. Softer jitter than a rock and no corners worth the name —
     * it has to read as a puddle, never as an edge you could crash into.
     */
    fun slickOutline(variant: Int): List<Offset> = (0 until SLICK_SIDES).map { i ->
        val base = i.toDouble() / SLICK_SIDES * 2 * Math.PI
        val radius = 0.85 + GameSurface.noise(i, variant, 55) * 0.30
        Offset((cos(base) * radius).toFloat(), (sin(base) * radius).toFloat())
    }

    /**
     * One tooth of a spike, in unit space, at [extended] 0..1.
     *
     * Returns the triangle's three points: two at the socket rim, one at the tip. At extension 0
     * the tip sits flush with the rim, which is what makes a retracted spike show WHERE it is
     * without pretending to be dangerous.
     */
    fun spikeTooth(index: Int, extended: Double): Triple<Offset, Offset, Offset> {
        val step = 2 * Math.PI / SPIKE_TEETH
        val centre = index * step
        val halfBase = step * 0.34
        val rim = 0.45
        val tip = rim + (1.0 - rim) * extended.coerceIn(0.0, 1.0)
        return Triple(
            Offset((cos(centre - halfBase) * rim).toFloat(), (sin(centre - halfBase) * rim).toFloat()),
            Offset((cos(centre + halfBase) * rim).toFloat(), (sin(centre + halfBase) * rim).toFloat()),
            Offset((cos(centre) * tip).toFloat(), (sin(centre) * tip).toFloat()),
        )
    }

    // ---- facets -----------------------------------------------------------------------------

    /**
     * Which of three facets a point belongs to, from the light direction.
     *
     * HARD EDGES BETWEEN THEM, no gradient. Faceting is what makes a shape read as stone rather
     * than as a blob, and a smooth shade would put us back where we started.
     *
     * 0 = lit top face, 1 = side, 2 = shadow face.
     */
    fun facet(p: Offset): Int {
        val d = p.x * LIGHT_X + p.y * LIGHT_Y
        return when {
            d > 0.35 -> 0
            d > -0.30 -> 1
            else -> 2
        }
    }

    /** Lightness multiplier per facet: +22% on the lit face, base on the side, -30% in shadow. */
    fun facetShade(facet: Int): Float = when (facet) {
        0 -> 1.22f
        1 -> 1.0f
        else -> 0.70f
    }

    // ---- spike phase ------------------------------------------------------------------------

    /**
     * How far a spike is extended right now, 0..1, with the rise and fall eased rather than cut.
     *
     * Derived from the SAME `period`/`offset` the server sent and the same simulation clock the
     * engine uses, so it cannot desync — `spikeExtended` in hazards.ts remains the authority for
     * whether the spike KILLS; this only decides how far out it is drawn.
     */
    fun extended(period: Double, offset: Double, duty: Double, time: Double): Double {
        val p = maxOf(period, 0.001)
        val phase = (((time + offset) % p) + p) % p / p
        if (phase < duty) {
            // Rising, then held out for the rest of the duty window.
            return minOf(1.0, phase * p / SPIKE_RISE)
        }
        // Retracting, then held down.
        return maxOf(0.0, 1.0 - (phase - duty) * p / SPIKE_FALL)
    }

    /**
     * 0..1 over the last [SPIKE_TELL] seconds before the teeth rise. Drives the socket's warning
     * glow; 0 at every other moment.
     */
    fun tell(period: Double, offset: Double, duty: Double, time: Double): Double {
        val p = maxOf(period, 0.001)
        val phase = (((time + offset) % p) + p) % p / p
        if (phase < duty) return 0.0
        val untilNext = (1 - phase) * p
        if (untilNext >= SPIKE_TELL) return 0.0
        return 1 - untilNext / SPIKE_TELL
    }
}
