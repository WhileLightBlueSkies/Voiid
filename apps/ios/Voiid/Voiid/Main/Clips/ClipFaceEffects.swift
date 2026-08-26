//
//  ClipFaceEffects.swift
//  Voiid
//
//  Face-tracked camera effects — the "dog filter" family.
//
//  ── WHY VISION AND NOT ARKIT ────────────────────────────────────────────────────
//  ARKit's face tracking is higher fidelity (a 3D mesh, 52 blend shapes) but it requires
//  the TrueDepth camera, so it works on the front camera only and not at all on the SE.
//  A dog filter that silently vanishes when you flip to the back camera is worse than one
//  that is slightly less precise. Vision's `VNDetectFaceLandmarksRequest` runs on any
//  camera on any device, and it consumes the CVPixelBuffer this pipeline already has.
//
//  ── WHY THE EFFECT IS DRAWN AS A CIImage ────────────────────────────────────────
//  The camera preview is an MTKView fed by `renderer.submit(CIImage)`. Compositing the
//  ears into that same CIImage means the effect follows the EXACT path the colour filters
//  already take — one code path to reason about, and the preview cannot drift from what a
//  future export produces.
//
//  ── DETECTION RUNS SLOWER THAN THE FRAME RATE, ON PURPOSE ───────────────────────
//  Landmark detection costs several milliseconds; running it on all 30 fps would drop
//  frames on older hardware. It runs on its own queue at ~12 Hz and the last known face is
//  reused between detections. Faces do not move far in 80 ms, and the alternative — a
//  stuttering preview — is far more visible than a frame of lag on the ears.
//
//  ── THE ASSETS ARE DRAWN IN CODE ────────────────────────────────────────────────
//  No PNGs, no downloads, no third-party SDK, no licence to honour. Each effect is vector
//  geometry rendered through Core Graphics once and cached as a CIImage. That keeps the
//  app binary unchanged and sidesteps the licensing問題 entirely: nothing here is
//  anyone else's artwork.
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
    case bunny
    case koala

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none:  return "None"
        case .dog:   return "Dog"
        case .bunny: return "Bunny"
        case .koala: return "Koala"
        }
    }

    /// Shown on the picker rail. A glyph, not a thumbnail: a face effect has nothing to
    /// preview until there is a face in frame.
    var symbol: String {
        switch self {
        case .none:  return "person"
        case .dog:   return "pawprint.fill"
        case .bunny: return "hare.fill"
        case .koala: return "teddybear.fill"
        }
    }

    /// Ear/nose palette, per effect.
    fileprivate var palette: (outer: UIColor, inner: UIColor, nose: UIColor) {
        switch self {
        case .none:
            return (.clear, .clear, .clear)
        case .dog:
            return (UIColor(red: 0.42, green: 0.28, blue: 0.18, alpha: 1),
                    UIColor(red: 0.85, green: 0.65, blue: 0.50, alpha: 1),
                    UIColor(red: 0.15, green: 0.12, blue: 0.11, alpha: 1))
        case .bunny:
            return (UIColor(red: 0.96, green: 0.94, blue: 0.94, alpha: 1),
                    UIColor(red: 0.98, green: 0.78, blue: 0.82, alpha: 1),
                    UIColor(red: 0.94, green: 0.55, blue: 0.62, alpha: 1))
        case .koala:
            return (UIColor(red: 0.55, green: 0.57, blue: 0.60, alpha: 1),
                    UIColor(red: 0.80, green: 0.82, blue: 0.85, alpha: 1),
                    UIColor(red: 0.20, green: 0.19, blue: 0.20, alpha: 1))
        }
    }

    /// Ear geometry as a fraction of face width. Floppy (dog) hangs down the sides;
    /// upright (bunny) rises above the head; round (koala) sits wide at the temples.
    fileprivate enum EarStyle { case floppy, upright, round }

    fileprivate var earStyle: EarStyle {
        switch self {
        case .dog:   return .floppy
        case .bunny: return .upright
        case .koala: return .round
        case .none:  return .round
        }
    }
}

