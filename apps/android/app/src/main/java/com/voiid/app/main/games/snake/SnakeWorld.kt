package com.voiid.app.main.games.snake

import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.min
import kotlin.math.pow
import kotlin.math.sin
import kotlin.math.sqrt
import kotlin.random.Random

/*
 * Port of iOS `Games/Snake/SnakeCore.swift` + `SnakeWorld.swift`, constant for constant: the
 * offline slither arena — you plus N bots on this device, no server round trip.
 *
 * One deliberate difference: SpriteKit's y axis points up and Compose's points down. The world
 * runs in screen orientation (y down). The arena is a circle and every rule is rotation- and
 * mirror-symmetric, so play is identical; only "label above the head" flips its sign.
 */

// MARK: - Vector helpers

class P(val x: Float, val y: Float) {
    operator fun plus(o: P) = P(x + o.x, y + o.y)
    operator fun minus(o: P) = P(x - o.x, y - o.y)
    operator fun times(s: Float) = P(x * s, y * s)
    val length: Float get() = sqrt(x * x + y * y)
    val angle: Float get() = atan2(y, x)
    fun distance(p: P) = (this - p).length
    fun distanceSquared(p: P): Float { val dx = x - p.x; val dy = y - p.y; return dx * dx + dy * dy }
    fun lerp(p: P, t: Float) = P(x + (p.x - x) * t, y + (p.y - y) * t)

    companion object {
        val ZERO = P(0f, 0f)
        fun fromAngle(a: Float, length: Float = 1f) = P(cos(a) * length, sin(a) * length)
    }
}

private const val TWO_PI = (PI * 2).toFloat()

fun angleDelta(from: Float, to: Float): Float {
    var d = (to - from) % TWO_PI
    if (d > PI) d -= TWO_PI
    if (d < -PI) d += TWO_PI
    return d
}

private fun clampF(v: Float, lo: Float, hi: Float) = min(max(v, lo), hi)

// MARK: - Tuning

object Cfg {
    const val ARENA_RADIUS = 2400f

    const val START_MASS = 14f
    const val MIN_MASS = 10f
    const val MAX_MASS = 4000f

    const val BASE_SPEED = 205f
    const val BOOST_SPEED = 355f
    const val BOOST_MASS_PER_SECOND = 14f
    const val BOOST_PELLET_INTERVAL = 0.11f
    const val BOOST_PELLET_VALUE = 1.3f

    fun turnRate(radius: Float) = clampF(5.6f - radius * 0.055f, 1.9f, 5.6f)
    fun radius(mass: Float) = 9f * (max(mass, MIN_MASS) / START_MASS).pow(0.29f)
    fun segmentSpacing(radius: Float) = radius * 0.58f
    fun segmentCount(mass: Float) = clampF(10f + mass * 0.42f, 10f, 320f).toInt()

    // Food
    const val FOOD_TARGET = 620
    const val FOOD_RADIUS = 5.5f
    const val FOOD_VALUE = 1.0f
    const val MAGNET_RANGE = 4.2f
    const val MAGNET_SPEED = 430f

    // Death scatter
    const val CORPSE_VALUE_FACTOR = 0.62f
    const val CORPSE_PELLET_VALUE = 3.0f

    const val BOT_THINK_INTERVAL = 0.09f
}

// MARK: - Trail

class Trail {
    val points = ArrayList<P>()

    fun reset(p: P) { points.clear(); points += p; points += p }

    fun record(p: P, minStep: Float) {
        if (points.size < 2) { reset(p); return }
        val anchor = points[points.size - 2]
        if (anchor.distance(p) >= minStep) points += p else points[points.size - 1] = p
    }

    fun trim(maxLength: Float) {
        if (points.size <= 2) return
        var acc = 0f
        var i = points.size - 1
        while (i > 0) {
            acc += points[i].distance(points[i - 1])
            if (acc >= maxLength) break
            i -= 1
        }
        if (i > 1) points.subList(0, i - 1).clear()
    }

