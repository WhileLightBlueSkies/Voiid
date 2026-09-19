package com.voiid.app.main.clips.facefx

import kotlin.math.abs
import kotlin.math.exp
import kotlin.math.min
import kotlin.math.sqrt

/**
 * One Euro filter: low cutoff when still (kills jitter), high cutoff when
 * moving (kills lag). A fixed low-pass cannot do both, which is the whole
 * reason this exists.
 *
 * Ported from the old ClipFaceEffects.kt. That file was wrong about most
 * things but right about this, and its tuning came from real device time.
 */
class OneEuroFilter(private var minCutoff: Float, private var beta: Float) {
    private var dCutoff = 1.0f
    private var xPrev = 0f
    private var dxPrev = 0f
    private var hasPrev = false

    private fun alpha(cutoff: Float, dt: Float): Float {
        val tau = 1f / (2f * Math.PI.toFloat() * cutoff)
        return 1f / (1f + tau / dt)
    }

    fun reset() { hasPrev = false; xPrev = 0f; dxPrev = 0f }

    fun filter(x: Float, dt: Float): Float {
        if (!hasPrev || dt <= 0f) {
            xPrev = x; dxPrev = 0f; hasPrev = true
            return x
        }
        val dx = (x - xPrev) / dt
        val aD = alpha(dCutoff, dt)
        val edx = aD * dx + (1 - aD) * dxPrev
        val cutoff = minCutoff + beta * abs(edx)
        val a = alpha(cutoff, dt)
        val xHat = a * x + (1 - a) * xPrev
        xPrev = xHat; dxPrev = edx
        return xHat
    }
}

/**
 * Critically-ish damped spring, sub-stepped at a fixed 240 Hz.
 *
 * Integrating a spring at a variable dt is a spring with variable stiffness:
 * the bounce would change character with frame rate, which is exactly the kind
 * of thing that feels wrong without being obviously broken.
 */
class SpringState {
    private var pos = 0f
    private var vel = 0f

    fun reset() { pos = 0f; vel = 0f }

    fun update(target: Float, dt: Float, stiffness: Float = 160f, damping: Float = 12f): Float {
        var remaining = min(dt, 0.1f)
        while (remaining > 0f) {
            val h = min(FIXED_STEP, remaining)
            val force = -stiffness * (pos - target) - damping * vel
            vel += force * h
            pos += vel * h
            remaining -= h
        }
        return pos
    }

    private companion object { const val FIXED_STEP = 1f / 240f }
}

/**
 * Smooths the head pose and blendshapes, and -- unlike iOS -- EXTRAPOLATES
 * forward to the display time.
 *
 * ARKit hands iOS a pose already matched to the frame it describes. MediaPipe
 * does not: it runs asynchronously on its own thread at roughly 24 Hz while the
 * display runs at 60. Without prediction every filter trails the face by 40-60
 * ms, which reads as "floaty" even when the placement is perfect. Prediction is
 * the single biggest contributor to Android feeling as immediate as iOS.
 *
 * The clamps matter as much as the prediction: an unclamped extrapolation
 * overshoots on a fast turn and snaps back, which is worse than the lag it
 * was meant to hide.
 */
class PoseStabilizer {

    private val tx = OneEuroFilter(1.8f, 0.02f)
    private val ty = OneEuroFilter(1.8f, 0.02f)
    private val tz = OneEuroFilter(1.8f, 0.02f)
    private val blend = Array(FaceFrame.BLENDSHAPE_COUNT) { OneEuroFilter(3.2f, 0.22f) }

    private var lastQuat = floatArrayOf(0f, 0f, 0f, 1f)
    private var haveQuat = false
    private var lastTimeNanos = 0L

    // Last two accepted poses, for the velocity estimate.
    private val prevTranslation = FloatArray(3)
    private val lastTranslation = FloatArray(3)
    private var prevTimeNanos = 0L
    private var havePrev = false

    val angularVelocity = FloatArray(3)

    fun reset() {
        tx.reset(); ty.reset(); tz.reset()
        blend.forEach { it.reset() }
        haveQuat = false
        lastTimeNanos = 0L
        prevTimeNanos = 0L
        havePrev = false
        angularVelocity.fill(0f)
    }