// MARK: - Tracked face

/// One detected face, in the coordinate space of the CIImage being rendered.
struct TrackedFace {
    /// Face bounding box, image pixels, origin bottom-left (CIImage convention).
    let box: CGRect
    /// Roll in radians, from the eye line. Ears rotate with the head; without this they
    /// stay stubbornly level while the face tilts, which is what reads as "stuck on".
    let roll: CGFloat
    /// Nose tip in image pixels, when landmarks resolved it.
    let nose: CGPoint?
}

// MARK: - Detector

/// Runs Vision off the capture queue and publishes the most recent faces.
///
/// Thread-safety: `latest` is guarded by a lock because it is written on the detection
/// queue and read on the capture queue, which are different threads by design.
/// Detect once, then TRACK every frame — the architecture Apple's own "Tracking the User's
/// Face in Real Time" sample uses, and the one Snapchat-style effects need.
///
/// ── WHY THE FIRST VERSION LOOKED BAD ────────────────────────────────────────────
/// It ran full `VNDetectFaceLandmarksRequest` at 12–20 Hz and reused the last result in
/// between. Two things followed, and both were visible:
///   • The ears updated at 20 Hz over 30 fps video, so they stepped rather than moved.
///   • Full detection re-finds the face from scratch each time, and its box lands a few
///     pixels differently on every run even on a motionless head. That is shimmer, and no
///     amount of smoothing removes it without also removing real movement.
///
/// ── WHAT THIS DOES INSTEAD ──────────────────────────────────────────────────────
/// `VNTrackObjectRequest` on a `VNSequenceRequestHandler` follows the SAME face from frame
/// to frame. It is far cheaper than detection, so it runs on EVERY frame — the effect moves
/// at video rate — and because it is following one object rather than re-finding it, its
/// output is inherently stable.
///
/// Detection still runs, but only to (re)acquire: at start, when tracking is lost, and
/// occasionally to correct drift. That is the split that makes this feel attached.
final class ClipFaceDetector {

    private let queue = DispatchQueue(label: "voiid.clip.face", qos: .userInitiated)
    private let lock = NSLock()
    private var _latest: [TrackedFace] = []
    private var busy = false

    /// Sequence handler carries state between frames; a fresh one per frame would defeat
    /// the point of tracking entirely.
    private let sequence = VNSequenceRequestHandler()
    private var tracker: VNTrackObjectRequest?

    /// Re-detect this often even while tracking succeeds. Trackers drift — they follow the
    /// region they were given, and a slow drift off the face is exactly the "sliding" look
    /// that makes an effect feel cheap.
    private let redetectInterval: CFTimeInterval = 1.0
    private var lastDetect: CFTimeInterval = 0

    /// Below this the tracker is not really on the face any more; drop it and re-detect
    /// rather than follow whatever it has latched onto.
    private let minConfidence: VNConfidence = 0.4

    private static let copyContext = CIContext(options: [.cacheIntermediates: false])

    var latest: [TrackedFace] {
        lock.lock(); defer { lock.unlock() }
        return _latest
    }

    func reset() {
        lock.lock()
        _latest = []
        tracker = nil
        lastDetect = 0
        lock.unlock()
    }