    fun sample(spacing: Float, count: Int): List<P> {
        val out = ArrayList<P>(count)
        val head = points.lastOrNull() ?: return out
        out += head
        if (count <= 1) return out
        var i = points.size - 1
        var cursor = head
        var need = spacing
        while (out.size < count) {
            if (i == 0) { out += points[0]; continue }
            val next = points[i - 1]
            val seg = cursor.distance(next)
            if (seg >= need) {
                cursor = cursor.lerp(next, need / max(seg, 0.0001f))
                out += cursor
                need = spacing
            } else {
                need -= seg
                cursor = next
                i -= 1
            }
        }
        return out
    }
}

// MARK: - Entities

class Snake(
    val id: Int,
    val name: String,
    val skin: Int,
    val isPlayer: Boolean,
    var head: P,
    var heading: Float,
) {
    var desiredHeading = heading
    var mass = Cfg.START_MASS
    var boosting = false
    var alive = true
    val trail = Trail().also { it.reset(head) }
    var body: List<P> = emptyList()
    var boostClock = 0f
    var thinkClock = 0f

    val radius get() = Cfg.radius(mass)
    val spacing get() = Cfg.segmentSpacing(radius)
    val segmentCount get() = Cfg.segmentCount(mass)
    val score get() = mass.toInt()
    val isBoostingEffective get() = boosting && mass > Cfg.MIN_MASS + 2
    val speed get() = if (isBoostingEffective) Cfg.BOOST_SPEED else Cfg.BASE_SPEED

    fun rebuildBody() { body = trail.sample(spacing, segmentCount) }
}

class Food(var position: P, val value: Float, val skin: Int, var velocity: P = P.ZERO) {
    val radius get() = Cfg.FOOD_RADIUS * (1 + (value - 1) * 0.16f)
}

// MARK: - Spatial hash

private class SpatialHash(private val cell: Float) {
    class Entry(val snake: Int, val point: P, val radius: Float)

    private val buckets = HashMap<Long, ArrayList<Entry>>()

    private fun key(gx: Int, gy: Int): Long = (gx.toLong() shl 32) or (gy.toLong() and 0xffffffffL)

    fun removeAll() = buckets.values.forEach { it.clear() }

    fun insert(e: Entry) {
        val k = key(floor(e.point.x / cell).toInt(), floor(e.point.y / cell).toInt())
        buckets.getOrPut(k) { ArrayList() } += e
    }

    inline fun forNearby(p: P, block: (Entry) -> Boolean) {
        val gx = floor(p.x / cell).toInt(); val gy = floor(p.y / cell).toInt()
        for (dx in -1..1) for (dy in -1..1) {
            val bucket = buckets[key(gx + dx, gy + dy)] ?: continue
            for (e in bucket) if (block(e)) return
        }
    }
}

class LeaderRow(val name: String, val score: Int, val isPlayer: Boolean)

// MARK: - World

class SnakeWorld {
    val snakes = ArrayList<Snake>()
    var food = ArrayList<Food>()
        private set
    var tick = 0
        private set

    var playerAim: Float? = null
    var playerBoosting = false
    var isPaused = false
    var activeBotCount = 11
    var playerKills = 0

    private val hash = SpatialHash(90f)
    private var nextID = 0

    val player: Snake? get() = snakes.firstOrNull { it.isPlayer }

    private val botNames = listOf(
        "Vyper", "Kraken", "Nagini", "Coil", "Rattler", "Mamba",
        "Sidewinder", "Boa", "Adder", "Python", "Cobra", "Basilisk",
        "Taipan", "Krait", "Fang",
    )

    fun reset(botCount: Int = 11) {
        activeBotCount = botCount
        playerKills = 0
        snakes.clear()
        food.clear()
        nextID = 0
        tick = 0
        isPaused = false
        playerAim = null
        spawn(true, "You")
        for (i in 0 until activeBotCount) spawn(false, botNames[i % botNames.size])
        while (food.size < Cfg.FOOD_TARGET) food += randomPellet()
    }

