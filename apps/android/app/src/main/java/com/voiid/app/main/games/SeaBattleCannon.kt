package com.voiid.app.main.games

import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.geometry.Size
import androidx.compose.ui.graphics.Brush
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.rotate
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.hypot
import kotlin.math.pow
import kotlin.math.sin

/**
 * The launcher, the rocket and the blast (docs/games/VISUALS_AUDIO_AND_PARITY.md §6.4).
 *
 * WHY THIS IS A FILE AND NOT MORE OF `SeaBattleBoard.kt`.
 *
 * The board renderer's job is to answer "what does square 47 show" a hundred times. The ordnance
 * is the opposite shape of problem: one object, continuous position, four phases, and none of it
 * is per-cell. Mixed into the cell loop it was 90 lines of trigonometry inside a `for` over 100
 * squares, and every change to a fireball risked the grid.
 *
 * THE FOUR PHASES, and which of them is in the latency budget:
 *
 *   | Phase     | Budget | What it is                                                      |
 *   |-----------|--------|-----------------------------------------------------------------|
 *   | Charge    | 140 ms | Launcher swings onto the bearing and pulls back. Starts on the   |
 *   |           |        | FIRE tap, so it overlaps the round trip and costs nothing.       |
 *   | Flight    | 380 ms | The rocket. This IS the round-trip window (§3.3).                |
 *   | Impact    | 140 ms | Fireball, shockwave, debris. AFTER the reveal, so free.          |
 *   | Aftermath | 380 ms | Smoke drifts off and the marker settles into its final form.     |
 *
 * Only the flight is in the budget. Charge overlaps the network and impact runs after the result
 * is already on screen, so the total added latency of all of this is zero — which is the entire
 * reason it is safe to make a turn-based game this loud.
 *
 * A ROCKET, NOT A TUMBLING BOMB. A bomb is a passive object and its read is "it fell"; a rocket
 * is an object under power and its read is "it was sent". The difference is entirely in two
 * details: the rocket is ORIENTED ALONG ITS OWN VELOCITY (so it noses over at the top of the arc
 * rather than spinning), and it leaves an EXHAUST TRAIL, which is what makes the arc legible as a
 * path instead of a position.
 *
 * Ported from iOS `SeaBattleCannon.swift`. Every constant here is a parity surface.
 */
object SeaBattleCannon {

    // ---- phase durations --------------------------------------------------------------------
    //
    // Read by [SeaBattleMotion], which owns the clocks; this file owns only the drawing. Keeping
    // the numbers here means the drawing and the timing cannot drift apart.

    const val CHARGE_MS = 140L
    const val FLIGHT_MS = 380L

    /**
     * Impact plus aftermath. The blast is one clock: the fireball owns the first quarter of it
     * and the smoke owns the rest, which is cheaper than two overlapping timers.
     */
    const val BLAST_MS = 520L

    /** A sunk ship gets a longer blast with a second detonation in it (§6.3). */
    const val SUNK_BLAST_MS = 720L

    // ---- geometry ---------------------------------------------------------------------------
    //
    // Shared by the drawing below AND by anything that needs to know where the rocket is — there
    // must be exactly one answer to "where is it at t", or the shadow drifts off the body.

    /**
     * The launcher sits at the near edge of the board being fired at, centred.
     *
     * JUST INSIDE THE BOARD, not below it. The grid draws into a square canvas that clips at its
     * own edge, so a muzzle at `board + 0.35` put the whole base plate outside the clip and left a
     * tube stub apparently growing out of nothing. Sitting it 0.16 of a cell inside the bottom rim
     * costs a sliver of the two centre squares of row 10 and is the layout the reference art has
     * anyway.
     */
    fun muzzle(board: Float, cellSize: Float): Offset = Offset(board / 2f, board - cellSize * 0.16f)

    /**
     * Arc height scales with distance, clamped so a near shot still lobs and a far one does not
     * leave the board.
     */
    fun arcHeight(muzzle: Offset, target: Offset, cellSize: Float): Float {
        val distanceCells = hypot(target.x - muzzle.x, target.y - muzzle.y) / cellSize
        return (distanceCells * 0.28f).coerceIn(0.9f, 3.2f) * cellSize
    }

