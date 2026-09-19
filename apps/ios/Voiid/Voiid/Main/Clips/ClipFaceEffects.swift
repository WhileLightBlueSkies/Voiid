//
//  ClipFaceEffects.swift
//  Voiid
//
//  Face-tracked camera effects — Snapchat-level 3D pose & depth tracking,
//  multi-layer anchor attachments, foreshortening, and rich vector art.
//

import Foundation
import CoreImage
import Vision
import UIKit
import AVFoundation

// MARK: - Effect catalogue

enum ClipFaceEffect: String, CaseIterable, Identifiable {
    case none
    case dog
    case tiger
    case party
    case cyber
    case bunny
    case koala
    case cat
    case sunglasses
    case crown
    case halo
    case devil

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:       return "None"
        case .dog:        return "Puppy"
        case .tiger:      return "Wildcat"
        case .party:      return "Party"
        case .cyber:      return "Cyber"
        case .bunny:      return "Bunny"
        case .koala:      return "Koala"
        case .cat:        return "Cat"
        case .sunglasses: return "Shades"
        case .crown:      return "Crown"
        case .halo:       return "Halo"
        case .devil:      return "Devil"
        }
    }

    /// Shown on the picker rail. A glyph, not a thumbnail.
    var symbol: String {
        switch self {
        case .none:       return "person"
        case .dog:        return "pawprint.fill"
        case .tiger:      return "cat.circle.fill"
        case .party:      return "sparkles"
        case .cyber:      return "eyeglasses"
        case .bunny:      return "hare.fill"
        case .koala:      return "teddybear.fill"
        case .cat:        return "cat.fill"
        case .sunglasses: return "sunglasses.fill"
        case .crown:      return "crown.fill"
        case .halo:       return "sun.max.fill"
        case .devil:      return "flame.fill"
        }
    }

    /// Ear/headwear palette, per effect.
    fileprivate var palette: (outer: UIColor, inner: UIColor, nose: UIColor) {
        switch self {
        case .none:
            return (.clear, .clear, .clear)
        case .dog:
            return (UIColor(red: 0.42, green: 0.28, blue: 0.18, alpha: 1),
                    UIColor(red: 0.85, green: 0.65, blue: 0.50, alpha: 1),
                    UIColor(red: 0.15, green: 0.12, blue: 0.11, alpha: 1))
        case .tiger:
            return (UIColor(red: 0.95, green: 0.56, blue: 0.12, alpha: 1),
                    UIColor(red: 0.16, green: 0.16, blue: 0.18, alpha: 1),
                    UIColor(red: 0.98, green: 0.62, blue: 0.70, alpha: 1))
        case .party:
            return (UIColor(red: 1.00, green: 0.82, blue: 0.15, alpha: 1),
                    UIColor(red: 1.00, green: 0.22, blue: 0.40, alpha: 1),
                    .clear)
        case .cyber:
            return (UIColor(red: 0.00, green: 0.94, blue: 1.00, alpha: 1),
                    UIColor(red: 1.00, green: 0.00, blue: 0.55, alpha: 0.85),
                    .clear)
        case .bunny:
            return (UIColor(red: 0.96, green: 0.94, blue: 0.94, alpha: 1),
                    UIColor(red: 0.98, green: 0.78, blue: 0.82, alpha: 1),
                    UIColor(red: 0.94, green: 0.55, blue: 0.62, alpha: 1))
        case .koala:
            return (UIColor(red: 0.55, green: 0.57, blue: 0.60, alpha: 1),
                    UIColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1),
                    UIColor(red: 0.20, green: 0.19, blue: 0.20, alpha: 1))
        case .cat:
            return (UIColor(red: 0.22, green: 0.22, blue: 0.24, alpha: 1),
                    UIColor(red: 0.98, green: 0.72, blue: 0.78, alpha: 1),
                    UIColor(red: 0.98, green: 0.58, blue: 0.68, alpha: 1))
        case .sunglasses:
            return (UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1),
                    UIColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 0.85),
                    .clear)
        case .crown:
            return (UIColor(red: 0.98, green: 0.78, blue: 0.12, alpha: 1),
                    UIColor(red: 0.88, green: 0.12, blue: 0.24, alpha: 1),
                    .clear)
        case .halo:
            return (UIColor(red: 1.00, green: 0.90, blue: 0.35, alpha: 0.95),
                    UIColor(red: 1.00, green: 0.96, blue: 0.70, alpha: 0.60),
                    .clear)
        case .devil:
            return (UIColor(red: 0.88, green: 0.12, blue: 0.15, alpha: 1),
                    UIColor(red: 1.00, green: 0.35, blue: 0.10, alpha: 1),
                    .clear)
        }
    }
}

// MARK: - Tracked face

/// One detected face, with full 3D head pose, expression action units, and feature anchors in CIImage space.
struct TrackedFace {
    let box: CGRect
    let eyeMid: CGPoint
    let eyeDistance: CGFloat
    let roll: CGFloat
    let yaw: CGFloat
    let pitch: CGFloat
    let nose: CGPoint
    let mouthMid: CGPoint
    let mouthOpenness: CGFloat // 0.0 (closed) to 1.0 (wide open)
    let smilingRatio: CGFloat  // 0.0 to 1.0
    let earWobble: CGFloat     // Spring inertia angle for bouncy ears/props
    let hasLandmarks: Bool
}

// MARK: - Physics & One Euro filter
//
// The filter and spring themselves now live in FaceFX/PoseStabilizer.swift, which the
// new face-filter engine shares. This file used to carry its own private copies; once
// PoseStabilizer landed they were duplicate declarations of the same two type names and
// nothing in the target compiled.
//
// The shared versions work in Float (what Metal and simd want) while everything on this
// older path is CGFloat, so these shims convert at the boundary rather than churning the
// ~20 call sites below. Keeping the shared implementation matters beyond deduplication:
// its spring integrates at a fixed 1/240s step, so bounce keeps its character when the
// frame rate drops, which the variable-dt spring that used to be here did not.

private struct CGSpring {
    private var inner = SpringState()
    mutating func update(target: CGFloat, dt: CGFloat,
                         stiffness: CGFloat = 160, damping: CGFloat = 12) -> CGFloat {
        CGFloat(inner.update(target: Float(target), dt: Float(dt),
                             stiffness: Float(stiffness), damping: Float(damping)))
    }
}

private struct CGOneEuro {
    private var inner: OneEuroFilter
    init(minCutoff: CGFloat, beta: CGFloat) {
        inner = OneEuroFilter(minCutoff: Float(minCutoff), beta: Float(beta))
    }
    mutating func filter(_ x: CGFloat, dt: CGFloat) -> CGFloat {
        CGFloat(inner.filter(Float(x), dt: Float(dt)))
    }
}

private struct FaceSmoother {
    var eyeMidX   = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var eyeMidY   = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var dist      = CGOneEuro(minCutoff: 1.8, beta: 0.02)
    var roll      = CGOneEuro(minCutoff: 2.5, beta: 0.15)
    var yaw       = CGOneEuro(minCutoff: 2.0, beta: 0.12)
    var pitch     = CGOneEuro(minCutoff: 2.0, beta: 0.12)
    var noseX     = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var noseY     = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var mouthMidX = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var mouthMidY = CGOneEuro(minCutoff: 2.2, beta: 0.04)
    var mouthOpen = CGOneEuro(minCutoff: 3.2, beta: 0.22)
    var smile     = CGOneEuro(minCutoff: 2.0, beta: 0.10)
    var earWobble = CGSpring()
}

// MARK: - Detector

final class ClipFaceDetector {

    private let queue = DispatchQueue(label: "voiid.clip.face", qos: .userInitiated)
    private let lock = NSLock()
    private var _latest: [TrackedFace] = []
    private var busy = false

    private var smoother = FaceSmoother()
    private var hadFace = false
    private var lastEyeMid: CGPoint = .zero
    private var lastPublish: CFTimeInterval = 0

    private static let copyContext = CIContext(options: [.cacheIntermediates: false])