    /// Hand a frame in. Returns immediately.
    ///
    /// The buffer MUST be copied before it crosses onto another queue: capture buffers come
    /// from a finite pool and are recycled as soon as this delegate returns. Handing the
    /// original to an async block is a use-after-recycle — it crashed, and crashed soonest
    /// on the front camera whose pool wraps around fastest.
    func submit(_ pixels: CVPixelBuffer) {
        lock.lock()
        if busy { lock.unlock(); return }
        busy = true
        lock.unlock()

        guard let snapshot = Self.copy(pixels) else {
            lock.lock(); busy = false; lock.unlock()
            return
        }

        // Dimensions of the ORIGINAL frame, not the downscaled snapshot. Vision reports
        // normalised boxes, and the renderer draws into the full-resolution image — scaling
        // them by the 480px snapshot would place the ears in a corner at a fraction of the
        // right size.
        let width = CGFloat(CVPixelBufferGetWidth(pixels))
        let height = CGFloat(CVPixelBufferGetHeight(pixels))

        queue.async { [weak self] in
            guard let self else { return }
            defer { self.lock.lock(); self.busy = false; self.lock.unlock() }
            self.process(snapshot, width: width, height: height)
        }
    }

    private func process(_ buffer: CVPixelBuffer, width: CGFloat, height: CGFloat) {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        var active = tracker
        let dueForDetect = (now - lastDetect) > redetectInterval
        lock.unlock()

        // ── Track ──────────────────────────────────────────────────────────────
        if let request = active, !dueForDetect {
            do {
                try sequence.perform([request], on: buffer)
                if let obs = request.results?.first as? VNDetectedObjectObservation,
                   obs.confidence >= minConfidence {
                    request.inputObservation = obs      // feed forward for the next frame
                    publish(box: obs.boundingBox, width: width, height: height, roll: nil)
                    return
                }
            } catch {
                // Fall through to re-detect.
            }
            // Lost: drop the tracker so the branch below reacquires.
            lock.lock(); tracker = nil; lock.unlock()
            active = nil
        }

        // ── Detect (acquire or correct) ────────────────────────────────────────
        let request = VNDetectFaceRectanglesRequest()
        // Rectangles, not landmarks: the only landmark this effect used was the nose, and
        // it can be derived from the box far more cheaply than a 65-point constellation.
        // Rectangle detection is several times faster, which is what lets it re-run often
        // enough to keep the tracker honest.
        if let newest = VNDetectFaceRectanglesRequest.supportedRevisions.max() {
            request.revision = newest
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do { try handler.perform([request]) } catch { return }

        guard let face = (request.results ?? [])
            .max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            // No face: clear, so the ears do not hang in the last known spot.
            lock.lock(); _latest = []; tracker = nil; lock.unlock()
            return
        }

        let fresh = VNTrackObjectRequest(detectedObjectObservation:
            VNDetectedObjectObservation(boundingBox: face.boundingBox))
        // `.accurate` costs more per frame than `.fast` but drifts far less, and drift is
        // the failure mode that reads as broken.
        fresh.trackingLevel = .accurate

        lock.lock()
        tracker = fresh
        lastDetect = now
        lock.unlock()

        // Roll comes from detection only — the tracker reports a box, not an angle — so it
        // refreshes at the re-detect rate and is smoothed between.
        publish(box: face.boundingBox, width: width, height: height,
                roll: CGFloat(face.roll?.doubleValue ?? 0))
    }