    /**
     * Where the rocket is at [t]. A straight ground track plus a parabola that is zero at both
     * ends — so the rocket leaves the muzzle and arrives at the cell exactly, whatever the arc.
     */
    fun position(muzzle: Offset, target: Offset, arc: Float, t: Float): Offset {
        val ground = groundTrack(muzzle, target, t)
        return Offset(ground.x, ground.y - arc * 4f * t * (1f - t))
    }

    /**
     * The point on the sea directly under the rocket. The shadow walks this, which is what makes
     * the arc read as height rather than as sideways drift.
     */
    fun groundTrack(muzzle: Offset, target: Offset, t: Float): Offset = Offset(
        muzzle.x + (target.x - muzzle.x) * t,
        muzzle.y + (target.y - muzzle.y) * t,
    )

    /**
     * Which way the rocket is pointing: the tangent of the flight path, not the muzzle-to-target
     * bearing. THIS is the detail that separates a rocket from a thrown object — it climbs
     * nose-up, levels at apex, and noses over into the target.
     */
    fun heading(muzzle: Offset, target: Offset, arc: Float, t: Float): Float {
        val dx = target.x - muzzle.x
        val dy = (target.y - muzzle.y) - arc * 4f * (1f - 2f * t)
        return atan2(dy, dx)
    }

    // ---- the launcher -----------------------------------------------------------------------

    /**
     * The launcher at the near edge: a base, and a tube on it that swings onto the bearing during
     * the charge and recoils when the rocket leaves.
     *
     * [charge] is 0..1 through the swing, [flight] is 0..1 through the rocket's travel (or 0 when
     * nothing is in the air). Drawn even at rest so the player can see what fires — a launcher
     * that materialises only during a shot reads as a glitch.
     */
    fun DrawScope.drawLauncher(
        board: Float,
        cellSize: Float,
        target: Offset?,
        charge: Float,
        flight: Float,
        team: SeaBattleTeam,
        ink: Color,
    ) {
        val p = team.palette
        val m = muzzle(board, cellSize)

        // At rest the tube points straight up the board. [charge] eases it onto the bearing, and
        // it STAYS there for the whole flight — a tube that snaps back while its own rocket is
        // still in the air is the single most common way this kind of animation reads as fake.
        val rest = (-PI / 2).toFloat()
        val aim = target?.let { atan2(it.y - m.y, it.x - m.x) } ?: rest
        val swing = if (charge <= 0f && flight <= 0f) 0f else maxOf(charge, if (flight > 0f) 1f else 0f)
        val angle = rest + (aim - rest) * ease(swing)

        // Recoil: pulled back through the charge, snapped out on launch, settling over the first
        // third of the flight.
        val pullback = cellSize * 0.10f * ease(charge)
        val kick = if (flight > 0f) cellSize * 0.22f * (1f - flight / 0.30f).coerceAtLeast(0f) else 0f
        val recoil = pullback + kick

        // THE TUBE STOWS WHEN NOTHING IS HAPPENING. At rest it is a stub barely taller than its
        // own base; committing to a shot runs it out to full length. That is what keeps a
        // permanent fixture from covering the two squares it sits on for the whole match — a
        // launcher you cannot fire past would be a worse problem than no launcher at all.
        val len = cellSize * (0.40f + 0.58f * ease(swing))
        val halfBeam = cellSize * 0.135f

        rotate(degrees = angle * 180f / PI.toFloat(), pivot = m) {
            val left = m.x - cellSize * 0.20f - recoil
            val top = m.y - halfBeam
            drawRoundRect(
                brush = Brush.verticalGradient(
                    listOf(p.deck, p.body), startY = top, endY = top + halfBeam * 2),
                topLeft = Offset(left, top),
                size = Size(len, halfBeam * 2),
                cornerRadius = CornerRadius(halfBeam * 0.5f),
            )
            drawRoundRect(
                color = p.ink.copy(alpha = 0.85f),
                topLeft = Offset(left, top),
                size = Size(len, halfBeam * 2),
                cornerRadius = CornerRadius(halfBeam * 0.5f),
                style = Stroke(width = 1f),
            )
            // The muzzle ring, so the tube has a front.
            drawOval(
                color = p.stripe.copy(alpha = 0.9f),
                topLeft = Offset(left + len - cellSize * 0.06f, m.y - halfBeam * 0.85f),
                size = Size(halfBeam * 0.7f, halfBeam * 1.7f),
                style = Stroke(width = 1.2f),
            )

            // MUZZLE FLASH — only in the first 60 ms of the flight, and drawn in the tube's frame
            // so it sits on the muzzle whichever way the tube is aimed.
            if (flight > 0f && flight < 0.16f) {
                val f = 1f - flight / 0.16f
                val r = cellSize * 0.34f * f
                val nose = Offset(left + len, m.y)
                drawCircle(
                    brush = Brush.radialGradient(
                        listOf(
                            Color.White.copy(alpha = 0.95f * f),
                            Color(1.0f, 0.82f, 0.35f).copy(alpha = 0.85f * f),
                            Color(0.95f, 0.42f, 0.10f).copy(alpha = 0f),
                        ),
                        center = nose,
                        radius = r,
                    ),
                    radius = r,
                    center = nose,
                )
            }
        }

        // The base plate, in the BOARD's frame — it does not rotate with the tube.
        val baseW = cellSize * 0.80f
        val baseH = cellSize * 0.30f
        val baseTop = m.y - baseH * 0.5f
        drawRoundRect(
            brush = Brush.verticalGradient(
                listOf(p.lit, p.body), startY = baseTop, endY = baseTop + baseH),
            topLeft = Offset(m.x - baseW / 2f, baseTop),
            size = Size(baseW, baseH),
            cornerRadius = CornerRadius(baseH * 0.42f),
        )
        drawRoundRect(
            color = ink.copy(alpha = 0.5f),
            topLeft = Offset(m.x - baseW / 2f, baseTop),
            size = Size(baseW, baseH),
            cornerRadius = CornerRadius(baseH * 0.42f),
            style = Stroke(width = 1f),
        )
    }