    var latest: [TrackedFace] {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    func reset() {
        lock.lock()
        _latest = []
        smoother = FaceSmoother()
        hadFace = false
        lastPublish = 0
        lock.unlock()
    }

    func submit(_ pixels: CVPixelBuffer) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        guard let snapshot = Self.copy(pixels) else {
            lock.lock(); busy = false; lock.unlock()
            return
        }

        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            self.process(snapshot, width: width, height: height)
        }
    }

    private func process(_ buffer: CVPixelBuffer, width: CGFloat, height: CGFloat) {
        let request = VNDetectFaceLandmarksRequest()
        if let newest = VNDetectFaceLandmarksRequest.supportedRevisions.max() {
            request.revision = newest
            if VNDetectFaceLandmarksRequest.revision(
                newest, supportsConstellation: .constellation65Points) {
                request.constellation = .constellation65Points
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do { try handler.perform([request]) } catch { return }

        guard let face = (request.results ?? [])
            .max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            lock.lock(); _latest = []; hadFace = false; lock.unlock()
            return
        }

        let imageSize = CGSize(width: width, height: height)
        let box = CGRect(x: face.boundingBox.minX * width, y: face.boundingBox.minY * height,
                         width: face.boundingBox.width * width,
                         height: face.boundingBox.height * height)

        let left = centroid(face.landmarks?.leftEye, in: imageSize)
        let right = centroid(face.landmarks?.rightEye, in: imageSize)

        var eyeMid = CGPoint(x: box.midX, y: box.minY + box.height * 0.60)
        var eyeDistance = box.width * 0.46
        var roll = CGFloat(face.roll?.doubleValue ?? 0)
        var yaw = CGFloat(face.yaw?.doubleValue ?? 0)
        var pitch = CGFloat(face.pitch?.doubleValue ?? 0)
        var hasLandmarks = false

        if let l = left, let r = right {
            hasLandmarks = true
            eyeMid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            eyeDistance = max(1, hypot(r.x - l.x, r.y - l.y))
            // Landmark points: l is leftEye (user's right in mirror), r is rightEye (user's left in mirror).
            // Vector from l to r:
            let landmarkRoll = atan2(r.y - l.y, r.x - l.x)
            // Use Vision's face.roll as primary reference to avoid 180-degree phase inversions
            if let vRoll = face.roll?.doubleValue {
                roll = CGFloat(vRoll)
            } else {
                roll = landmarkRoll
            }

            // Calculate secondary yaw from eye asymmetry relative to nose for extra accuracy
            if let nosePoint = centroid(face.landmarks?.nose, in: imageSize) {
                let dL = abs(nosePoint.x - l.x)
                let dR = abs(nosePoint.x - r.x)
                let total = dL + dR
                if total > 5 {
                    let eyeRatio = (dR - dL) / total
                    if abs(yaw) < 0.05 {
                        yaw = min(0.60, max(-0.60, eyeRatio * 0.50))
                    }
                }
            }
        }

        let nose = centroid(face.landmarks?.nose, in: imageSize)
            ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.42)

        var mouthMid = CGPoint(x: box.midX, y: box.minY + box.height * 0.28)
        var rawMouthOpen: CGFloat = 0
        var rawSmile: CGFloat = 0

        if let innerLips = face.landmarks?.innerLips, innerLips.pointCount >= 4 {
            let pts = innerLips.pointsInImage(imageSize: imageSize)
            if !pts.isEmpty {
                let minY = pts.map(\.y).min() ?? 0
                let maxY = pts.map(\.y).max() ?? 0
                let mouthH = max(0, maxY - minY)
                rawMouthOpen = min(1.0, max(0.0, (mouthH / (eyeDistance * 0.40) - 0.08) / 0.38))
                let avgX = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
                let avgY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
                mouthMid = CGPoint(x: avgX, y: avgY)
            }
        } else if let outerLips = face.landmarks?.outerLips, outerLips.pointCount >= 4 {
            let pts = outerLips.pointsInImage(imageSize: imageSize)
            if !pts.isEmpty {
                let minY = pts.map(\.y).min() ?? 0
                let maxY = pts.map(\.y).max() ?? 0
                let mouthH = max(0, maxY - minY)
                rawMouthOpen = min(1.0, max(0.0, (mouthH / (eyeDistance * 0.44) - 0.12) / 0.40))
                let avgX = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
                let avgY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
                mouthMid = CGPoint(x: avgX, y: avgY)
            }
        }

        if let outerLips = face.landmarks?.outerLips, outerLips.pointCount >= 6 {
            let pts = outerLips.pointsInImage(imageSize: imageSize)
            if pts.count >= 6 {
                let sortedX = pts.sorted(by: { $0.x < $1.x })
                if let leftC = sortedX.first, let rightC = sortedX.last {
                    let cornerAvgY = (leftC.y + rightC.y) / 2
                    let centerLipY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
                    let smileDelta = cornerAvgY - centerLipY
                    rawSmile = min(1.0, max(0.0, (smileDelta / (eyeDistance * 0.12) + 0.15) / 0.50))
                }
            }
        }

        publish(box: box, eyeMid: eyeMid, eyeDistance: eyeDistance, roll: roll,
                yaw: yaw, pitch: pitch, nose: nose, mouthMid: mouthMid,
                mouthOpenness: rawMouthOpen, smilingRatio: rawSmile, hasLandmarks: hasLandmarks)
    }

    private func centroid(_ region: VNFaceLandmarkRegion2D?,
                          in imageSize: CGSize) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.pointsInImage(imageSize: imageSize)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    private var lastDistance: CGFloat = 0
    private var lastRoll: CGFloat = 0

    private func publish(box: CGRect, eyeMid: CGPoint, eyeDistance: CGFloat, roll: CGFloat,
                         yaw: CGFloat, pitch: CGFloat, nose: CGPoint, mouthMid: CGPoint,
                         mouthOpenness: CGFloat, smilingRatio: CGFloat, hasLandmarks: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        let dt = min(0.1, max(1.0 / 60.0, hadFace ? now - lastPublish : 1.0 / 30.0))
        lastPublish = now

        let posJump = hypot(eyeMid.x - lastEyeMid.x, eyeMid.y - lastEyeMid.y) > max(eyeDistance * 1.2, 120)
        let scaleJump = lastDistance > 0 && abs(eyeDistance - lastDistance) / lastDistance > 0.40

        if !hadFace || posJump || scaleJump {
            smoother = FaceSmoother()
        }
        hadFace = true
        lastEyeMid = eyeMid
        lastDistance = eyeDistance

        let rollVelocity = (roll - lastRoll) / CGFloat(dt)
        lastRoll = roll
        let wobble = smoother.earWobble.update(target: -rollVelocity * 0.08, dt: dt)

        let smoothed = TrackedFace(
            box: box,
            eyeMid: CGPoint(x: smoother.eyeMidX.filter(eyeMid.x, dt: dt),
                            y: smoother.eyeMidY.filter(eyeMid.y, dt: dt)),
            eyeDistance: smoother.dist.filter(eyeDistance, dt: dt),
            roll: smoother.roll.filter(roll, dt: dt),
            yaw: smoother.yaw.filter(yaw, dt: dt),
            pitch: smoother.pitch.filter(pitch, dt: dt),
            nose: CGPoint(x: smoother.noseX.filter(nose.x, dt: dt),
                          y: smoother.noseY.filter(nose.y, dt: dt)),
            mouthMid: CGPoint(x: smoother.mouthMidX.filter(mouthMid.x, dt: dt),
                              y: smoother.mouthMidY.filter(mouthMid.y, dt: dt)),
            mouthOpenness: smoother.mouthOpen.filter(mouthOpenness, dt: dt),
            smilingRatio: smoother.smile.filter(smilingRatio, dt: dt),
            earWobble: wobble,
            hasLandmarks: hasLandmarks)
        _latest = [smoothed]
        lock.unlock()
    }

    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        // Use 720px ceiling instead of 480px for significantly sharper landmark resolution on zoomed faces
        let scale = min(1.0, 720.0 / CGFloat(max(sw, sh)))
        let w = Int((CGFloat(sw) * scale).rounded())
        let h = Int((CGFloat(sh) * scale).rounded())
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        guard CVPixelBufferCreate(nil, w, h, kCVPixelFormatType_32BGRA,
                                  attrs as CFDictionary, &out) == kCVReturnSuccess,
              let dest = out else { return nil }
        let image = CIImage(cvPixelBuffer: source)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        copyContext.render(image, to: dest)
        return dest
    }
}

// MARK: - Renderer

enum ClipFaceRenderer {

    private static var cache: [String: CIImage] = [:]
    private static let cacheLock = NSLock()
    private static let referenceSprite: CGFloat = 512