    private fun spawn(isPlayer: Boolean, name: String): Snake {
        val id = nextID++
        val angle = Random.nextFloat() * TWO_PI
        val dist = Random.nextFloat() * Cfg.ARENA_RADIUS * 0.72f
        val s = Snake(id, name, id % 8, isPlayer, P.fromAngle(angle, dist), Random.nextFloat() * TWO_PI)
        snakes += s
        return s
    }

    private fun randomPellet(): Food {
        val angle = Random.nextFloat() * TWO_PI
        val dist = sqrt(Random.nextFloat()) * Cfg.ARENA_RADIUS * 0.97f
        return Food(P.fromAngle(angle, dist), Cfg.FOOD_VALUE, Random.nextInt(8))
    }

    fun step(dtIn: Float) {
        if (isPaused) return
        tick += 1
        val dt = min(dtIn, 1f / 30)

        player?.let { p -> playerAim?.let { p.desiredHeading = it }; p.boosting = playerBoosting }
        for (s in snakes) if (!s.isPlayer) think(s, dt)
        for (s in snakes) advance(s, dt)

        rebuildHashes()
        resolveCollisions()
        consumeFood(dt)

        while (food.size < Cfg.FOOD_TARGET) food += randomPellet()
    }

    private fun advance(s: Snake, dt: Float) {
        if (!s.alive) return
        val maxTurn = Cfg.turnRate(s.radius) * dt
        s.heading += clampF(angleDelta(s.heading, s.desiredHeading), -maxTurn, maxTurn)

        if (s.isBoostingEffective) {
            s.mass = max(Cfg.MIN_MASS, s.mass - Cfg.BOOST_MASS_PER_SECOND * dt)
            s.boostClock += dt
            if (s.boostClock >= Cfg.BOOST_PELLET_INTERVAL) {
                s.boostClock = 0f
                val behind = if (s.body.size > 3) s.body.last() else s.head
                food += Food(behind, Cfg.BOOST_PELLET_VALUE, s.skin)
            }
        }

        s.head = s.head + P.fromAngle(s.heading, s.speed * dt)
        s.trail.record(s.head, max(2f, s.radius * 0.25f))
        s.trail.trim((s.segmentCount + 4) * s.spacing)
        s.rebuildBody()
    }

    private fun rebuildHashes() {
        hash.removeAll()
        for (s in snakes) if (s.alive) {
            val r = s.radius
            s.body.forEachIndexed { i, p -> if (i > 2) hash.insert(SpatialHash.Entry(s.id, p, r)) }
        }
    }

    // MARK: Collisions

    private fun resolveCollisions() {
        val doomed = HashSet<Int>()
        val playerId = player?.id
        for (s in snakes) {
            if (!s.alive) continue
            if (s.head.length + s.radius * 0.5f > Cfg.ARENA_RADIUS) { doomed += s.id; continue }
            hash.forNearby(s.head) { e ->
                if (e.snake == s.id) return@forNearby false
                val reach = s.radius * 0.72f + e.radius * 0.85f
                if (s.head.distanceSquared(e.point) < reach * reach) {
                    doomed += s.id
                    if (e.snake == playerId && !s.isPlayer) playerKills += 1
                    true
                } else false
            }
        }
        if (doomed.isEmpty()) return
        for (s in snakes) if (s.id in doomed) kill(s)
        snakes.removeAll { !it.alive && !it.isPlayer }
        while (snakes.count { !it.isPlayer } < activeBotCount) spawn(false, botNames.random())
    }

    private fun kill(s: Snake) {
        s.alive = false
        val total = s.mass * Cfg.CORPSE_VALUE_FACTOR
        val pellets = max(4, (total / Cfg.CORPSE_PELLET_VALUE).toInt())
        if (s.body.isEmpty()) return
        for (i in 0 until pellets) {
            val t = i.toFloat() / max(pellets - 1, 1)
            val idx = (t * (s.body.size - 1)).toInt()
            val jitter = P(Random.nextFloat() * 12 - 6, Random.nextFloat() * 12 - 6)
            food += Food(s.body[idx] + jitter, Cfg.CORPSE_PELLET_VALUE, s.skin, jitter * 3f)
        }
    }