    // ---- the rocket -------------------------------------------------------------------------

    /**
     * The rocket in flight, its exhaust trail and its shadow.
     *
     * THREE DETAILS SELL IT, and none is optional (§6.4):
     *  * it SCALES along the flight (1.0 -> 1.55 -> 0.85), which is perspective in a top-down
     *    view and the difference between "launched" and "slid";
     *  * a SHADOW tracks the straight muzzle->target line at sea level while the rocket arcs above
     *    it — without it the arc reads as sideways drift;
     *  * it is ORIENTED ALONG ITS VELOCITY and leaves a fading EXHAUST TRAIL, which is what makes
     *    the arc read as a path rather than as a position.
     */
    fun DrawScope.drawRocket(
        cellSize: Float,
        muzzle: Offset,
        target: Offset,
        t: Float,
        team: SeaBattleTeam,
        ink: Color,
    ) {
        val p = team.palette
        val arc = arcHeight(muzzle, target, cellSize)
        val ground = groundTrack(muzzle, target, t)
        val pos = position(muzzle, target, arc, t)
        val angle = heading(muzzle, target, arc, t)
        val bodyScale = 1f + 0.55f * sin(t * PI).toFloat() - 0.15f * t

        // SMOKE TRAIL, oldest first so newer puffs overlap older ones. Sampled backwards along
        // the same parabola the rocket is on, so the trail is the flight path by construction and
        // cannot drift away from it.
        for (k in 1..7) {
            val tk = t - k * 0.055f
            if (tk <= 0.01f) continue
            val q = position(muzzle, target, arc, tk)
            val r = cellSize * (0.070f + 0.034f * k)
            // Fades with age AND with the whole flight, so nothing is left hanging at impact.
            val a = 0.42f * (1f - k / 8f) * minOf(1f, t * 5f) * (1f - t * 0.55f)
            drawCircle(color = Color(0.78f, 0.78f, 0.80f, a), radius = r, center = q)
        }

        // Shadow on the sea, shrinking as the rocket climbs away from it.
        val shadowR = cellSize * 0.15f * (1f - 0.35f * sin(t * PI).toFloat())
        drawOval(
            color = ink.copy(alpha = 0.26f),
            topLeft = Offset(ground.x - shadowR, ground.y - shadowR * 0.5f),
            size = Size(shadowR * 2f, shadowR),
        )

        val len = cellSize * 0.62f * bodyScale
        val r = cellSize * 0.105f * bodyScale

        rotate(degrees = angle * 180f / PI.toFloat(), pivot = pos) {
            val cx = pos.x
            val cy = pos.y

            // EXHAUST, behind the tail. Flickers on a fast sine so the flame is alive over a
            // 380 ms flight — a static cone reads as a paper cutout.
            val flick = 0.72f + 0.28f * sin(t * 46f)
            val flameLen = len * 0.85f * flick
            val flameBase = cx - len * 0.44f
            val flame = Path().apply {
                moveTo(flameBase, cy - r * 0.85f)
                quadraticTo(cx - len * 0.60f, cy - r * 0.55f, flameBase - flameLen, cy)
                quadraticTo(cx - len * 0.60f, cy + r * 0.55f, flameBase, cy + r * 0.85f)
                close()
            }
            drawPath(
                flame,
                Brush.horizontalGradient(
                    listOf(
                        Color(0.94f, 0.34f, 0.08f, 0f),
                        Color(1.0f, 0.78f, 0.26f, 0.85f),
                        Color.White.copy(alpha = 0.95f),
                    ),
                    startX = flameBase - flameLen,
                    endX = flameBase,
                ),
            )

            // FUSELAGE: a body that stops short of the nose, then a cone. One path so the outline
            // runs round the whole silhouette rather than showing a seam at the shoulder.
            val hull = Path().apply {
                moveTo(cx - len * 0.44f, cy - r)
                lineTo(cx + len * 0.12f, cy - r)
                quadraticTo(cx + len * 0.40f, cy - r * 0.72f, cx + len * 0.50f, cy)
                quadraticTo(cx + len * 0.40f, cy + r * 0.72f, cx + len * 0.12f, cy + r)
                lineTo(cx - len * 0.44f, cy + r)
                close()
            }

            // FINS at the tail, one up one down. Two is enough in a top-down view and a third
            // only muddies the silhouette at this size.
            val fins = Path().apply {
                moveTo(cx - len * 0.26f, cy - r)
                lineTo(cx - len * 0.48f, cy - r * 2.15f)
                lineTo(cx - len * 0.48f, cy - r * 0.9f)
                close()
                moveTo(cx - len * 0.26f, cy + r)
                lineTo(cx - len * 0.48f, cy + r * 2.15f)
                lineTo(cx - len * 0.48f, cy + r * 0.9f)
                close()
            }
            drawPath(fins, p.body)
            drawPath(fins, p.ink.copy(alpha = 0.8f), style = Stroke(width = 0.8f))

            drawPath(
                hull,
                Brush.verticalGradient(
                    listOf(Color(0.90f, 0.91f, 0.93f), p.body),
                    startY = cy - r, endY = cy + r,
                ),
            )
            drawPath(hull, p.ink.copy(alpha = 0.9f), style = Stroke(width = 0.9f))

            // The team band and the warhead tip: the rocket is the firing team's colour, which is
            // how a spectator knows whose shot is in the air.
            drawRoundRect(
                color = p.stripe,
                topLeft = Offset(cx - len * 0.06f, cy - r),
                size = Size(len * 0.14f, r * 2f),
                cornerRadius = CornerRadius(r * 0.3f),
            )
            drawCircle(
                color = p.stripe.copy(alpha = 0.9f),
                radius = r * 0.42f,
                center = Offset(cx + len * 0.28f + r * 0.42f, cy),
            )
        }
    }