    // Placement configurations per filter
    private struct Config {
        let headSpan: CGFloat
        let crownRise: CGFloat
        let noseSpan: CGFloat
        let hasNoseSprite: Bool
        let hasFaceDetails: Bool
        let isEyewear: Bool
        let hasReactiveMouth: Bool
    }

    private static func config(for effect: ClipFaceEffect) -> Config {
        switch effect {
        case .none:
            return Config(headSpan: 0, crownRise: 0, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: false, isEyewear: false, hasReactiveMouth: false)
        case .dog:
            return Config(headSpan: 2.9, crownRise: 1.28, noseSpan: 0.58, hasNoseSprite: true, hasFaceDetails: false, isEyewear: false, hasReactiveMouth: true)
        case .tiger:
            return Config(headSpan: 2.8, crownRise: 1.22, noseSpan: 0.54, hasNoseSprite: true, hasFaceDetails: true, isEyewear: false, hasReactiveMouth: true)
        case .party:
            return Config(headSpan: 2.3, crownRise: 1.62, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: true, isEyewear: false, hasReactiveMouth: true)
        case .cyber:
            return Config(headSpan: 2.45, crownRise: 0.0, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: true, isEyewear: true, hasReactiveMouth: false)
        case .bunny:
            return Config(headSpan: 2.7, crownRise: 1.35, noseSpan: 0.44, hasNoseSprite: true, hasFaceDetails: true, isEyewear: false, hasReactiveMouth: false)
        case .koala:
            return Config(headSpan: 3.0, crownRise: 1.15, noseSpan: 0.62, hasNoseSprite: true, hasFaceDetails: false, isEyewear: false, hasReactiveMouth: false)
        case .cat:
            return Config(headSpan: 2.5, crownRise: 1.25, noseSpan: 0.38, hasNoseSprite: true, hasFaceDetails: true, isEyewear: false, hasReactiveMouth: false)
        case .sunglasses:
            return Config(headSpan: 2.35, crownRise: 0.0, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: false, isEyewear: true, hasReactiveMouth: false)
        case .crown:
            return Config(headSpan: 2.4, crownRise: 1.45, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: false, isEyewear: false, hasReactiveMouth: false)
        case .halo:
            return Config(headSpan: 2.7, crownRise: 1.85, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: false, isEyewear: false, hasReactiveMouth: false)
        case .devil:
            return Config(headSpan: 2.4, crownRise: 1.30, noseSpan: 0, hasNoseSprite: false, hasFaceDetails: true, isEyewear: false, hasReactiveMouth: false)
        }
    }

    static func apply(_ effect: ClipFaceEffect, to image: CIImage,
                      faces: [TrackedFace]) -> CIImage {
        guard effect != .none, !faces.isEmpty else { return image }

        var output = image
        let cfg = config(for: effect)
        let frameHeight = max(image.extent.height, 1)

        for face in faces {
            let projectedD = face.hasLandmarks ? face.eyeDistance : face.box.width * 0.46
            guard projectedD > 8 else { continue }

            // Un-project interocular distance gently so head turns do NOT cause sprite to shrink
            let cosYaw = max(0.60, cos(face.yaw))
            let D = projectedD / cosYaw

            // When face is zoomed in, dampen 3D perspective translations
            let faceZoomFraction = min(1.0, max(0.0, (D / frameHeight - 0.12) / 0.25))
            let offsetDamping = 1.0 - (0.55 * faceZoomFraction)

            // 3D Directional basis vectors
            let up = CGVector(dx: -sin(face.roll), dy: cos(face.roll))
            let right = CGVector(dx: cos(face.roll), dy: sin(face.roll))

            // 1. Primary Sprite (Headwear / Ears / Sunglasses / Visor)
            if let mainSprite = sprite(for: effect) {
                let spriteSide = D * cfg.headSpan
                let baseScale = spriteSide / referenceSprite

                let pitchOffset = (D * sin(face.pitch) * 0.35) * offsetDamping
                let yawOffset = (D * sin(face.yaw) * 0.30) * offsetDamping

                var anchorPoint: CGPoint
                if cfg.isEyewear {
                    // Sunglasses / Cyber Visor sit right on the eye line / nose bridge
                    anchorPoint = CGPoint(
                        x: face.eyeMid.x + up.dx * (D * cfg.crownRise + pitchOffset * 0.2) + right.dx * yawOffset,
                        y: face.eyeMid.y + up.dy * (D * cfg.crownRise + pitchOffset * 0.2) + right.dy * yawOffset
                    )
                } else {
                    // Headwear / Ears sit on the crown of the skull
                    anchorPoint = face.hasLandmarks
                        ? CGPoint(x: face.eyeMid.x + up.dx * (D * cfg.crownRise + pitchOffset) + right.dx * yawOffset,
                                  y: face.eyeMid.y + up.dy * (D * cfg.crownRise + pitchOffset) + right.dy * yawOffset)
                        : CGPoint(x: face.box.midX + right.dx * yawOffset,
                                  y: face.box.maxY + face.box.height * 0.10 + up.dy * pitchOffset)
                }

                // Halo floating hover bobbing
                if effect == .halo {
                    let haloBob = sin(CFAbsoluteTimeGetCurrent() * 4.0) * (D * 0.05)
                    anchorPoint = CGPoint(x: anchorPoint.x + up.dx * haloBob, y: anchorPoint.y + up.dy * haloBob)
                }

                // 3D perspective foreshortening
                let scaleX = baseScale * max(0.70, cosYaw)
                let scaleY = baseScale * max(0.75, cos(face.pitch * 0.6))
                let skewX = tan(face.yaw * 0.18) * offsetDamping

                var t = CGAffineTransform(translationX: anchorPoint.x, y: anchorPoint.y)
                let wobbleAngle = (effect == .dog || effect == .bunny || effect == .tiger || effect == .cat || effect == .koala)
                    ? face.earWobble
                    : 0
                t = t.rotated(by: face.roll + wobbleAngle)
                if abs(face.yaw) > 0.05 {
                    t = t.concatenating(CGAffineTransform(a: 1, b: 0, c: skewX, d: 1, tx: 0, ty: 0))
                }
                t = t.scaledBy(x: scaleX, y: scaleY)
                t = t.translatedBy(x: -referenceSprite / 2, y: -referenceSprite / 2)

                let placed = mainSprite.transformed(by: t)
                output = placed.composited(over: output)
            }

            // 2. Nose Sprite (Snout / Pink Cat / Tiger Nose)
            if cfg.hasNoseSprite, let nSprite = noseSprite(for: effect) {
                let noseSide = D * cfg.noseSpan
                let noseScale = noseSide / referenceSprite

                let noseYawShift = (D * sin(face.yaw) * 0.18) * offsetDamping
                let nosePitchShift = (-D * sin(face.pitch) * 0.18) * offsetDamping

                let nAnchor = CGPoint(
                    x: face.nose.x + right.dx * noseYawShift + up.dx * nosePitchShift,
                    y: face.nose.y + right.dy * noseYawShift + up.dy * nosePitchShift
                )

                var nt = CGAffineTransform(translationX: nAnchor.x, y: nAnchor.y)
                nt = nt.rotated(by: face.roll)
                nt = nt.scaledBy(x: noseScale * max(0.70, cosYaw), y: noseScale)
                nt = nt.translatedBy(x: -referenceSprite / 2, y: -referenceSprite / 2)

                let placedNose = nSprite.transformed(by: nt)
                output = placedNose.composited(over: output)
            }

            // 3. Face Details (Whiskers, Blush cheeks, Tiger stripes, Cyber HUD)
            if cfg.hasFaceDetails, let detailsSprite = faceDetailsSprite(for: effect) {
                let detailSide = D * 2.1
                let dScale = detailSide / referenceSprite

                var dt = CGAffineTransform(translationX: face.nose.x, y: face.nose.y)
                dt = dt.rotated(by: face.roll)
                dt = dt.scaledBy(x: dScale * max(0.70, cosYaw), y: dScale)
                dt = dt.translatedBy(x: -referenceSprite / 2, y: -referenceSprite / 2)

                let placedDetails = detailsSprite.transformed(by: dt)
                output = placedDetails.composited(over: output)
            }

            // 4. Reactive Mouth Action Trigger (Tongue, Fangs, Confetti)
            if cfg.hasReactiveMouth {
                if effect == .dog, face.mouthOpenness > 0.15, let tongue = dogTongueSprite() {
                    let openProg = min(1.0, (face.mouthOpenness - 0.15) / 0.45)
                    let tongueH = D * 0.90 * openProg
                    let tongueW = D * 0.55
                    let tongueScaleX = tongueW / referenceSprite
                    let tongueScaleY = tongueH / referenceSprite

                    let mouthOffset = -up.dy * (D * 0.08)
                    let mAnchor = CGPoint(
                        x: face.mouthMid.x + up.dx * mouthOffset + right.dx * (D * sin(face.yaw) * 0.15),
                        y: face.mouthMid.y + up.dy * mouthOffset + right.dy * (D * sin(face.yaw) * 0.15)
                    )

                    var mt = CGAffineTransform(translationX: mAnchor.x, y: mAnchor.y)
                    mt = mt.rotated(by: face.roll + face.earWobble * 0.3)
                    mt = mt.scaledBy(x: tongueScaleX * max(0.70, cosYaw), y: tongueScaleY)
                    mt = mt.translatedBy(x: -referenceSprite / 2, y: 0)

                    let placedTongue = tongue.transformed(by: mt)
                    output = placedTongue.composited(over: output)
                } else if effect == .tiger, face.mouthOpenness > 0.18, let fangs = tigerFangsSprite() {
                    let openProg = min(1.0, (face.mouthOpenness - 0.18) / 0.40)
                    let fangsH = D * 0.52 * openProg
                    let fangsW = D * 0.65
                    let fScaleX = fangsW / referenceSprite
                    let fScaleY = fangsH / referenceSprite

                    let mAnchor = CGPoint(
                        x: face.mouthMid.x + right.dx * (D * sin(face.yaw) * 0.12),
                        y: face.mouthMid.y + right.dy * (D * sin(face.yaw) * 0.12)
                    )

                    var mt = CGAffineTransform(translationX: mAnchor.x, y: mAnchor.y)
                    mt = mt.rotated(by: face.roll)
                    mt = mt.scaledBy(x: fScaleX * max(0.70, cosYaw), y: fScaleY)
                    mt = mt.translatedBy(x: -referenceSprite / 2, y: -referenceSprite * 0.15)

                    let placedFangs = fangs.transformed(by: mt)
                    output = placedFangs.composited(over: output)
                } else if effect == .party, (face.mouthOpenness > 0.22 || face.smilingRatio > 0.40), let confetti = partyConfettiSprite() {
                    let burstIntensity = max(face.mouthOpenness, face.smilingRatio)
                    let burstSide = D * (2.2 + burstIntensity * 1.0)
                    let bScale = burstSide / referenceSprite

                    var pt = CGAffineTransform(translationX: face.mouthMid.x, y: face.mouthMid.y)
                    pt = pt.rotated(by: face.roll)
                    pt = pt.scaledBy(x: bScale, y: bScale)
                    pt = pt.translatedBy(x: -referenceSprite / 2, y: -referenceSprite / 2)

                    let placedConfetti = confetti.transformed(by: pt)
                    output = placedConfetti.composited(over: output)
                }
            }
        }
        return output
    }

