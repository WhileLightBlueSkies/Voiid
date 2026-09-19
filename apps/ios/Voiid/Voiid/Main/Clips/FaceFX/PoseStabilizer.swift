//
//  PoseStabilizer.swift
//  Voiid
//
//  One Euro smoothing and spring physics.
//
//  The filter and the spring are ported verbatim from the old
//  ClipFaceEffects.swift — that code was wrong about a lot of things, but these
//  two were right, and the tuning in them came from real device time.
//
//  NOTE ON EXTRAPOLATION: the spec's velocity extrapolation is ANDROID-ONLY.
//  ARKit hands us the face pose in the same callback as the frame it belongs
//  to, already synchronised, so on iOS there is nothing to predict — predicting
//  a pose we already know exactly would only add overshoot.
//

import Foundation
import simd

/// One Euro filter: low cutoff when still (kills jitter), high cutoff when
/// moving (kills lag). The whole point is that a fixed low-pass cannot do both.
struct OneEuroFilter {
    var minCutoff: Float
    var beta: Float
    var dCutoff: Float = 1.0

    private var xPrev: Float = 0
    private var dxPrev: Float = 0
    private var hasPrev = false

    init(minCutoff: Float, beta: Float) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func reset() { hasPrev = false; xPrev = 0; dxPrev = 0 }

    mutating func filter(_ x: Float, dt: Float) -> Float {
        guard hasPrev, dt > 0 else {
            xPrev = x; dxPrev = 0; hasPrev = true
            return x
        }
        let dx = (x - xPrev) / dt
        let aD = alpha(cutoff: dCutoff, dt: dt)
        let edx = aD * dx + (1 - aD) * dxPrev
        let cutoff = minCutoff + beta * abs(edx)
        let a = alpha(cutoff: cutoff, dt: dt)
        let xHat = a * x + (1 - a) * xPrev
        xPrev = xHat; dxPrev = edx
        return xHat
    }
}

/// Critically-ish damped spring, integrated semi-implicitly.
///
/// Drives ear and hair bounce off head angular velocity. Sub-stepped at a fixed
/// rate so the bounce does not change character with frame rate — a spring
/// integrated at a variable dt is a spring with variable stiffness.
struct SpringState {
    private var pos: Float = 0
    private var vel: Float = 0
    private static let fixedStep: Float = 1.0 / 240.0

    mutating func reset() { pos = 0; vel = 0 }

    mutating func update(target: Float, dt: Float,
                         stiffness: Float = 160, damping: Float = 12) -> Float {
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            let h = min(Self.fixedStep, remaining)
            let force = -stiffness * (pos - target) - damping * vel
            vel += force * h
            pos += vel * h
            remaining -= h
        }
        return pos
    }
}

/// Smooths a head pose and the 52 blendshapes.
///
/// The matrix is decomposed to translation + quaternion + scale before
/// filtering: smoothing the sixteen matrix elements independently does not
/// preserve orthonormality, and the accumulated shear shows up as props that
/// subtly skew when the head turns.
struct PoseStabilizer {
    private var tx = OneEuroFilter(minCutoff: 1.8, beta: 0.02)
    private var ty = OneEuroFilter(minCutoff: 1.8, beta: 0.02)
    private var tz = OneEuroFilter(minCutoff: 1.8, beta: 0.02)
    private var blend: [OneEuroFilter]
    private var lastQuat = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))
    private var haveQuat = false
    private var lastTimeNanos: Int64 = 0
    private var lastEuler = SIMD3<Float>.zero

    /// Angular velocity in rad/s, for spring drivers. Not smoothed: the spring
    /// itself is the low-pass, and pre-smoothing the driver makes it mushy.
    private(set) var angularVelocity = SIMD3<Float>.zero

    init() {
        blend = (0..<FaceFrame.blendshapeCount).map { _ in
            OneEuroFilter(minCutoff: 3.2, beta: 0.22)
        }
    }

    mutating func reset() {
        tx.reset(); ty.reset(); tz.reset()
        for i in blend.indices { blend[i].reset() }
        haveQuat = false
        lastTimeNanos = 0
        angularVelocity = .zero
        lastEuler = .zero
    }

    /// Rotation smoothing is a slerp toward the new orientation rather than a
    /// One Euro on Euler angles, because Euler angles wrap and gimbal-lock and
    /// a filter across either discontinuity produces a violent flick.
    mutating func stabilize(_ frame: inout FaceFrame) {
        guard frame.valid else { reset(); return }

        let dt: Float
        if lastTimeNanos > 0 {
            dt = max(1.0 / 120.0, min(0.1, Float(frame.timestampNanos - lastTimeNanos) * 1e-9))
        } else {
            dt = 1.0 / 60.0
        }
        lastTimeNanos = frame.timestampNanos

        var m = frame.headMatrix
        let t = SIMD3<Float>(m[3].x, m[3].y, m[3].z)

        var basis = simd_float3x3(SIMD3(m[0].x, m[0].y, m[0].z),
                                  SIMD3(m[1].x, m[1].y, m[1].z),
                                  SIMD3(m[2].x, m[2].y, m[2].z))
        let scale = SIMD3<Float>(simd_length(basis[0]), simd_length(basis[1]), simd_length(basis[2]))
        for i in 0..<3 where scale[i] > 1e-6 { basis[i] /= scale[i] }

        var q = simd_quatf(basis)
        if haveQuat {
            // Shortest path: quaternions double-cover, so q and -q are the same
            // orientation and lerping to the far one spins the head the long way.
            if simd_dot(q.vector, lastQuat.vector) < 0 { q = simd_quatf(vector: -q.vector) }
            let responsiveness: Float = 1 - exp(-dt * 26.0)
            q = simd_slerp(lastQuat, q, responsiveness)

            let delta = q * lastQuat.inverse
            let angle = delta.angle
            if angle > 1e-5, dt > 0 {
                angularVelocity = simd_normalize(delta.axis) * (angle / dt)
            } else {
                angularVelocity = .zero
            }
        }
        lastQuat = q
        haveQuat = true

        let st = SIMD3<Float>(tx.filter(t.x, dt: dt),
                              ty.filter(t.y, dt: dt),
                              tz.filter(t.z, dt: dt))

        var r = simd_float3x3(q)
        for i in 0..<3 { r[i] *= scale[i] }
        m = simd_float4x4(SIMD4(r[0], 0), SIMD4(r[1], 0), SIMD4(r[2], 0), SIMD4(st, 1))
        frame.headMatrix = m

        for i in frame.blendshapes.indices where i < blend.count {
            frame.blendshapes[i] = blend[i].filter(frame.blendshapes[i], dt: dt)
        }
    }
}