    /// Convert to image pixels and blend into the published value.
    ///
    /// Smoothing is light because tracking is already stable: it exists to soften the one
    /// step that does jump — the hand-off when a re-detect corrects the tracker.
    private func publish(box normalised: CGRect, width: CGFloat, height: CGFloat,
                         roll: CGFloat?) {
        let box = CGRect(x: normalised.origin.x * width, y: normalised.origin.y * height,
                         width: normalised.width * width, height: normalised.height * height)

        lock.lock()
        let previous = _latest.first
        // Roll is nil on tracked frames; hold the last known angle rather than snapping the
        // ears level between re-detects.
        let newRoll = roll ?? previous?.roll ?? 0

        var result = TrackedFace(box: box, roll: newRoll, nose: nil)
        if let a = previous {
            let k: CGFloat = 0.5
            func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * k }
            let jump = hypot(box.midX - a.box.midX, box.midY - a.box.midY)
            // A real jump (fast head turn, or a different face acquired) must snap, or the
            // ears crawl across the screen to catch up.
            if jump <= a.box.width * 0.5 {
                result = TrackedFace(
                    box: CGRect(x: lerp(a.box.minX, box.minX), y: lerp(a.box.minY, box.minY),
                                width: lerp(a.box.width, box.width),
                                height: lerp(a.box.height, box.height)),
                    roll: lerp(a.roll, newRoll),
                    nose: nil)
            }
        }
        _latest = [result]
        lock.unlock()
    }

    /// Detach a frame from the capture pool so it can outlive the delegate callback,
    /// downscaling as it goes.
    ///
    /// Vision works in NORMALISED coordinates, so a smaller buffer costs nothing in
    /// accuracy of placement — but it makes both this copy and the tracking meaningfully
    /// cheaper, which is what allows tracking to run on every frame. 480px on the long edge
    /// is well above what face rectangles need.
    private static func copy(_ source: CVPixelBuffer) -> CVPixelBuffer? {
        let sw = CVPixelBufferGetWidth(source)
        let sh = CVPixelBufferGetHeight(source)
        let scale = min(1.0, 480.0 / CGFloat(max(sw, sh)))
        let w = Int((CGFloat(sw) * scale).rounded())
        let h = Int((CGFloat(sh) * scale).rounded())
        var out: CVPixelBuffer?
        let attrs: [String: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],   // required for Metal/Vision
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

/// Draws an effect over a frame. Stateless apart from a small sprite cache.
enum ClipFaceRenderer {

    /// Sprites are rasterised once per (effect, size) and reused. Rebuilding the ear
    /// artwork every frame would dominate the frame budget for no visual gain.
    private static var cache: [String: CIImage] = [:]
    private static let cacheLock = NSLock()

    static func apply(_ effect: ClipFaceEffect, to image: CIImage,
                      faces: [TrackedFace]) -> CIImage {
        guard effect != .none, !faces.isEmpty else { return image }

        var output = image
        for face in faces {
            // Sized off face WIDTH, not height: Vision's box height varies with how much
            // chin and forehead it includes, while width is stable across expressions.
            let w = face.box.width
            guard w > 20 else { continue }   // too small to place convincingly

            guard let sprite = sprite(for: effect) else { continue }

            // The sprite is a fixed-size bitmap; THIS is what makes it track the face. It
            // is scaled from the reference size to 1.6× the current face width, so the ears
            // grow and shrink continuously as you move toward and away from the camera.
            // 1.3×, verified against the ear path extents below: at 1.6× the outer edge of
            // the dog ear landed at 0.74× face width from centre — outside a face that only
            // reaches 0.5× — so the ears floated beside the head instead of sitting on it.
            let spriteSide = w * 1.3
            let scale = spriteSide / referenceSprite

            // Anchored to the TOP of the box, not its centre.
            //
            // Vision's box height swells and shrinks with expression and head angle while
            // its top edge tracks the crown fairly steadily — so a centre anchor made the
            // ears creep up and down the head as you talked. Measuring down from the top
            // edge keeps them planted.
            let centre = CGPoint(x: face.box.midX, y: face.box.maxY - w * 0.08)

            // Order matters and reads right-to-left: scale the sprite, centre it on the
            // origin, rotate with the head, then move to the face. Scaling AFTER the
            // centring offset would scale the offset too and throw the ears off-centre.
            var t = CGAffineTransform.identity
            t = t.translatedBy(x: centre.x, y: centre.y)
            t = t.rotated(by: face.roll)
            t = t.translatedBy(x: -spriteSide / 2, y: -spriteSide / 2)
            t = t.scaledBy(x: scale, y: scale)

            let placed = sprite.transformed(by: t)
            output = placed.composited(over: output)

            // Derived from the box rather than a landmark: the nose sits on the vertical
            // centre line a little below the middle of the face. A landmark would jitter
            // independently of the box and make the snout swim against the ears.
            let nose = face.nose ?? CGPoint(x: face.box.midX,
                                            y: face.box.minY + face.box.height * 0.42)
            if let noseSprite = noseSprite(for: effect) {
                let noseSide = w * 0.30
                let noseScale = noseSide / referenceSprite
                var nt = CGAffineTransform.identity
                nt = nt.translatedBy(x: nose.x, y: nose.y)
                nt = nt.rotated(by: face.roll)
                nt = nt.translatedBy(x: -noseSide / 2, y: -noseSide / 2)
                nt = nt.scaledBy(x: noseScale, y: noseScale)
                output = noseSprite.transformed(by: nt).composited(over: output)
            }
        }
        return output
    }

    // MARK: Sprite construction

    /// Every sprite is rasterised ONCE at this size and scaled per frame.
    ///
    /// Rasterising per face width was the bug behind "the ears never change size": the
    /// cache key was the requested POINT size, but `UIGraphicsImageRenderer` renders at the
    /// screen's scale (2–3×), so the bitmap was 2–3× larger than the transform assumed —
    /// and whichever size was built first was what got reused. Scaling one cached bitmap
    /// is both continuous and correct.
    private static let referenceSprite: CGFloat = 512

    private static func sprite(for effect: ClipFaceEffect) -> CIImage? {
        let key = "\(effect.rawValue)-ears"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let size = CGSize(width: referenceSprite, height: referenceSprite)
        // scale: 1 — render in PIXELS, not screen points. Without this the bitmap comes out
        // 2–3× the requested size on a Retina device and every placement is wrong by that
        // factor.
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let ui = renderer.image { ctx in
            drawEars(effect, in: ctx.cgContext, size: size)
        }
        guard let cg = ui.cgImage else { return nil }
        // `.oriented(.downMirrored)` converts UIKit's top-left origin into CIImage's
        // bottom-left. Skipping this draws every effect upside down — the single easiest
        // mistake to make in this file.
        let ci = CIImage(cgImage: cg).oriented(.downMirrored)

        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func noseSprite(for effect: ClipFaceEffect) -> CIImage? {
        let key = "\(effect.rawValue)-nose"
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()

        let box = CGSize(width: referenceSprite, height: referenceSprite)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false
        let renderer = UIGraphicsImageRenderer(size: box, format: format)
        let colours = effect.palette
        let ui = renderer.image { ctx in
            let c = ctx.cgContext
            c.setFillColor(colours.nose.cgColor)
            // A rounded triangle reads as a snout at small sizes; a circle reads as a dot.
            let path = UIBezierPath()
            path.move(to: CGPoint(x: box.width * 0.5, y: box.height * 0.95))
            path.addCurve(to: CGPoint(x: box.width * 0.05, y: box.height * 0.30),
                          controlPoint1: CGPoint(x: box.width * 0.20, y: box.height * 0.90),
                          controlPoint2: CGPoint(x: box.width * 0.02, y: box.height * 0.55))
            path.addCurve(to: CGPoint(x: box.width * 0.95, y: box.height * 0.30),
                          controlPoint1: CGPoint(x: box.width * 0.10, y: box.height * 0.02),
                          controlPoint2: CGPoint(x: box.width * 0.90, y: box.height * 0.02))
            path.addCurve(to: CGPoint(x: box.width * 0.5, y: box.height * 0.95),
                          controlPoint1: CGPoint(x: box.width * 0.98, y: box.height * 0.55),
                          controlPoint2: CGPoint(x: box.width * 0.80, y: box.height * 0.90))
            path.close()
            c.addPath(path.cgPath)
            c.fillPath()
        }
        guard let cg = ui.cgImage else { return nil }
        let ci = CIImage(cgImage: cg).oriented(.downMirrored)
        cacheLock.lock(); cache[key] = ci; cacheLock.unlock()
        return ci
    }

    private static func drawEars(_ effect: ClipFaceEffect, in c: CGContext, size: CGSize) {
        let colours = effect.palette
        let w = size.width, h = size.height

        func ear(flipped: Bool) {
            c.saveGState()
            if flipped {
                // Mirror about the centre so the two ears are symmetric without a second
                // hand-written path that could drift from the first.
                c.translateBy(x: w, y: 0)
                c.scaleBy(x: -1, y: 1)
            }

            let outer = UIBezierPath()
            let inner = UIBezierPath()

            switch effect.earStyle {
            case .floppy:
                // Hangs from the crown down past the temple — the dog silhouette.
                //
                // The ear ROOT sits at x≈0.30 and the tip reaches x≈0.14, so with a 1.3×
                // canvas the outer edge lands ≈0.32× face width from centre: ON the head,
                // overlapping the skull, which is what makes it read as attached. The
                // previous path reached x=0.04 and floated clear of the face entirely.
                outer.move(to: CGPoint(x: w * 0.34, y: h * 0.26))
                outer.addCurve(to: CGPoint(x: w * 0.14, y: h * 0.60),
                               controlPoint1: CGPoint(x: w * 0.20, y: h * 0.30),
                               controlPoint2: CGPoint(x: w * 0.14, y: h * 0.44))
                outer.addCurve(to: CGPoint(x: w * 0.40, y: h * 0.50),
                               controlPoint1: CGPoint(x: w * 0.15, y: h * 0.72),
                               controlPoint2: CGPoint(x: w * 0.34, y: h * 0.66))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.34, y: h * 0.32))
                inner.addCurve(to: CGPoint(x: w * 0.21, y: h * 0.57),
                               controlPoint1: CGPoint(x: w * 0.25, y: h * 0.35),
                               controlPoint2: CGPoint(x: w * 0.20, y: h * 0.46))
                inner.addCurve(to: CGPoint(x: w * 0.36, y: h * 0.48),
                               controlPoint1: CGPoint(x: w * 0.23, y: h * 0.65),
                               controlPoint2: CGPoint(x: w * 0.33, y: h * 0.61))
                inner.close()

            case .upright:
                // Tall, narrow, rising above the crown — the bunny silhouette.
                outer.move(to: CGPoint(x: w * 0.30, y: h * 0.34))
                outer.addCurve(to: CGPoint(x: w * 0.24, y: h * 0.02),
                               controlPoint1: CGPoint(x: w * 0.22, y: h * 0.26),
                               controlPoint2: CGPoint(x: w * 0.18, y: h * 0.08))
                outer.addCurve(to: CGPoint(x: w * 0.40, y: h * 0.30),
                               controlPoint1: CGPoint(x: w * 0.34, y: h * 0.02),
                               controlPoint2: CGPoint(x: w * 0.42, y: h * 0.14))
                outer.close()

                inner.move(to: CGPoint(x: w * 0.31, y: h * 0.31))
                inner.addCurve(to: CGPoint(x: w * 0.28, y: h * 0.10),
                               controlPoint1: CGPoint(x: w * 0.26, y: h * 0.25),
                               controlPoint2: CGPoint(x: w * 0.24, y: h * 0.14))
                inner.addCurve(to: CGPoint(x: w * 0.37, y: h * 0.28),
                               controlPoint1: CGPoint(x: w * 0.33, y: h * 0.09),
                               controlPoint2: CGPoint(x: w * 0.38, y: h * 0.17))
                inner.close()

            case .round:
                // Wide circles at the temples — the koala silhouette.
                outer.append(UIBezierPath(ovalIn: CGRect(x: w * 0.02, y: h * 0.20,
                                                         width: w * 0.30, height: h * 0.30)))
                inner.append(UIBezierPath(ovalIn: CGRect(x: w * 0.09, y: h * 0.27,
                                                         width: w * 0.16, height: h * 0.16)))
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
}