    // ---- the blast --------------------------------------------------------------------------

    /**
     * The impact. [kind] is the server's own `lastResult` — 0 miss, 1 hit, 2 hit-and-sunk — so the
     * explosion can never disagree with the board about what happened.
     *
     * [t] runs 0..1 over [BLAST_MS]. The fireball owns roughly the first quarter and the smoke
     * owns the rest, on one clock: two overlapping timers is two things to cancel when a screen
     * goes away mid-shot.
     *
     * [seed] is the cell index, so every speck of debris is deterministic per square — a
     * re-render mid-blast must not reshuffle the shrapnel.
     */
    fun DrawScope.drawBlast(
        centre: Offset,
        cellSize: Float,
        t: Float,
        kind: Int,
        seed: Int,
        ink: Color,
    ) {
        if (t <= 0f || t >= 1f) return
        if (kind == 0) {
            splash(centre, cellSize, t, seed, ink)
            return
        }
        detonation(centre, cellSize, t, seed, ink, 1f)
        // A SUNK SHIP GETS A SECOND DETONATION, a third of the way through and offset off the
        // impact point — a magazine going up. It is the only thing on this board that ever
        // happens twice, which is what makes a sink feel different from a hit rather than just
        // louder.
        if (kind == 2 && t > 0.34f) {
            val t2 = (t - 0.34f) / 0.66f
            val dx = (GameSurface.noise(seed, 71, 31) - 0.5).toFloat() * cellSize * 0.7f
            val dy = (GameSurface.noise(seed, 72, 32) - 0.5).toFloat() * cellSize * 0.7f
            detonation(Offset(centre.x + dx, centre.y + dy), cellSize, t2, seed + 977, ink, 0.8f)
        }
    }

