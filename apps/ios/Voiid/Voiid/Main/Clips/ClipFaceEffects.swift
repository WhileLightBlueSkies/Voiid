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
//  ── HOW THE TRACKING STAYS LOCKED (THE SNAPCHAT/INSTAGRAM APPROACH) ─────────────
//  Every frame runs `VNDetectFaceLandmarksRequest` on a downscaled copy, off the capture
//  queue, and anchors the artwork to REAL features — the eyes and the nose — rather than to
//  a bounding box. Two things follow from that, and both are what "accurate" actually means:
//    • Scale comes from the distance between the eyes, which does not change when you open
//      your mouth or when the box decides to include more forehead. Box width does, and that
//      breathing was the size wobble.
//    • Roll comes from the eye line every frame, not from the box once a second, so the ears
//      tilt with the head in real time.
//  Raw landmark positions shimmer a pixel or two per frame even on a still head. A One Euro
//  filter (Casiez et al.) removes that shimmer without the lag a fixed low-pass adds: it
//  smooths hard when you hold still and barely at all when you move fast, which is exactly
//  the trade a face filter needs. Detection that can't keep up on old hardware simply drops
//  the frame (see `busy`); the filter carries the gap.
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
///
/// Everything is expressed relative to the EYES rather than the bounding box, because the
/// eyes are the part of the face that holds still while the rest of it talks and emotes.
struct TrackedFace {
    /// Face bounding box, image pixels, origin bottom-left (CIImage convention). Kept for
    /// the size gate and as the fallback anchor when landmarks did not resolve this frame.
    let box: CGRect
    /// Midpoint between the two eye centres, image pixels. The anchor everything hangs off.
    let eyeMid: CGPoint
    /// Distance between the eye centres, in pixels — the scale reference. Invariant to
    /// expression and to how much forehead the box happens to include, which box width isn't.
    let eyeDistance: CGFloat
    /// Roll in radians, measured directly from the eye line and refreshed every frame. Ears
    /// rotate with the head; without this they stay stubbornly level while the face tilts,
    /// which is what reads as "stuck on".
    let roll: CGFloat
    /// Nose centroid in image pixels — a real landmark, so the snout sits on the actual nose
    /// instead of a guessed spot on the box.
    let nose: CGPoint
    /// True when the eyes resolved this frame. When false the renderer falls back to box math.
    let hasLandmarks: Bool
}

// MARK: - One Euro filter

/// A first-order low-pass whose cutoff frequency rises with the signal's speed: heavy
/// smoothing when still (kills jitter), light smoothing when moving (kills lag). This is the
/// filter production face-AR uses, and the reason the ears can be both steady and responsive.
private struct OneEuroFilter {
    var minCutoff: CGFloat
    var beta: CGFloat
    var dCutoff: CGFloat = 1.0

    private var xPrev: CGFloat = 0
    private var dxPrev: CGFloat = 0
    private var hasPrev = false

    init(minCutoff: CGFloat, beta: CGFloat) {
        self.minCutoff = minCutoff
        self.beta = beta
    }