    /**
     * Smooth [frame] in place. [nowNanos] is the display time being rendered
     * for; the gap between it and the frame's own timestamp is what gets
     * predicted away.
     */
    fun stabilize(frame: FaceFrame, nowNanos: Long) {
        if (!frame.valid) { reset(); return }

        val dt = if (lastTimeNanos > 0L) {
            ((frame.timestampNanos - lastTimeNanos) * 1e-9f).coerceIn(1f / 120f, 0.1f)
        } else {
            1f / 60f
        }
        lastTimeNanos = frame.timestampNanos

        val m = frame.headMatrix
        val t = floatArrayOf(m[12], m[13], m[14])

        // Decompose to translation + quaternion + scale before filtering.
        // Smoothing sixteen matrix elements independently does not preserve
        // orthonormality, and the accumulated shear reads as props that skew
        // when the head turns.
        val sx = sqrt(m[0] * m[0] + m[1] * m[1] + m[2] * m[2])
        val sy = sqrt(m[4] * m[4] + m[5] * m[5] + m[6] * m[6])
        val sz = sqrt(m[8] * m[8] + m[9] * m[9] + m[10] * m[10])
        val r = floatArrayOf(
            m[0] / sx, m[1] / sx, m[2] / sx,
            m[4] / sy, m[5] / sy, m[6] / sy,
            m[8] / sz, m[9] / sz, m[10] / sz,
        )
        var q = matrixToQuaternion(r)

        if (haveQuat) {
            // Quaternions double-cover: q and -q are the same orientation, and
            // interpolating to the far one spins the head the long way round.
            if (dot(q, lastQuat) < 0f) q = floatArrayOf(-q[0], -q[1], -q[2], -q[3])
            val responsiveness = 1f - exp(-dt * 26f)
            q = slerp(lastQuat, q, responsiveness)

            val delta = multiply(q, conjugate(lastQuat))
            val angle = 2f * kotlin.math.acos(delta[3].coerceIn(-1f, 1f))
            if (angle > 1e-5f && dt > 0f) {
                val s = sqrt(1f - delta[3] * delta[3]).coerceAtLeast(1e-6f)
                angularVelocity[0] = delta[0] / s * (angle / dt)
                angularVelocity[1] = delta[1] / s * (angle / dt)
                angularVelocity[2] = delta[2] / s * (angle / dt)
            } else {
                angularVelocity.fill(0f)
            }
        }
        lastQuat = q
        haveQuat = true

        val st = floatArrayOf(tx.filter(t[0], dt), ty.filter(t[1], dt), tz.filter(t[2], dt))

        // ---- extrapolation --------------------------------------------------
        // Predict the translation forward to the display time. Rotation is left
        // alone: predicting orientation is where overshoot is most visible, and
        // the slerp above already runs ahead of a fixed low-pass.
        if (havePrev) {
            val vdt = (frame.timestampNanos - prevTimeNanos) * 1e-9f
            val lead = ((nowNanos - frame.timestampNanos) * 1e-9f)
                .coerceIn(0f, MAX_EXTRAPOLATION_SECONDS)
            if (vdt > 1e-4f && lead > 0f) {
                // Displacement is capped against the face's own scale, so the
                // clamp means the same thing near and far from the camera.
                val maxStep = frame.interocularCm * frame.cmToUnits * MAX_STEP_INTEROCULAR
                for (i in 0..2) {
                    val v = (st[i] - prevTranslation[i]) / vdt
                    st[i] += (v * lead).coerceIn(-maxStep, maxStep)
                }
            }
        }
        st.copyInto(lastTranslation)
        lastTranslation.copyInto(prevTranslation)
        prevTimeNanos = frame.timestampNanos
        havePrev = true

        quaternionToMatrix(q, sx, sy, sz, st, m)

        for (i in frame.blendshapes.indices) {
            frame.blendshapes[i] = blend[i].filter(frame.blendshapes[i], dt)
        }
        angularVelocity.copyInto(frame.angularVelocity)
    }

    // --- quaternion helpers -------------------------------------------------