    /** A HIT: white core, fireball, shockwave, debris, smoke. */
    private fun DrawScope.detonation(
        c: Offset,
        cellSize: Float,
        t: Float,
        seed: Int,
        ink: Color,
        scale: Float,
    ) {
        // FLASH — the first 70 ms only. It is what gives the blast an onset; without it the
        // fireball reads as growing rather than as detonating.
        if (t < 0.14f) {
            val f = 1f - t / 0.14f
            val r = cellSize * scale * (0.30f + 1.10f * (t / 0.14f))
            drawCircle(color = Color.White.copy(alpha = 0.85f * f), radius = r, center = c)
        }

        // FIREBALL — expands hard then holds and fades. The 0.42 exponent is the deceleration:
        // an explosion is fastest at the instant it starts.
        val grow = minOf(t / 0.34f, 1f).pow(0.42f)
        val fr = cellSize * scale * (0.18f + 0.72f * grow)
        val fade = if (t < 0.34f) 1f else (1f - (t - 0.34f) / 0.30f).coerceAtLeast(0f)
        if (fade > 0f) {
            drawCircle(
                brush = Brush.radialGradient(
                    listOf(
                        Color.White.copy(alpha = 0.95f * fade),
                        Color(1.00f, 0.83f, 0.30f).copy(alpha = 0.95f * fade),
                        Color(0.93f, 0.38f, 0.09f).copy(alpha = 0.85f * fade),
                        Color(0.42f, 0.09f, 0.05f).copy(alpha = 0f),
                    ),
                    center = c,
                    radius = fr,
                ),
                radius = fr,
                center = c,
            )
        }

        // SHOCKWAVE — a thin ring that outruns the fireball and thins as it goes. This is the part
        // that makes the blast feel like it has force rather than volume.
        val sw = cellSize * scale * (0.22f + 2.10f * t.pow(0.55f))
        val swAlpha = (1f - t / 0.62f).coerceAtLeast(0f)
        if (swAlpha > 0f) {
            drawCircle(
                color = Color.White.copy(alpha = 0.55f * swAlpha * swAlpha),
                radius = sw,
                center = c,
                style = Stroke(width = (2.4f * swAlpha).coerceAtLeast(0.4f)),
            )
        }

        // DEBRIS — six specks thrown clear and pulled down. §6.4 asks for six; they are seeded per
        // cell so a re-render mid-blast cannot reshuffle them.
        for (k in 0 until 6) {
            val a = (GameSurface.noise(seed, k, 41) * 6.28318).toFloat()
            val speed = 1.5f + GameSurface.noise(seed, k, 42).toFloat() * 1.5f
            val d = cellSize * scale * speed * t * (1.15f - 0.35f * t)
            // Gravity, so shrapnel falls back rather than flying off in a straight line.
            val drop = cellSize * scale * 1.5f * t * t
            val px = c.x + cos(a) * d
            val py = c.y + sin(a) * d * 0.75f + drop
            val sz = cellSize * scale * 0.075f * (1f - t * 0.6f)
            val alpha = (1f - t / 0.85f).coerceAtLeast(0f)
            drawCircle(color = ink.copy(alpha = 0.65f * alpha), radius = sz, center = Offset(px, py))
        }

        // SMOKE — the aftermath, drifting up and dissipating (§6.4). Starts only once the fireball
        // is past its peak, so the two never fight for the same pixels.
        if (t <= 0.26f) return
        val st = (t - 0.26f) / 0.74f
        for (k in 0 until 4) {
            val q = st - k * 0.16f
            if (q <= 0f) continue
            val dx = (GameSurface.noise(seed, k, 43) - 0.5).toFloat() * cellSize * 0.9f * q
            val rise = cellSize * scale * 0.9f * q
            val r = cellSize * scale * (0.18f + 0.42f * q)
            drawCircle(
                color = Color(0.34f, 0.34f, 0.36f, 0.36f * (1f - q) * (1f - q)),
                radius = r,
                center = Offset(c.x + dx, c.y - rise),
            )
        }
    }