    private func alpha(cutoff: CGFloat, dt: CGFloat) -> CGFloat {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    mutating func filter(_ x: CGFloat, dt: CGFloat) -> CGFloat {
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

/// The set of filters for one tracked face. Reset (by reassignment) whenever the face is
/// (re)acquired, so a new head does not inherit the last one's smoothing history.
private struct FaceSmoother {
    // Positions move together and can move fast; a little beta keeps them from lagging on a
    // quick head turn. Scale should be near-constant, so it is smoothed harder.
    var eyeMidX = OneEuroFilter(minCutoff: 1.7, beta: 0.015)
    var eyeMidY = OneEuroFilter(minCutoff: 1.7, beta: 0.015)
    var dist    = OneEuroFilter(minCutoff: 1.0, beta: 0.007)
    var roll    = OneEuroFilter(minCutoff: 1.5, beta: 0.10)
    var noseX   = OneEuroFilter(minCutoff: 1.7, beta: 0.020)
    var noseY   = OneEuroFilter(minCutoff: 1.7, beta: 0.020)
}

// MARK: - Detector

/// Runs Vision off the capture queue and publishes the most recent face.
///
/// Thread-safety: `latest` is guarded by a lock because it is written on the detection
/// queue and read on the capture queue, which are different threads by design.
///
/// Landmark detection runs on EVERY frame the hardware can service — see the "how the
/// tracking stays locked" note at the top of the file for why that beats the old
/// detect-then-track split. The `busy` flag drops a frame rather than queue work up when a
/// detection is still in flight, and the One Euro filter in `publish` carries any gap so a
/// dropped frame never shows.
final class ClipFaceDetector {

    private let queue = DispatchQueue(label: "voiid.clip.face", qos: .userInitiated)
    private let lock = NSLock()
    private var _latest: [TrackedFace] = []
    private var busy = false

    /// Smoothing state, one filter per tracked quantity. Reset when the face is (re)acquired.
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
        let request = VNDetectFaceLandmarksRequest()
        // Newest revision, and the cheaper 65-point constellation where it is supported —
        // this effect only needs the eyes and the nose, so the extra 11 points of the
        // 76-point model would be paid for and thrown away.
        if let newest = VNDetectFaceLandmarksRequest.supportedRevisions.max() {
            request.revision = newest
            if VNDetectFaceLandmarksRequest.revision(
                newest, supportsConstellation: .constellation65Points) {
                request.constellation = .constellation65Points
            }
        }

        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, options: [:])
        do { try handler.perform([request]) } catch { return }

        // The largest face by box width: if two people are in frame, the effect follows the
        // nearer one rather than flickering between them.
        guard let face = (request.results ?? [])
            .max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            // No face: clear, so the ears do not hang in the last known spot, and forget the
            // smoothing history so the next face snaps in rather than sliding from here.
            lock.lock(); _latest = []; hadFace = false; lock.unlock()
            return
        }

        let imageSize = CGSize(width: width, height: height)
        let box = CGRect(x: face.boundingBox.minX * width, y: face.boundingBox.minY * height,
                         width: face.boundingBox.width * width,
                         height: face.boundingBox.height * height)

        // Eye centres from the landmark OUTLINES, not the pupils: a pupil point drops out
        // mid-blink, an outline centroid does not.
        let left = centroid(face.landmarks?.leftEye, in: imageSize)
        let right = centroid(face.landmarks?.rightEye, in: imageSize)

        // Sensible box-derived fallbacks, used only when a whole eye failed to resolve. Eyes
        // sit a little above the box centre; the nose a little below it.
        var eyeMid = CGPoint(x: box.midX, y: box.minY + box.height * 0.60)
        var eyeDistance = box.width * 0.46
        var roll = CGFloat(face.roll?.doubleValue ?? 0)
        var hasLandmarks = false

        if let l = left, let r = right {
            hasLandmarks = true
            eyeMid = CGPoint(x: (l.x + r.x) / 2, y: (l.y + r.y) / 2)
            eyeDistance = max(1, hypot(r.x - l.x, r.y - l.y))
            // Order the eyes by x so the sign of the angle is independent of which one Vision
            // labelled "left". In the bottom-left image space this atan2 is already in the
            // CCW-positive convention the renderer's `rotated(by:)` expects.
            let (a, b) = l.x <= r.x ? (l, r) : (r, l)
            roll = atan2(b.y - a.y, b.x - a.x)
        }

        let nose = centroid(face.landmarks?.nose, in: imageSize)
            ?? CGPoint(x: box.midX, y: box.minY + box.height * 0.42)

        publish(box: box, eyeMid: eyeMid, eyeDistance: eyeDistance, roll: roll,
                nose: nose, hasLandmarks: hasLandmarks)
    }

    /// Average of a landmark region's points, in image pixels (bottom-left origin).
    private func centroid(_ region: VNFaceLandmarkRegion2D?,
                          in imageSize: CGSize) -> CGPoint? {
        guard let region, region.pointCount > 0 else { return nil }
        let points = region.pointsInImage(imageSize: imageSize)
        guard !points.isEmpty else { return nil }
        let sum = points.reduce(CGPoint.zero) { CGPoint(x: $0.x + $1.x, y: $0.y + $1.y) }
        return CGPoint(x: sum.x / CGFloat(points.count), y: sum.y / CGFloat(points.count))
    }