    private fun dot(a: FloatArray, b: FloatArray) =
        a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3]

    private fun conjugate(q: FloatArray) = floatArrayOf(-q[0], -q[1], -q[2], q[3])

    private fun multiply(a: FloatArray, b: FloatArray) = floatArrayOf(
        a[3] * b[0] + a[0] * b[3] + a[1] * b[2] - a[2] * b[1],
        a[3] * b[1] - a[0] * b[2] + a[1] * b[3] + a[2] * b[0],
        a[3] * b[2] + a[0] * b[1] - a[1] * b[0] + a[2] * b[3],
        a[3] * b[3] - a[0] * b[0] - a[1] * b[1] - a[2] * b[2],
    )

    private fun slerp(a: FloatArray, b: FloatArray, t: Float): FloatArray {
        var cos = dot(a, b)
        val bb = if (cos < 0f) { cos = -cos; floatArrayOf(-b[0], -b[1], -b[2], -b[3]) } else b
        if (cos > 0.9995f) {
            val o = FloatArray(4)
            for (i in 0..3) o[i] = a[i] + (bb[i] - a[i]) * t
            return normalize(o)
        }
        val theta = kotlin.math.acos(cos.coerceIn(-1f, 1f))
        val sinTheta = kotlin.math.sin(theta)
        val wa = kotlin.math.sin((1 - t) * theta) / sinTheta
        val wb = kotlin.math.sin(t * theta) / sinTheta
        return normalize(floatArrayOf(
            a[0] * wa + bb[0] * wb, a[1] * wa + bb[1] * wb,
            a[2] * wa + bb[2] * wb, a[3] * wa + bb[3] * wb))
    }

    private fun normalize(q: FloatArray): FloatArray {
        val n = sqrt(dot(q, q)).coerceAtLeast(1e-6f)
        return floatArrayOf(q[0] / n, q[1] / n, q[2] / n, q[3] / n)
    }

    /** [r] is a column-major 3x3. Shepperd's method: pick the largest diagonal
     *  term so the square root never divides by something near zero. */
    private fun matrixToQuaternion(r: FloatArray): FloatArray {
        val m00 = r[0]; val m10 = r[1]; val m20 = r[2]
        val m01 = r[3]; val m11 = r[4]; val m21 = r[5]
        val m02 = r[6]; val m12 = r[7]; val m22 = r[8]
        val trace = m00 + m11 + m22
        return when {
            trace > 0f -> {
                val s = sqrt(trace + 1f) * 2f
                floatArrayOf((m21 - m12) / s, (m02 - m20) / s, (m10 - m01) / s, 0.25f * s)
            }
            m00 > m11 && m00 > m22 -> {
                val s = sqrt(1f + m00 - m11 - m22) * 2f
                floatArrayOf(0.25f * s, (m01 + m10) / s, (m02 + m20) / s, (m21 - m12) / s)
            }
            m11 > m22 -> {
                val s = sqrt(1f + m11 - m00 - m22) * 2f
                floatArrayOf((m01 + m10) / s, 0.25f * s, (m12 + m21) / s, (m02 - m20) / s)
            }
            else -> {
                val s = sqrt(1f + m22 - m00 - m11) * 2f
                floatArrayOf((m02 + m20) / s, (m12 + m21) / s, 0.25f * s, (m10 - m01) / s)
            }
        }
    }

    private fun quaternionToMatrix(
        q: FloatArray, sx: Float, sy: Float, sz: Float,
        t: FloatArray, out: FloatArray,
    ) {
        val x = q[0]; val y = q[1]; val z = q[2]; val w = q[3]
        out[0] = (1 - 2 * (y * y + z * z)) * sx
        out[1] = (2 * (x * y + z * w)) * sx
        out[2] = (2 * (x * z - y * w)) * sx
        out[3] = 0f
        out[4] = (2 * (x * y - z * w)) * sy
        out[5] = (1 - 2 * (x * x + z * z)) * sy
        out[6] = (2 * (y * z + x * w)) * sy
        out[7] = 0f
        out[8] = (2 * (x * z + y * w)) * sz
        out[9] = (2 * (y * z - x * w)) * sz
        out[10] = (1 - 2 * (x * x + y * y)) * sz
        out[11] = 0f
        out[12] = t[0]; out[13] = t[1]; out[14] = t[2]; out[15] = 1f
    }

    private companion object {
        /** Beyond ~50 ms a constant-velocity model stops being a good guess. */
        const val MAX_EXTRAPOLATION_SECONDS = 0.05f
        /** Cap displacement at a fraction of the face's own width. */
        const val MAX_STEP_INTEROCULAR = 0.15f
    }
}