    /**
     * A MISS: a water column, not a small explosion.
     *
     * §8.4 requires hit and miss to differ in SHAPE before they differ in colour, and that rule
     * has to survive into the animation or the board stops working in greyscale for the one second
     * per turn when something is actually happening. A splash is hollow rings and a falling
     * column; a hit is a filled expanding disc. They are opposite shapes on purpose.
     */
    private fun DrawScope.splash(
        c: Offset,
        cellSize: Float,
        t: Float,
        seed: Int,
        ink: Color,
    ) {
        // The column: up fast, back down under gravity, gone by 60% of the clock.
        if (t < 0.62f) {
            val ct = t / 0.62f
            val h = cellSize * 1.15f * (sin(ct * PI).toFloat() * 0.9f + ct * 0.1f)
            val w = cellSize * (0.30f - 0.10f * ct)
            val column = Path().apply {
                moveTo(c.x - w, c.y)
                quadraticTo(c.x - w * 0.8f, c.y - h * 0.55f, c.x, c.y - h)
                quadraticTo(c.x + w * 0.8f, c.y - h * 0.55f, c.x + w, c.y)
                close()
            }
            drawPath(
                column,
                Brush.verticalGradient(
                    listOf(
                        Color.White.copy(alpha = 0f),
                        Color.White.copy(alpha = 0.55f * (1f - ct)),
                        Color(0.86f, 0.93f, 0.96f).copy(alpha = 0.75f * (1f - ct)),
                    ),
                    startY = c.y - h,
                    endY = c.y,
                ),
            )
        }

        // Droplets thrown off the top of the column and falling back.
        for (k in 0 until 5) {
            val a = (GameSurface.noise(seed, k, 51) - 0.5).toFloat() * 3.0f
            val q = minOf(1f, t / 0.75f)
            val d = cellSize * q * (0.6f + GameSurface.noise(seed, k, 52).toFloat())
            val px = c.x + a * d * 0.6f
            val py = c.y - cellSize * 0.85f * sin(q * PI).toFloat() + cellSize * 0.5f * q * q
            val sz = cellSize * 0.05f * (1f - q * 0.5f)
            drawCircle(
                color = Color.White.copy(alpha = 0.7f * (1f - q)),
                radius = sz,
                center = Offset(px, py),
            )
        }

        // THREE HOLLOW RINGS spreading out. The permanent miss marker is a hollow ring too, so the
        // animation resolves INTO the marker rather than being replaced by it.
        for (k in 0 until 3) {
            val delay = k * 0.14f
            val q = (t - delay) / (1f - delay)
            if (q <= 0f) continue
            val rr = cellSize * (0.14f + 0.62f * q)
            val alpha = (0.60f * (1f - q)).coerceAtLeast(0f)
            drawOval(
                color = ink.copy(alpha = alpha),
                topLeft = Offset(c.x - rr, c.y - rr * 0.62f),
                size = Size(rr * 2f, rr * 1.24f),
                style = Stroke(width = (1.4f * (1f - q)).coerceAtLeast(0.4f)),
            )
        }
    }

    // ---- helpers ----------------------------------------------------------------------------

    /**
     * Ease-out-cubic. The launcher swings quickly and settles; a linear swing reads as a mechanism
     * being driven rather than one aiming.
     */
    private fun ease(x: Float): Float {
        val c = x.coerceIn(0f, 1f)
        return 1f - (1f - c).pow(3)
    }
}
