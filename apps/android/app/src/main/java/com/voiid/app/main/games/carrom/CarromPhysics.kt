package com.voiid.app.main.games.carrom

import kotlin.math.atan2
import kotlin.math.cos
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sin
import kotlin.math.sqrt

/*
 * Port of iOS `CarromPhysics.swift`, constant for constant: a deterministic 2D rigid-body
 * world for Carrom — circle–circle impulses, cushion bounces, powder friction, pocket gravity
 * wells and the aim raycast with one wall reflection. Units are the virtual 360×360 surface.
 */

/** A 2D vector / point on the virtual surface. */
data class Vec(val x: Float, val y: Float) {
    operator fun plus(o: Vec) = Vec(x + o.x, y + o.y)
    operator fun minus(o: Vec) = Vec(x - o.x, y - o.y)
    operator fun times(s: Float) = Vec(x * s, y * s)
    operator fun div(s: Float) = Vec(x / s, y / s)
    val lengthSquared: Float get() = x * x + y * y
    val length: Float get() = sqrt(lengthSquared)
    fun dot(o: Vec) = x * o.x + y * o.y
    fun distance(o: Vec) = (this - o).length
    val angle: Float get() = atan2(y, x)
    fun normalized(): Vec {
        val l = length
        return if (l > 0.0001f) Vec(x / l, y / l) else ZERO
    }

    companion object {
        val ZERO = Vec(0f, 0f)
        fun fromAngle(a: Float, len: Float = 1f) = Vec(cos(a) * len, sin(a) * len)
    }
}

enum class CarromPieceType { WHITE, BLACK, QUEEN, STRIKER }

data class CarromPiece(
    val id: Int,
    val type: CarromPieceType,
    var position: Vec,
    var velocity: Vec = Vec.ZERO,
    val radius: Float,
    val mass: Float,
    var isPocketed: Boolean = false,
    /** 0 = on the board, 1 = fully in the pocket. */
    var sinkProgress: Float = 0f,
    var pocketIndex: Int? = null,
)

data class CarromAimResult(
    val strikerPos: Vec,
    val rayStart: Vec,
    val rayEnd: Vec,
    val hasWallHit: Boolean,
    val wallBounceEnd: Vec?,
    val targetPieceId: Int?,
    val ghostStrikerPos: Vec?,
    val targetDeflectionEnd: Vec?,
)

class CarromPhysicsWorld {
    var pieces: MutableList<CarromPiece> = mutableListOf()
    val surfaceSize = CarromTheme.SURFACE

    val pocketCenters = listOf(
        Vec(CarromTheme.POCKET_INSET, CarromTheme.POCKET_INSET),
        Vec(CarromTheme.SURFACE - CarromTheme.POCKET_INSET, CarromTheme.POCKET_INSET),
        Vec(CarromTheme.SURFACE - CarromTheme.POCKET_INSET, CarromTheme.SURFACE - CarromTheme.POCKET_INSET),
        Vec(CarromTheme.POCKET_INSET, CarromTheme.SURFACE - CarromTheme.POCKET_INSET),
    )

    var onPieceCollision: ((Float) -> Unit)? = null
    var onCushionBounce: (() -> Unit)? = null
    var onPiecePocketed: ((CarromPiece, Int) -> Unit)? = null

    /** Four sub-steps per frame so a fast striker cannot tunnel through a piece. */
    fun step(dt: Float) {
        if (dt <= 0f) return
        val sub = dt / 4f
        repeat(4) { subStep(sub) }
    }

    private fun subStep(dt: Float) {
        for (p in pieces) {
            if (p.isPocketed) continue
            checkPocketSuction(p, dt)
            if (p.sinkProgress > 0f) {
                p.position = p.position + p.velocity * dt
                continue
            }
            p.position = p.position + p.velocity * dt
            // Boric-powder friction: constant Coulomb sliding + light viscous drag.
            val speed = p.velocity.length
            if (speed > 1f) {
                val total = (310f + 0.55f * speed) * dt
                p.velocity = if (speed <= total) Vec.ZERO else p.velocity.normalized() * (speed - total)
            } else {
                p.velocity = Vec.ZERO
            }
            resolveCushionBounce(p)
        }
        resolvePieceCollisions()
    }

    private fun checkPocketSuction(p: CarromPiece, dt: Float) {
        val suctionRadius = CarromTheme.POCKET_RADIUS + p.radius * 0.40f
        pocketCenters.forEachIndexed { idx, pocket ->
            val dist = p.position.distance(pocket)
            if (p.pocketIndex == idx || (p.pocketIndex == null && dist < suctionRadius)) {
                if (p.pocketIndex == null) p.pocketIndex = idx
                val toPocket = (pocket - p.position).normalized()
                p.velocity = (p.velocity + toPocket * (450f * dt)) * 0.82f
                p.sinkProgress += dt * 6.5f
                if (p.sinkProgress >= 1f || dist < CarromTheme.POCKET_RADIUS * 0.55f) {
                    p.isPocketed = true
                    p.sinkProgress = 1f
                    p.velocity = Vec.ZERO
                    p.position = pocket
                    onPiecePocketed?.invoke(p, idx)
                }
                return
            }
        }
    }