    // MARK: - Sprite Construction & Caching

    private static func sprite(for effect: ClipFaceEffect) -> CIImage? {
        let key = "\(effect.rawValue)-main"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            drawMain(effect, in: ctx.cgContext, size: size)
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)

        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func noseSprite(for effect: ClipFaceEffect) -> CIImage? {
        let key = "\(effect.rawValue)-nose"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let colours = effect.palette
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            c.saveGState()

            let path = UIBezierPath()
            if effect == .cat || effect == .tiger {
                // Heart-like feline nose
                path.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.85))
                path.addCurve(to: CGPoint(x: size.width * 0.20, y: size.height * 0.35),
                              controlPoint1: CGPoint(x: size.width * 0.35, y: size.height * 0.80),
                              controlPoint2: CGPoint(x: size.width * 0.15, y: size.height * 0.55))
                path.addCurve(to: CGPoint(x: size.width * 0.80, y: size.height * 0.35),
                              controlPoint1: CGPoint(x: size.width * 0.25, y: size.height * 0.20),
                              controlPoint2: CGPoint(x: size.width * 0.75, y: size.height * 0.20))
                path.addCurve(to: CGPoint(x: size.width * 0.5, y: size.height * 0.85),
                              controlPoint1: CGPoint(x: size.width * 0.85, y: size.height * 0.55),
                              controlPoint2: CGPoint(x: size.width * 0.65, y: size.height * 0.80))
                path.close()

                c.setFillColor(colours.nose.cgColor)
                c.addPath(path.cgPath)
                c.fillPath()