    /// Run each quantity through its One Euro filter and publish the smoothed face.
    private func publish(box: CGRect, eyeMid: CGPoint, eyeDistance: CGFloat, roll: CGFloat,
                         nose: CGPoint, hasLandmarks: Bool) {
        let now = CFAbsoluteTimeGetCurrent()

        lock.lock()
        // dt for the filter. Clamp to a sane range so a long stall (backgrounding, a slow
        // first frame) neither divides by ~0 nor snaps everything with a huge step.
        let dt = min(0.1, max(1.0 / 60.0, hadFace ? now - lastPublish : 1.0 / 30.0))
        lastPublish = now

        // Snap — by discarding the filter history — when the face is first acquired or when a
        // different face jumps in, so the ears do not glide across the screen from the last
        // head to this one. Ordinary motion never trips this: it is gated on 1.5× the eye
        // span, far beyond a frame's worth of real movement.
        if !hadFace || hypot(eyeMid.x - lastEyeMid.x, eyeMid.y - lastEyeMid.y)
            > eyeDistance * 1.5 {
            smoother = FaceSmoother()
        }
        hadFace = true
        lastEyeMid = eyeMid

        let smoothed = TrackedFace(
            box: box,
            eyeMid: CGPoint(x: smoother.eyeMidX.filter(eyeMid.x, dt: dt),
                            y: smoother.eyeMidY.filter(eyeMid.y, dt: dt)),
            eyeDistance: smoother.dist.filter(eyeDistance, dt: dt),
            roll: smoother.roll.filter(roll, dt: dt),
            nose: CGPoint(x: smoother.noseX.filter(nose.x, dt: dt),
                          y: smoother.noseY.filter(nose.y, dt: dt)),
            hasLandmarks: hasLandmarks)
        _latest = [smoothed]
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

    // ── PLACEMENT TUNING ────────────────────────────────────────────────────────
    // All in eye-distance units. These are the only dials that move the artwork on the
    // head — change them here, not in the transform below, so the model stays in one place.
    //   headSpan  — canvas width; larger = bigger ears. ~3 D wraps the skull.
    //   crownRise — how far above the eye line the crown (and the sprite centre) sits.
    //   noseSpan  — snout diameter.
    private static let headSpan: CGFloat = 3.0
    private static let crownRise: CGFloat = 1.40
    private static let noseSpan: CGFloat = 0.60

    static func apply(_ effect: ClipFaceEffect, to image: CIImage,
                      faces: [TrackedFace]) -> CIImage {
        guard effect != .none, !faces.isEmpty else { return image }

        var output = image
        for face in faces {
            // The scale unit is the INTEROCULAR DISTANCE — rotation- and expression-
            // invariant — falling back to a fraction of box width only when landmarks did
            // not resolve this frame. (0.46 is the eye span's typical share of face width,
            // so the fallback lands at the same size the landmark path does.)
            let unit = face.hasLandmarks ? face.eyeDistance : face.box.width * 0.46
            guard unit > 8 else { continue }   // too small to place convincingly

            guard let sprite = sprite(for: effect) else { continue }

            // ── HEAD MODEL ──────────────────────────────────────────────────────
            // A real head, measured in eye-distances (D). These ratios are roughly
            // anthropometric and are what make the ears sit like Snapchat's rather than
            // float: the head is ~2.2 D wide, the crown sits ~1.4 D above the eye line, so
            // the ear artwork is anchored on the CROWN and spans a canvas ~3 D across —
            // wide enough for a full set of ears to wrap the top of the skull.
            //
            // The sprite is centred on the crown, so tilting the head swings the ears around
            // the top of the skull, which is where ears actually pivot.
            let D = unit
            let spriteSide = D * headSpan
            let scale = spriteSide / referenceSprite

            // `up` is the eye line turned 90° — the head's own vertical axis — so the crown
            // offset follows the head through roll instead of staying screen-vertical.
            let up = CGVector(dx: -sin(face.roll), dy: cos(face.roll))
            let centre = face.hasLandmarks
                ? CGPoint(x: face.eyeMid.x + up.dx * (D * crownRise),
                          y: face.eyeMid.y + up.dy * (D * crownRise))
                : CGPoint(x: face.box.midX, y: face.box.maxY + face.box.height * 0.10)

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

            // The snout sits on the REAL nose landmark now (smoothed alongside the eyes, so
            // it never swims against the ears), scaled off the same eye-distance unit.
            if let noseSprite = noseSprite(for: effect) {
                let noseSide = D * noseSpan
                let noseScale = noseSide / referenceSprite
                var nt = CGAffineTransform.identity
                nt = nt.translatedBy(x: face.nose.x, y: face.nose.y)
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

            // The canvas centre (0.5, 0.5) is the CROWN. Smaller y is ABOVE the head,
            // larger y is down toward the face. Each case draws the LEFT ear; `flipped`
            // mirrors it to the right, so the pair is symmetric by construction.
            switch effect.earStyle {
            case .floppy:
                // Dog: root at the top-left of the skull, flopping down past the temple.
                // Root ≈ (0.34, 0.40) sits just above and left of the crown; the tip reaches
                // out to ≈ (0.07, 0.74), i.e. the side of the head at temple height.
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

            case .upright:
                // Bunny: tall and narrow, rooted at the crown and rising well above it.
                // Root ≈ (0.38, 0.48); tip ≈ (0.30, 0.05) — straight up over the head.
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

            case .round:
                // Koala: big round ear straddling the top-left of the head.
                // Centre ≈ (0.22, 0.40), just above and out from the crown.
                outer.append(UIBezierPath(ovalIn: CGRect(x: w * 0.04, y: h * 0.22,
                                                         width: w * 0.36, height: h * 0.36)))
                inner.append(UIBezierPath(ovalIn: CGRect(x: w * 0.12, y: h * 0.30,
                                                         width: w * 0.20, height: h * 0.20)))
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