    private fun resolveCushionBounce(p: CarromPiece) {
        if (p.sinkProgress != 0f) return
        val r = p.radius
        var x = p.position.x; var y = p.position.y
        var vx = p.velocity.x; var vy = p.velocity.y
        val e = 0.74f
        var bounced = false
        if (x - r < 0) { x = r; if (vx < 0) { vx = -vx * e; bounced = true } }
        if (x + r > surfaceSize) { x = surfaceSize - r; if (vx > 0) { vx = -vx * e; bounced = true } }
        if (y - r < 0) { y = r; if (vy < 0) { vy = -vy * e; bounced = true } }
        if (y + r > surfaceSize) { y = surfaceSize - r; if (vy > 0) { vy = -vy * e; bounced = true } }
        p.position = Vec(x, y)
        p.velocity = Vec(vx, vy)
        if (bounced && p.velocity.length > 25f) onCushionBounce?.invoke()
    }

    private fun clamp(p: CarromPiece) {
        if (p.sinkProgress != 0f) return
        val r = p.radius
        p.position = Vec(min(max(p.position.x, r), surfaceSize - r), min(max(p.position.y, r), surfaceSize - r))
    }

    private fun resolvePieceCollisions() {
        val n = pieces.size
        if (n < 2) return
        repeat(2) {   // two relaxation passes for clusters
            for (i in 0 until n) {
                val a = pieces[i]
                if (a.isPocketed || a.sinkProgress != 0f) continue
                for (j in i + 1 until n) {
                    val b = pieces[j]
                    if (b.isPocketed || b.sinkProgress != 0f) continue
                    val delta = b.position - a.position
                    val distSq = delta.lengthSquared
                    val minDist = a.radius + b.radius
                    if (distSq < minDist * minDist && distSq > 0.0001f) {
                        val dist = sqrt(distSq)
                        val normal = delta * (1f / dist)
                        val overlap = minDist - dist
                        val invA = 1f / a.mass; val invB = 1f / b.mass; val invSum = invA + invB
                        a.position = a.position - normal * (overlap * invA / invSum)
                        b.position = b.position + normal * (overlap * invB / invSum)
                        clamp(a); clamp(b)
                        val velAlong = (a.velocity - b.velocity).dot(normal)
                        if (velAlong > 0) {
                            val impulse = (1f + 0.74f) * velAlong / invSum
                            a.velocity = a.velocity - normal * (impulse * invA)
                            b.velocity = b.velocity + normal * (impulse * invB)
                            if (impulse > 20f) onPieceCollision?.invoke(impulse)
                        }
                    }
                }
            }
        }
    }

    fun predictAim(origin: Vec, direction: Vec, maxDist: Float = 500f): CarromAimResult {
        val dir = direction.normalized()
        if (dir.lengthSquared <= 0.1f) {
            return CarromAimResult(origin, origin, origin, false, null, null, null, null)
        }
        val sr = CarromTheme.STRIKER_RADIUS
        var nearest = maxDist
        var hit: CarromPiece? = null
        for (piece in pieces) {
            if (piece.type == CarromPieceType.STRIKER || piece.isPocketed) continue
            val oc = piece.position - origin
            val tca = oc.dot(dir)
            if (tca < 0) continue
            val d2 = oc.lengthSquared - tca * tca
            val r2 = (sr + piece.radius) * (sr + piece.radius)
            if (d2 > r2) continue
            val t = tca - sqrt(max(0f, r2 - d2))
            if (t > 0 && t < nearest) { nearest = t; hit = piece }
        }
        hit?.let { target ->
            val rayEnd = origin + dir * nearest
            val normal = (target.position - rayEnd).normalized()
            return CarromAimResult(origin, origin, rayEnd, false, null, target.id, rayEnd,
                target.position + normal * 52f)
        }
        var wallT = maxDist
        var wallNormal = Vec.ZERO
        if (dir.x < 0) { val t = (sr - origin.x) / dir.x; if (t > 0 && t < wallT) { wallT = t; wallNormal = Vec(1f, 0f) } }
        if (dir.x > 0) { val t = (surfaceSize - sr - origin.x) / dir.x; if (t > 0 && t < wallT) { wallT = t; wallNormal = Vec(-1f, 0f) } }
        if (dir.y < 0) { val t = (sr - origin.y) / dir.y; if (t > 0 && t < wallT) { wallT = t; wallNormal = Vec(0f, 1f) } }
        if (dir.y > 0) { val t = (surfaceSize - sr - origin.y) / dir.y; if (t > 0 && t < wallT) { wallT = t; wallNormal = Vec(0f, -1f) } }
        val rayEnd = origin + dir * wallT
        val bounceDir = dir - wallNormal * (2f * dir.dot(wallNormal))
        return CarromAimResult(origin, origin, rayEnd, true, rayEnd + bounceDir.normalized() * 60f, null, null, null)
    }

    val isSettled: Boolean
        get() = pieces.none { !it.isPocketed && (it.velocity.lengthSquared > 2f || it.sinkProgress > 0f) }
}