                // Highlight shine
                c.setFillColor(UIColor.white.withAlphaComponent(0.4).cgColor)
                c.fillEllipse(in: CGRect(x: size.width * 0.35, y: size.height * 0.32,
                                         width: size.width * 0.15, height: size.height * 0.10))
            } else {
                // Dog / Bunny / Koala snout
                path.move(to: CGPoint(x: size.width * 0.5, y: size.height * 0.95))
                path.addCurve(to: CGPoint(x: size.width * 0.05, y: size.height * 0.30),
                              controlPoint1: CGPoint(x: size.width * 0.20, y: size.height * 0.90),
                              controlPoint2: CGPoint(x: size.width * 0.02, y: size.height * 0.55))
                path.addCurve(to: CGPoint(x: size.width * 0.95, y: size.height * 0.30),
                              controlPoint1: CGPoint(x: size.width * 0.10, y: size.height * 0.02),
                              controlPoint2: CGPoint(x: size.width * 0.90, y: size.height * 0.02))
                path.addCurve(to: CGPoint(x: size.width * 0.5, y: size.height * 0.95),
                              controlPoint1: CGPoint(x: size.width * 0.98, y: size.height * 0.55),
                              controlPoint2: CGPoint(x: size.width * 0.80, y: size.height * 0.90))
                path.close()

                c.setFillColor(colours.nose.cgColor)
                c.addPath(path.cgPath)
                c.fillPath()

                // Specular highlight
                c.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
                c.fillEllipse(in: CGRect(x: size.width * 0.28, y: size.height * 0.20,
                                         width: size.width * 0.22, height: size.height * 0.14))
            }
            c.restoreGState()
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)

        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func dogTongueSprite() -> CIImage? {
        let key = "dog-tongue"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height

            let tongue = UIBezierPath()
            tongue.move(to: CGPoint(x: w * 0.25, y: h * 0.02))
            tongue.addLine(to: CGPoint(x: w * 0.22, y: h * 0.70))
            tongue.addCurve(to: CGPoint(x: w * 0.78, y: h * 0.70),
                            controlPoint1: CGPoint(x: w * 0.22, y: h * 0.98),
                            controlPoint2: CGPoint(x: w * 0.78, y: h * 0.98))
            tongue.addLine(to: CGPoint(x: w * 0.75, y: h * 0.02))
            tongue.close()

            c.setFillColor(UIColor(red: 1.0, green: 0.44, blue: 0.58, alpha: 1.0).cgColor)
            c.addPath(tongue.cgPath)
            c.fillPath()

            c.setStrokeColor(UIColor(red: 0.82, green: 0.20, blue: 0.36, alpha: 0.80).cgColor)
            c.setLineWidth(10.0)
            c.setLineCap(.round)
            c.move(to: CGPoint(x: w * 0.50, y: h * 0.10))
            c.addLine(to: CGPoint(x: w * 0.50, y: h * 0.68))
            c.strokePath()

            c.setFillColor(UIColor.white.withAlphaComponent(0.40).cgColor)
            c.fillEllipse(in: CGRect(x: w * 0.30, y: h * 0.30, width: w * 0.14, height: h * 0.28))
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func tigerFangsSprite() -> CIImage? {
        let key = "tiger-fangs"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height

            func fang(xCenter: CGFloat, flipped: Bool) {
                let p = UIBezierPath()
                let dx: CGFloat = flipped ? -1 : 1
                p.move(to: CGPoint(x: xCenter - 30 * dx, y: h * 0.10))
                p.addCurve(to: CGPoint(x: xCenter + 6 * dx, y: h * 0.88),
                           controlPoint1: CGPoint(x: xCenter - 15 * dx, y: h * 0.45),
                           controlPoint2: CGPoint(x: xCenter - 6 * dx, y: h * 0.70))
                p.addCurve(to: CGPoint(x: xCenter + 30 * dx, y: h * 0.10),
                           controlPoint1: CGPoint(x: xCenter + 15 * dx, y: h * 0.65),
                           controlPoint2: CGPoint(x: xCenter + 25 * dx, y: h * 0.35))
                p.close()

                c.setFillColor(UIColor.white.cgColor)
                c.addPath(p.cgPath)
                c.fillPath()

                c.setStrokeColor(UIColor(white: 0.2, alpha: 0.4).cgColor)
                c.setLineWidth(4.0)
                c.addPath(p.cgPath)
                c.strokePath()

                c.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                c.setLineWidth(3.0)
                c.move(to: CGPoint(x: xCenter - 4 * dx, y: h * 0.20))
                c.addLine(to: CGPoint(x: xCenter + 2 * dx, y: h * 0.75))
                c.strokePath()
            }

            fang(xCenter: w * 0.32, flipped: false)
            fang(xCenter: w * 0.68, flipped: true)
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func partyConfettiSprite() -> CIImage? {
        let key = "party-confetti"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height

            let colors: [UIColor] = [
                UIColor(red: 1.0, green: 0.85, blue: 0.15, alpha: 0.95), // Gold
                UIColor(red: 1.0, green: 0.25, blue: 0.45, alpha: 0.95), // Coral
                UIColor(red: 0.20, green: 0.85, blue: 1.0, alpha: 0.95), // Cyan
                UIColor(red: 0.65, green: 0.30, blue: 1.0, alpha: 0.95), // Violet
                UIColor(red: 0.30, green: 0.95, blue: 0.55, alpha: 0.95)  // Mint
            ]

            let pieces: [(x: CGFloat, y: CGFloat, r: CGFloat, rot: CGFloat, c: Int, isStar: Bool)] = [
                (0.20, 0.25, 24, 0.3, 0, true),
                (0.80, 0.22, 28, -0.4, 1, true),
                (0.12, 0.60, 20, 0.8, 2, false),
                (0.88, 0.55, 22, -0.7, 3, false),
                (0.35, 0.12, 26, 0.1, 4, true),
                (0.65, 0.10, 22, -0.2, 0, false),
                (0.25, 0.82, 18, 0.5, 1, false),
                (0.75, 0.85, 20, -0.6, 2, true),
                (0.08, 0.38, 16, 1.2, 3, false),
                (0.92, 0.35, 18, -1.1, 4, true),
                (0.40, 0.92, 22, 0.4, 0, true),
                (0.60, 0.94, 20, -0.3, 1, false)
            ]

            for p in pieces {
                c.saveGState()
                c.translateBy(x: w * p.x, y: h * p.y)
                c.rotate(by: p.rot)
                c.setFillColor(colors[p.c % colors.count].cgColor)

                if p.isStar {
                    let sp = UIBezierPath()
                    let r = p.r
                    sp.move(to: CGPoint(x: 0, y: -r))
                    sp.addQuadCurve(to: CGPoint(x: r, y: 0), controlPoint: CGPoint(x: r * 0.2, y: -r * 0.2))
                    sp.addQuadCurve(to: CGPoint(x: 0, y: r), controlPoint: CGPoint(x: r * 0.2, y: r * 0.2))
                    sp.addQuadCurve(to: CGPoint(x: -r, y: 0), controlPoint: CGPoint(x: -r * 0.2, y: r * 0.2))
                    sp.addQuadCurve(to: CGPoint(x: 0, y: -r), controlPoint: CGPoint(x: -r * 0.2, y: -r * 0.2))
                    sp.close()
                    c.addPath(sp.cgPath)
                    c.fillPath()
                } else {
                    let rect = CGRect(x: -p.r * 0.5, y: -p.r, width: p.r, height: p.r * 2)
                    let dp = UIBezierPath(roundedRect: rect, cornerRadius: 4)
                    c.addPath(dp.cgPath)
                    c.fillPath()
                }
                c.restoreGState()
            }
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)
        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func faceDetailsSprite(for effect: ClipFaceEffect) -> CIImage? {
        let key = "\(effect.rawValue)-details"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            let w = size.width, h = size.height

            if effect == .cat {
                // Soft pink blush on cheeks
                c.saveGState()
                let blushColor = UIColor(red: 1.0, green: 0.45, blue: 0.60, alpha: 0.32).cgColor
                c.setFillColor(blushColor)
                c.fillEllipse(in: CGRect(x: w * 0.08, y: h * 0.42, width: w * 0.24, height: h * 0.16))
                c.fillEllipse(in: CGRect(x: w * 0.68, y: h * 0.42, width: w * 0.24, height: h * 0.16))

                // Delicate whiskers
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                c.setLineWidth(4.0)
                c.setLineCap(.round)

                // Left whiskers
                c.move(to: CGPoint(x: w * 0.32, y: h * 0.48))
                c.addQuadCurve(to: CGPoint(x: w * 0.02, y: h * 0.42), control: CGPoint(x: w * 0.16, y: h * 0.44))
                c.move(to: CGPoint(x: w * 0.30, y: h * 0.55))
                c.addQuadCurve(to: CGPoint(x: w * 0.04, y: h * 0.58), control: CGPoint(x: w * 0.15, y: h * 0.56))
                c.move(to: CGPoint(x: w * 0.32, y: h * 0.62))
                c.addQuadCurve(to: CGPoint(x: w * 0.08, y: h * 0.72), control: CGPoint(x: w * 0.18, y: h * 0.68))

                // Right whiskers
                c.move(to: CGPoint(x: w * 0.68, y: h * 0.48))
                c.addQuadCurve(to: CGPoint(x: w * 0.98, y: h * 0.42), control: CGPoint(x: w * 0.84, y: h * 0.44))
                c.move(to: CGPoint(x: w * 0.70, y: h * 0.55))
                c.addQuadCurve(to: CGPoint(x: w * 0.96, y: h * 0.58), control: CGPoint(x: w * 0.85, y: h * 0.56))
                c.move(to: CGPoint(x: w * 0.68, y: h * 0.62))
                c.addQuadCurve(to: CGPoint(x: w * 0.92, y: h * 0.72), control: CGPoint(x: w * 0.82, y: h * 0.68))

                c.strokePath()
                c.restoreGState()
            } else if effect == .bunny {
                // Soft pastel blush for bunny
                c.saveGState()
                let blushColor = UIColor(red: 1.0, green: 0.55, blue: 0.65, alpha: 0.35).cgColor
                c.setFillColor(blushColor)
                c.fillEllipse(in: CGRect(x: w * 0.12, y: h * 0.45, width: w * 0.22, height: h * 0.15))
                c.fillEllipse(in: CGRect(x: w * 0.66, y: h * 0.45, width: w * 0.22, height: h * 0.15))
                c.restoreGState()
            } else if effect == .tiger {
                // Tiger cheek stripes & fierce whiskers
                c.saveGState()
                c.setFillColor(UIColor(red: 0.14, green: 0.14, blue: 0.16, alpha: 0.90).cgColor)

                func stripe(startX: CGFloat, startY: CGFloat, endX: CGFloat, endY: CGFloat, thickness: CGFloat) {
                    let sp = UIBezierPath()
                    sp.move(to: CGPoint(x: startX, y: startY))
                    sp.addQuadCurve(to: CGPoint(x: endX, y: endY),
                                    controlPoint: CGPoint(x: (startX + endX) / 2, y: (startY + endY) / 2 + 8))
                    sp.addQuadCurve(to: CGPoint(x: startX, y: startY + thickness),
                                    controlPoint: CGPoint(x: (startX + endX) / 2, y: (startY + endY) / 2 + 12))
                    sp.close()
                    c.addPath(sp.cgPath)
                    c.fillPath()
                }

                // Left cheek stripes
                stripe(startX: w * 0.04, startY: h * 0.40, endX: w * 0.25, endY: h * 0.46, thickness: 12)
                stripe(startX: w * 0.06, startY: h * 0.52, endX: w * 0.26, endY: h * 0.56, thickness: 10)
                stripe(startX: w * 0.08, startY: h * 0.64, endX: w * 0.24, endY: h * 0.66, thickness: 9)

                // Right cheek stripes
                stripe(startX: w * 0.96, startY: h * 0.40, endX: w * 0.75, endY: h * 0.46, thickness: 12)
                stripe(startX: w * 0.94, startY: h * 0.52, endX: w * 0.74, endY: h * 0.56, thickness: 10)
                stripe(startX: w * 0.92, startY: h * 0.64, endX: w * 0.76, endY: h * 0.66, thickness: 9)

                // White whiskers
                c.setStrokeColor(UIColor.white.withAlphaComponent(0.90).cgColor)
                c.setLineWidth(3.5)
                c.setLineCap(.round)

                c.move(to: CGPoint(x: w * 0.30, y: h * 0.50))
                c.addLine(to: CGPoint(x: w * 0.02, y: h * 0.48))
                c.move(to: CGPoint(x: w * 0.29, y: h * 0.58))
                c.addLine(to: CGPoint(x: w * 0.04, y: h * 0.62))

                c.move(to: CGPoint(x: w * 0.70, y: h * 0.50))
                c.addLine(to: CGPoint(x: w * 0.98, y: h * 0.48))
                c.move(to: CGPoint(x: w * 0.71, y: h * 0.58))
                c.addLine(to: CGPoint(x: w * 0.96, y: h * 0.62))

                c.strokePath()
                c.restoreGState()
            } else if effect == .party {
                // Gold and magenta sparkles on cheeks
                c.saveGState()
                let gold = UIColor(red: 1.0, green: 0.82, blue: 0.15, alpha: 0.9).cgColor
                c.setFillColor(gold)
                c.fillEllipse(in: CGRect(x: w * 0.16, y: h * 0.48, width: 14, height: 14))
                c.fillEllipse(in: CGRect(x: w * 0.24, y: h * 0.42, width: 10, height: 10))
                c.fillEllipse(in: CGRect(x: w * 0.80, y: h * 0.48, width: 14, height: 14))
                c.fillEllipse(in: CGRect(x: w * 0.72, y: h * 0.42, width: 10, height: 10))
                c.restoreGState()
            } else if effect == .cyber {
                // Cyberpunk HUD telemetry and cheek nodes
                c.saveGState()
                c.setStrokeColor(UIColor(red: 0.0, green: 0.94, blue: 1.0, alpha: 0.85).cgColor)
                c.setLineWidth(2.5)

                // Left cheek HUD bracket
                c.move(to: CGPoint(x: w * 0.12, y: h * 0.42))
                c.addLine(to: CGPoint(x: w * 0.18, y: h * 0.42))
                c.addLine(to: CGPoint(x: w * 0.22, y: h * 0.55))
                c.strokePath()

                // Right cheek HUD bracket
                c.move(to: CGPoint(x: w * 0.88, y: h * 0.42))
                c.addLine(to: CGPoint(x: w * 0.82, y: h * 0.42))
                c.addLine(to: CGPoint(x: w * 0.78, y: h * 0.55))
                c.strokePath()

                // Glowing node dots
                c.setFillColor(UIColor(red: 1.0, green: 0.0, blue: 0.55, alpha: 0.9).cgColor)
                c.fillEllipse(in: CGRect(x: w * 0.21, y: h * 0.54, width: 6, height: 6))
                c.fillEllipse(in: CGRect(x: w * 0.77, y: h * 0.54, width: 6, height: 6))

                c.restoreGState()
            } else if effect == .devil {
                // Glowing crimson cheek embers
                c.saveGState()
                c.setFillColor(UIColor(red: 1.0, green: 0.30, blue: 0.10, alpha: 0.6).cgColor)
                c.fillEllipse(in: CGRect(x: w * 0.16, y: h * 0.44, width: 12, height: 12))
                c.fillEllipse(in: CGRect(x: w * 0.80, y: h * 0.44, width: 12, height: 12))
                c.restoreGState()
            }
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg)

        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    // MARK: - Drawing Vector Artwork

    private static func drawMain(_ effect: ClipFaceEffect, in c: CGContext, size: CGSize) {
        let colours = effect.palette
        let w = size.width, h = size.height

        switch effect {
        case .none:
            break

        case .dog, .bunny, .koala, .cat, .tiger:
            drawAnimalEars(effect, in: c, size: size)

        case .sunglasses:
            drawSunglasses(in: c, size: size, colors: colours)

        case .crown:
            drawCrown(in: c, size: size, colors: colours)

        case .halo:
            drawHalo(in: c, size: size, colors: colours)

        case .devil:
            drawDevilHorns(in: c, size: size, colors: colours)

        case .party:
            drawPartyHat(in: c, size: size, colors: colours)

        case .cyber:
            drawCyberVisor(in: c, size: size, colors: colours)
        }
    }

    private static func drawAnimalEars(_ effect: ClipFaceEffect, in c: CGContext, size: CGSize) {
        let colours = effect.palette
        let w = size.width, h = size.height

        func ear(flipped: Bool) {
            c.saveGState()
            if flipped {
                c.translateBy(x: w, y: 0)
                c.scaleBy(x: -1, y: 1)
            }

            let outer = UIBezierPath()
            let inner = UIBezierPath()

            switch effect {
            case .dog:
                // Floppy dog ear
                outer.move(to: CGPoint(x: w * 0.36, y: h * 0.40))
                outer.addCurve(to: CGPoint(x: w * 0.07, y: h * 0.72),
                               controlPoint1: CGPoint(x: w * 0.19, y: h * 0.42),
                               controlPoint2: CGPoint(x: w * 0.06, y: h * 0.58))
                outer.addCurve(to: CGPoint(x: w * 0.38, y: h * 0.60),
                               controlPoint1: CGPoint(x: w * 0.08, y: h * 0.84),
                               controlPoint2: CGPoint(x: w * 0.28, y: h * 0.70))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.35, y: h * 0.46))
                inner.addCurve(to: CGPoint(x: w * 0.17, y: h * 0.68),
                               controlPoint1: CGPoint(x: w * 0.25, y: h * 0.48),
                               controlPoint2: CGPoint(x: w * 0.16, y: h * 0.59))
                inner.addCurve(to: CGPoint(x: w * 0.36, y: h * 0.58),
                               controlPoint1: CGPoint(x: w * 0.18, y: h * 0.76),
                               controlPoint2: CGPoint(x: w * 0.29, y: h * 0.66))
                inner.close()

            case .bunny:
                // Upright bunny ear with gentle fold
                outer.move(to: CGPoint(x: w * 0.40, y: h * 0.48))
                outer.addCurve(to: CGPoint(x: w * 0.30, y: h * 0.05),
                               controlPoint1: CGPoint(x: w * 0.31, y: h * 0.34),
                               controlPoint2: CGPoint(x: w * 0.26, y: h * 0.16))
                outer.addCurve(to: CGPoint(x: w * 0.47, y: h * 0.44),
                               controlPoint1: CGPoint(x: w * 0.40, y: h * 0.03),
                               controlPoint2: CGPoint(x: w * 0.48, y: h * 0.22))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.40, y: h * 0.44))
                inner.addCurve(to: CGPoint(x: w * 0.33, y: h * 0.14),
                               controlPoint1: CGPoint(x: w * 0.34, y: h * 0.33),
                               controlPoint2: CGPoint(x: w * 0.31, y: h * 0.20))
                inner.addCurve(to: CGPoint(x: w * 0.44, y: h * 0.42),
                               controlPoint1: CGPoint(x: w * 0.39, y: h * 0.13),
                               controlPoint2: CGPoint(x: w * 0.45, y: h * 0.24))
                inner.close()

            case .koala:
                // Fluffy round koala ears
                outer.append(UIBezierPath(ovalIn: CGRect(x: w * 0.04, y: h * 0.22,
                                                         width: w * 0.36, height: h * 0.36)))
                inner.append(UIBezierPath(ovalIn: CGRect(x: w * 0.12, y: h * 0.30,
                                                         width: w * 0.20, height: h * 0.20)))

            case .cat:
                // Pointed alert cat ear
                outer.move(to: CGPoint(x: w * 0.42, y: h * 0.48))
                outer.addLine(to: CGPoint(x: w * 0.20, y: h * 0.10))
                outer.addLine(to: CGPoint(x: w * 0.16, y: h * 0.46))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.38, y: h * 0.45))
                inner.addLine(to: CGPoint(x: w * 0.22, y: h * 0.18))
                inner.addLine(to: CGPoint(x: w * 0.20, y: h * 0.43))
            case .tiger:
                // Rounded powerful tiger ear with dark stripe accent
                outer.move(to: CGPoint(x: w * 0.44, y: h * 0.48))
                outer.addCurve(to: CGPoint(x: w * 0.16, y: h * 0.16),
                               controlPoint1: CGPoint(x: w * 0.38, y: h * 0.22),
                               controlPoint2: CGPoint(x: w * 0.22, y: h * 0.14))
                outer.addCurve(to: CGPoint(x: w * 0.16, y: h * 0.48),
                               controlPoint1: CGPoint(x: w * 0.10, y: h * 0.22),
                               controlPoint2: CGPoint(x: w * 0.12, y: h * 0.38))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.38, y: h * 0.46))
                inner.addCurve(to: CGPoint(x: w * 0.22, y: h * 0.24),
                               controlPoint1: CGPoint(x: w * 0.34, y: h * 0.28),
                               controlPoint2: CGPoint(x: w * 0.25, y: h * 0.22))
                inner.addCurve(to: CGPoint(x: w * 0.22, y: h * 0.45),
                               controlPoint1: CGPoint(x: w * 0.18, y: h * 0.28),
                               controlPoint2: CGPoint(x: w * 0.19, y: h * 0.38))
                inner.close()

            default:
                break
            }

            c.setFillColor(colours.outer.cgColor)
            c.addPath(outer.cgPath); c.fillPath()
            c.setFillColor(colours.inner.cgColor)
            c.addPath(inner.cgPath); c.fillPath()
            c.restoreGState()
        }

        ear(flipped: false)
        ear(flipped: true)
    }

    private static func drawSunglasses(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height
        c.saveGState()

        let framePath = UIBezierPath()
        let lensLeft = UIBezierPath(roundedRect: CGRect(x: w * 0.12, y: h * 0.36, width: w * 0.33, height: h * 0.30),
                                    cornerRadius: 18)
        let lensRight = UIBezierPath(roundedRect: CGRect(x: w * 0.55, y: h * 0.36, width: w * 0.33, height: h * 0.30),
                                     cornerRadius: 18)

        // Outer sunglasses frame
        framePath.append(UIBezierPath(roundedRect: CGRect(x: w * 0.08, y: h * 0.32, width: w * 0.39, height: h * 0.36),
                                      cornerRadius: 24))
        framePath.append(UIBezierPath(roundedRect: CGRect(x: w * 0.53, y: h * 0.32, width: w * 0.39, height: h * 0.36),
                                      cornerRadius: 24))

        // Bridge connecting lenses
        framePath.append(UIBezierPath(roundedRect: CGRect(x: w * 0.43, y: h * 0.42, width: w * 0.14, height: h * 0.08),
                                      cornerRadius: 4))

        // Side temples
        framePath.append(UIBezierPath(roundedRect: CGRect(x: w * 0.02, y: h * 0.36, width: w * 0.09, height: h * 0.07),
                                      cornerRadius: 3))
        framePath.append(UIBezierPath(roundedRect: CGRect(x: w * 0.89, y: h * 0.36, width: w * 0.09, height: h * 0.07),
                                      cornerRadius: 3))

        // Fill black glossy frame
        c.setFillColor(colors.outer.cgColor)
        c.addPath(framePath.cgPath)
        c.fillPath()

        // Lenses with deep gradient tint
        c.setFillColor(colors.inner.cgColor)
        c.addPath(lensLeft.cgPath)
        c.addPath(lensRight.cgPath)
        c.fillPath()

        // Specular highlight streaks across both lenses
        let glarePath = UIBezierPath()
        glarePath.move(to: CGPoint(x: w * 0.16, y: h * 0.62))
        glarePath.addLine(to: CGPoint(x: w * 0.32, y: h * 0.38))
        glarePath.addLine(to: CGPoint(x: w * 0.37, y: h * 0.38))
        glarePath.addLine(to: CGPoint(x: w * 0.21, y: h * 0.62))
        glarePath.close()

        glarePath.move(to: CGPoint(x: w * 0.59, y: h * 0.62))
        glarePath.addLine(to: CGPoint(x: w * 0.75, y: h * 0.38))
        glarePath.addLine(to: CGPoint(x: w * 0.80, y: h * 0.38))
        glarePath.addLine(to: CGPoint(x: w * 0.64, y: h * 0.62))
        glarePath.close()

        c.setFillColor(UIColor.white.withAlphaComponent(0.28).cgColor)
        c.addPath(glarePath.cgPath)
        c.fillPath()

        c.restoreGState()
    }

    private static func drawCrown(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height
        c.saveGState()

        // 5-Point Regal Gold Crown
        let crownPath = UIBezierPath()
        crownPath.move(to: CGPoint(x: w * 0.16, y: h * 0.76))
        crownPath.addLine(to: CGPoint(x: w * 0.12, y: h * 0.30))  // Left peak
        crownPath.addLine(to: CGPoint(x: w * 0.30, y: h * 0.52))  // Valley 1
        crownPath.addLine(to: CGPoint(x: w * 0.38, y: h * 0.22))  // Mid-left peak
        crownPath.addLine(to: CGPoint(x: w * 0.50, y: h * 0.46))  // Center valley
        crownPath.addLine(to: CGPoint(x: w * 0.50, y: h * 0.10))  // High center peak
        crownPath.addLine(to: CGPoint(x: w * 0.50, y: h * 0.46))
        crownPath.addLine(to: CGPoint(x: w * 0.62, y: h * 0.22))  // Mid-right peak
        crownPath.addLine(to: CGPoint(x: w * 0.70, y: h * 0.52))  // Valley 2
        crownPath.addLine(to: CGPoint(x: w * 0.88, y: h * 0.30))  // Right peak
        crownPath.addLine(to: CGPoint(x: w * 0.84, y: h * 0.76))  // Base right
        crownPath.close()

        // Rich Gold Fill
        c.setFillColor(colors.outer.cgColor)
        c.addPath(crownPath.cgPath)
        c.fillPath()

        // Crown headband trim
        let bandPath = UIBezierPath(roundedRect: CGRect(x: w * 0.15, y: h * 0.72, width: w * 0.70, height: h * 0.10),
                                    cornerRadius: 6)
        c.setFillColor(UIColor(red: 0.85, green: 0.65, blue: 0.08, alpha: 1).cgColor)
        c.addPath(bandPath.cgPath)
        c.fillPath()

        // Ruby Gems on peaks & headband
        c.setFillColor(colors.inner.cgColor)
        c.fillEllipse(in: CGRect(x: w * 0.46, y: h * 0.14, width: w * 0.08, height: h * 0.08))
        c.fillEllipse(in: CGRect(x: w * 0.35, y: h * 0.25, width: w * 0.06, height: h * 0.06))
        c.fillEllipse(in: CGRect(x: w * 0.59, y: h * 0.25, width: w * 0.06, height: h * 0.06))
        c.fillEllipse(in: CGRect(x: w * 0.10, y: h * 0.32, width: w * 0.05, height: h * 0.05))
        c.fillEllipse(in: CGRect(x: w * 0.85, y: h * 0.32, width: w * 0.05, height: h * 0.05))

        // Center oval ruby in headband
        c.fillEllipse(in: CGRect(x: w * 0.46, y: h * 0.73, width: w * 0.08, height: h * 0.08))

        c.restoreGState()
    }

    private static func drawHalo(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height
        c.saveGState()

        let haloRect = CGRect(x: w * 0.15, y: h * 0.35, width: w * 0.70, height: h * 0.28)

        // Outer glow
        c.setShadow(offset: .zero, blur: 28, color: UIColor.systemYellow.cgColor)

        // Torus Ring Path
        let ringPath = UIBezierPath(ovalIn: haloRect)
        c.setStrokeColor(colors.outer.cgColor)
        c.setLineWidth(24)
        c.addPath(ringPath.cgPath)
        c.strokePath()

        // Inner luminous core
        c.setShadow(offset: .zero, blur: 10, color: UIColor.white.cgColor)
        c.setStrokeColor(UIColor.white.withAlphaComponent(0.92).cgColor)
        c.setLineWidth(10)
        c.addPath(ringPath.cgPath)
        c.strokePath()

        c.restoreGState()
    }

    private static func drawDevilHorns(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height

        func horn(flipped: Bool) {
            c.saveGState()
            if flipped {
                c.translateBy(x: w, y: 0)
                c.scaleBy(x: -1, y: 1)
            }

            let hornPath = UIBezierPath()
            // Root at brow/skull side, curving outward and upward sharply
            hornPath.move(to: CGPoint(x: w * 0.32, y: h * 0.62))
            hornPath.addCurve(to: CGPoint(x: w * 0.14, y: h * 0.15),
                              controlPoint1: CGPoint(x: w * 0.22, y: h * 0.52),
                              controlPoint2: CGPoint(x: w * 0.12, y: h * 0.32))
            hornPath.addCurve(to: CGPoint(x: w * 0.40, y: h * 0.55),
                              controlPoint1: CGPoint(x: w * 0.20, y: h * 0.22),
                              controlPoint2: CGPoint(x: w * 0.32, y: h * 0.40))
            hornPath.close()

            // Crimson red horn
            c.setFillColor(colors.outer.cgColor)
            c.addPath(hornPath.cgPath)
            c.fillPath()

            // Glowing inner ridge highlight
            let ridgePath = UIBezierPath()
            ridgePath.move(to: CGPoint(x: w * 0.31, y: h * 0.58))
            ridgePath.addCurve(to: CGPoint(x: w * 0.16, y: h * 0.20),
                               controlPoint1: CGPoint(x: w * 0.23, y: h * 0.48),
                               controlPoint2: CGPoint(x: w * 0.15, y: h * 0.34))
            ridgePath.addCurve(to: CGPoint(x: w * 0.35, y: h * 0.54),
                               controlPoint1: CGPoint(x: w * 0.22, y: h * 0.28),
                               controlPoint2: CGPoint(x: w * 0.30, y: h * 0.44))
            ridgePath.close()

            c.setFillColor(colors.inner.cgColor)
            c.addPath(ridgePath.cgPath)
            c.fillPath()

            c.restoreGState()
        }

        horn(flipped: false)
        horn(flipped: true)
    }

    private static func drawPartyHat(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height
        c.saveGState()

        // Cone hat body
        let cone = UIBezierPath()
        cone.move(to: CGPoint(x: w * 0.50, y: h * 0.12)) // apex
        cone.addLine(to: CGPoint(x: w * 0.22, y: h * 0.78))
        cone.addQuadCurve(to: CGPoint(x: w * 0.78, y: h * 0.78), controlPoint: CGPoint(x: w * 0.50, y: h * 0.86))
        cone.close()

        c.setFillColor(colors.outer.cgColor) // Festive gold
        c.addPath(cone.cgPath)
        c.fillPath()

        // Diagonal festive stripes
        c.saveGState()
        c.addPath(cone.cgPath)
        c.clip()

        let stripeColors = [
            UIColor(red: 1.0, green: 0.25, blue: 0.45, alpha: 0.95), // Coral red
            UIColor(red: 0.20, green: 0.85, blue: 1.0, alpha: 0.95), // Cyan
            UIColor(red: 0.65, green: 0.30, blue: 1.0, alpha: 0.95)  // Violet
        ]
        for i in 0..<5 {
            let sp = UIBezierPath()
            let yBase = h * (0.25 + CGFloat(i) * 0.13)
            sp.move(to: CGPoint(x: w * 0.10, y: yBase))
            sp.addLine(to: CGPoint(x: w * 0.90, y: yBase - h * 0.12))
            sp.addLine(to: CGPoint(x: w * 0.90, y: yBase - h * 0.05))
            sp.addLine(to: CGPoint(x: w * 0.10, y: yBase + h * 0.07))
            sp.close()
            c.setFillColor(stripeColors[i % stripeColors.count].cgColor)
            c.addPath(sp.cgPath)
            c.fillPath()
        }
        c.restoreGState()

        // Hat brim trim
        let brim = UIBezierPath()
        brim.move(to: CGPoint(x: w * 0.20, y: h * 0.78))
        brim.addQuadCurve(to: CGPoint(x: w * 0.80, y: h * 0.78), controlPoint: CGPoint(x: w * 0.50, y: h * 0.88))
        c.setStrokeColor(UIColor.white.withAlphaComponent(0.95).cgColor)
        c.setLineWidth(14.0)
        c.setLineCap(.round)
        c.addPath(brim.cgPath)
        c.strokePath()

        // Top fluffy pom-pom
        c.setFillColor(colors.inner.cgColor) // Ruby red
        c.fillEllipse(in: CGRect(x: w * 0.43, y: h * 0.06, width: w * 0.14, height: h * 0.14))

        // Sparkle glints on pom-pom
        c.setFillColor(UIColor.white.cgColor)
        c.fillEllipse(in: CGRect(x: w * 0.46, y: h * 0.09, width: 8, height: 8))

        c.restoreGState()
    }

    private static func drawCyberVisor(in c: CGContext, size: CGSize, colors: (outer: UIColor, inner: UIColor, nose: UIColor)) {
        let w = size.width, h = size.height
        c.saveGState()

        // Outer neon frame
        let visorPath = UIBezierPath()
        visorPath.move(to: CGPoint(x: w * 0.08, y: h * 0.38))
        visorPath.addLine(to: CGPoint(x: w * 0.22, y: h * 0.34))
        visorPath.addLine(to: CGPoint(x: w * 0.78, y: h * 0.34))
        visorPath.addLine(to: CGPoint(x: w * 0.92, y: h * 0.38))
        visorPath.addLine(to: CGPoint(x: w * 0.88, y: h * 0.62))
        visorPath.addLine(to: CGPoint(x: w * 0.58, y: h * 0.66))
        visorPath.addLine(to: CGPoint(x: w * 0.50, y: h * 0.54)) // bridge notch
        visorPath.addLine(to: CGPoint(x: w * 0.42, y: h * 0.66))
        visorPath.addLine(to: CGPoint(x: w * 0.12, y: h * 0.62))
        visorPath.close()

        // Polarized dark tint
        c.setFillColor(UIColor(red: 0.04, green: 0.08, blue: 0.14, alpha: 0.85).cgColor)
        c.addPath(visorPath.cgPath)
        c.fillPath()

        // Neon cyan border
        c.setStrokeColor(colors.outer.cgColor) // #00F0FF
        c.setLineWidth(6.0)
        c.setLineJoin(.miter)
        c.addPath(visorPath.cgPath)
        c.strokePath()

        // Glowing HUD grid lines across visor
        c.saveGState()
        c.addPath(visorPath.cgPath)
        c.clip()

        c.setStrokeColor(UIColor(red: 0.0, green: 0.94, blue: 1.0, alpha: 0.35).cgColor)
        c.setLineWidth(1.5)
        for y in stride(from: h * 0.36, to: h * 0.64, by: 12) {
            c.move(to: CGPoint(x: w * 0.10, y: y))
            c.addLine(to: CGPoint(x: w * 0.90, y: y))
            c.strokePath()
        }

        // Hot pink telemetry crosshairs in right lens
        c.setStrokeColor(colors.inner.cgColor) // #FF007F
        c.setLineWidth(2.5)
        let cx = w * 0.72, cy = h * 0.48
        c.strokeEllipse(in: CGRect(x: cx - 18, y: cy - 18, width: 36, height: 36))
        c.move(to: CGPoint(x: cx - 24, y: cy))
        c.addLine(to: CGPoint(x: cx + 24, y: cy))
        c.move(to: CGPoint(x: cx, y: cy - 24))
        c.addLine(to: CGPoint(x: cx, y: cy + 24))
        c.strokePath()

        // Specular glare streak across left lens
        let glare = UIBezierPath()
        glare.move(to: CGPoint(x: w * 0.18, y: h * 0.60))
        glare.addLine(to: CGPoint(x: w * 0.32, y: h * 0.36))
        glare.addLine(to: CGPoint(x: w * 0.36, y: h * 0.36))
        glare.addLine(to: CGPoint(x: w * 0.22, y: h * 0.60))
        glare.close()
        c.setFillColor(UIColor.white.withAlphaComponent(0.35).cgColor)
        c.addPath(glare.cgPath)
        c.fillPath()

        c.restoreGState()

        // Temple data hinges
        c.setFillColor(colors.outer.cgColor)
        c.fill(CGRect(x: w * 0.04, y: h * 0.36, width: w * 0.06, height: h * 0.08))
        c.fill(CGRect(x: w * 0.90, y: h * 0.36, width: w * 0.06, height: h * 0.08))

        c.restoreGState()
    }
}