    // MARK: Food

    private fun consumeFood(dt: Float) {
        if (food.isEmpty()) return
        val eaten = BooleanArray(food.size)
        var any = false
        for (s in snakes) {
            if (!s.alive) continue
            val pull = s.radius * Cfg.MAGNET_RANGE
            val pullSq = pull * pull
            val bite = s.radius + Cfg.FOOD_RADIUS
            for (i in food.indices) {
                if (eaten[i]) continue
                val f = food[i]
                val d2 = f.position.distanceSquared(s.head)
                if (d2 >= pullSq) continue
                if (d2 < bite * bite) {
                    s.mass = min(Cfg.MAX_MASS, s.mass + f.value)
                    eaten[i] = true; any = true
                } else {
                    val dir = s.head - f.position
                    f.position = f.position + dir * (1f / max(dir.length, 0.001f)) * (Cfg.MAGNET_SPEED * dt)
                }
            }
        }
        for (f in food) if (f.velocity.length > 1) {
            f.position = f.position + f.velocity * dt
            f.velocity = f.velocity * 0.88f
        }
        if (any) {
            val kept = ArrayList<Food>(food.size)
            food.forEachIndexed { i, f -> if (!eaten[i]) kept += f }
            food = kept
        }
    }

    // MARK: Bots

    private val offsets = floatArrayOf(0f, -0.35f, 0.35f, -0.75f, 0.75f, -1.25f, 1.25f, -1.9f, 1.9f)

    private fun think(s: Snake, dt: Float) {
        if (!s.alive) return
        s.thinkClock += dt
        if (s.thinkClock < Cfg.BOT_THINK_INTERVAL) return
        s.thinkClock = 0f

        val look = s.radius * 7 + 60
        var bestAngle = 0f; var bestClear = -1f
        for (off in offsets) {
            val a = s.heading + off
            val clearance = probe(s, a, look)
            if (clearance >= look) { bestAngle = a; bestClear = clearance; break }
            if (bestClear < 0 || clearance > bestClear) { bestAngle = a; bestClear = clearance }
        }
        if (bestClear < look) {
            s.desiredHeading = bestAngle
            s.boosting = false
            return
        }

        var target: P? = null
        var bestScore = Float.MAX_VALUE
        val searchSq = 700f * 700f
        for (f in food) {
            val d2 = f.position.distanceSquared(s.head)
            if (d2 >= searchSq) continue
            val score = d2 / (f.value * f.value)
            if (score < bestScore) { bestScore = score; target = f.position }
        }
        if (target != null) {
            val aim = (target - s.head).angle
            if (probe(s, aim, look * 0.8f) >= look * 0.8f) s.desiredHeading = aim
        } else if (s.head.length > Cfg.ARENA_RADIUS * 0.8f) {
            s.desiredHeading = (P.ZERO - s.head).angle
        }
        s.boosting = s.mass > 60 && bestScore < 200f * 200f && Random.nextInt(7) == 0
    }

    private fun probe(s: Snake, angle: Float, distance: Float): Float {
        val steps = 6
        for (i in 1..steps) {
            val t = distance * i / steps
            val p = s.head + P.fromAngle(angle, t)
            if (p.length + s.radius > Cfg.ARENA_RADIUS) return t
            var hit = false
            hash.forNearby(p) { e ->
                if (e.snake == s.id) return@forNearby false
                val reach = s.radius + e.radius * 1.15f
                hit = p.distanceSquared(e.point) < reach * reach
                hit
            }
            if (hit) return t
        }
        return distance
    }

    // MARK: Readouts

    fun leaderboard(limit: Int = 5): List<LeaderRow> =
        snakes.filter { it.alive }.sortedByDescending { it.mass }.take(limit)
            .map { LeaderRow(it.name, it.score, it.isPlayer) }

    fun rank(s: Snake) = 1 + snakes.count { it.alive && it.mass > s.mass }
}
