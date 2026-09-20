//
//  ClipFaceEffects.swift
//  Voiid
//
//  Face-tracked camera effects: Vision landmarks, One Euro smoothing, and photoreal
//  sprites placed in units of the interocular distance.
//
//  The art and its placement live in ClipFaceSprites.swift, which mirrors the Android
//  table in ClipFaceSprites.kt — the two platforms have to agree on where a dog's ear
//  goes, so the numbers are kept in one shape on both.
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
        // These were being left behind, so the first frame after a reset computed its roll
        // VELOCITY against a stale angle and kicked the ear spring on frame one — a visible
        // flick every time the filter was re-enabled.
        lastRoll = 0
        lastEyeMid = .zero
        lastDistance = 0
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
            // Measured between the eyes we actually found. Vision's own `roll` was being
            // read here and the landmark angle computed and then thrown away, which also
            // made the whole branch a no-op — `roll` had already been set to face.roll
            // above. The landmarks are the better source: they follow the eyes even when
            // Vision's coarse pose lags.
            roll = atan2(r.y - l.y, r.x - l.x)

            // Secondary yaw from eye asymmetry about the nose. BLENDED, not switched: the
            // old code substituted this only while |yaw| < 0.05, so yaw jumped every time
            // it crossed that threshold and the props popped sideways.
            if let nosePoint = centroid(face.landmarks?.nose, in: imageSize) {
                let dL = abs(nosePoint.x - l.x)
                let dR = abs(nosePoint.x - r.x)
                let total = dL + dR
                if total > 5 {
                    let eyeRatio = (dR - dL) / total
                    let fromEyes = min(0.60, max(-0.60, eyeRatio * 0.50))
                    // Trust the landmark estimate head-on, Vision's pose as the head turns.
                    let w = max(0, min(1, 1 - abs(yaw) / 0.25))
                    yaw = yaw * (1 - w) + fromEyes * w
                }
            }
        }

        let nose = centroid(face.landmarks?.nose, in: imageSize)
            ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.42)

        var mouthMid = CGPoint(x: box.midX, y: box.minY + box.height * 0.28)
        var rawMouthOpen: CGFloat = 0
        var rawSmile: CGFloat = 0

        // Mouth opening measured along the FACE's up axis, not the image's. Taking the
        // raw y-extent of the lip points meant a rolled head projected some of the mouth's
        // WIDTH onto image-y, so tilting your head read as opening your mouth.
        let faceUp = CGVector(dx: -sin(roll), dy: cos(roll))
        func openness(_ pts: [CGPoint], scale: CGFloat, floor: CGFloat, span: CGFloat) -> CGFloat {
            var lo = CGFloat.greatestFiniteMagnitude
            var hi = -CGFloat.greatestFiniteMagnitude
            for p in pts {
                let along = p.x * faceUp.dx + p.y * faceUp.dy
                lo = min(lo, along); hi = max(hi, along)
            }
            let h = max(0, hi - lo)
            return min(1.0, max(0.0, (h / (eyeDistance * scale) - floor) / span))
        }

        if let innerLips = face.landmarks?.innerLips, innerLips.pointCount >= 4 {
            let pts = innerLips.pointsInImage(imageSize: imageSize)
            if !pts.isEmpty {
                rawMouthOpen = openness(pts, scale: 0.40, floor: 0.08, span: 0.38)
                let avgX = pts.reduce(0) { $0 + $1.x } / CGFloat(pts.count)
                let avgY = pts.reduce(0) { $0 + $1.y } / CGFloat(pts.count)
                mouthMid = CGPoint(x: avgX, y: avgY)
            }
        } else if let outerLips = face.landmarks?.outerLips, outerLips.pointCount >= 4 {
            let pts = outerLips.pointsInImage(imageSize: imageSize)
            if !pts.isEmpty {
                rawMouthOpen = openness(pts, scale: 0.44, floor: 0.12, span: 0.40)
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
        let dtF = CGFloat(dt)
        let wobble = smoother.earWobble.update(target: -rollVelocity * 0.08, dt: dtF)

        let smoothed = TrackedFace(
            box: box,
            eyeMid: CGPoint(x: smoother.eyeMidX.filter(eyeMid.x, dt: dtF),
                            y: smoother.eyeMidY.filter(eyeMid.y, dt: dtF)),
            eyeDistance: smoother.dist.filter(eyeDistance, dt: dtF),
            roll: smoother.roll.filter(roll, dt: dtF),
            yaw: smoother.yaw.filter(yaw, dt: dtF),
            pitch: smoother.pitch.filter(pitch, dt: dtF),
            nose: CGPoint(x: smoother.noseX.filter(nose.x, dt: dtF),
                          y: smoother.noseY.filter(nose.y, dt: dtF)),
            mouthMid: CGPoint(x: smoother.mouthMidX.filter(mouthMid.x, dt: dtF),
                              y: smoother.mouthMidY.filter(mouthMid.y, dt: dtF)),
            mouthOpenness: smoother.mouthOpen.filter(mouthOpenness, dt: dtF),
            smilingRatio: smoother.smile.filter(smilingRatio, dt: dtF),
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

    /// Composites the filter's layers onto the camera image.
    ///
    /// Core Image's y axis points UP, so "up the face" is (-sin roll, cos roll) here where
    /// Android uses (sin roll, -cos roll). That sign is the only real difference between
    /// the two renderers; the layer table, the D units and the pivots are identical.
    static func apply(_ effect: ClipFaceEffect, to image: CIImage,
                      faces: [TrackedFace]) -> CIImage {
        guard effect != .none, !faces.isEmpty else { return image }
        let layers = ClipFaceArt.layers[effect] ?? []
        guard !layers.isEmpty else { return image }

        var output = image

        for face in faces {
            let projectedD = face.hasLandmarks ? face.eyeDistance : face.box.width * 0.46
            guard projectedD > 8 else { continue }

            // Un-project so a turned head does not shrink the props.
            let cosYaw = max(0.55, cos(face.yaw))
            let D = projectedD / cosYaw

            let up = CGVector(dx: -sin(face.roll), dy: cos(face.roll))
            let right = CGVector(dx: cos(face.roll), dy: sin(face.roll))

            for layer in layers {
                if let gate = layer.openMouth, face.mouthOpenness < gate { continue }
                guard let sprite = ClipFaceAssets.image(named: layer.asset) else { continue }

                let src = sprite.extent
                guard src.width > 0, src.height > 0 else { continue }

                let targetW = layer.widthD * D * cosYaw
                let targetH = targetW / (src.width / src.height) / cosYaw
                let sx = targetW / src.width
                let sy = targetH / src.height

                let angle = face.roll + (layer.wobble ? face.earWobble : 0)
                let anchor = anchorPoint(layer.anchor, face)

                for side in (layer.mirrored ? [CGFloat(-1), CGFloat(1)] : [CGFloat(0)]) {
                    let outward = layer.outD * D * side
                    let at = CGPoint(
                        x: anchor.x + up.dx * (layer.riseD * D) + right.dx * outward,
                        y: anchor.y + up.dy * (layer.riseD * D) + right.dy * outward)

                    let flip = side > 0 ? !layer.flipBase : layer.flipBase

                    // Applied to a point in reverse order: pivot to origin, scale, rotate,
                    // then out to the anchor. pivotYFromTop is measured downward, Core
                    // Image counts upward, hence 1 - pivot.
                    var t = CGAffineTransform(translationX: at.x, y: at.y)
                    t = t.rotated(by: angle)
                    t = t.scaledBy(x: flip ? -sx : sx, y: sy)
                    t = t.translatedBy(x: -src.width * layer.pivotX,
                                       y: -src.height * (1 - layer.pivotYFromTop))

                    output = sprite.transformed(by: t).composited(over: output)
                }
            }
        }

        return output
    }

    private static func anchorPoint(_ anchor: FxAnchor, _ face: TrackedFace) -> CGPoint {
        switch anchor {
        case .eyes:  return face.eyeMid
        case .nose:  return face.nose
        case .mouth: return face.mouthMid
        }
    }
}
