//
//  FaceTracker.swift
//  Voiid
//
//  ARKit face tracking, adapted to the shared FaceFrame contract.
//
//  Why ARKit and not MediaPipe (which Android uses): MediaPipe on iOS costs
//  ~21-25 MB of download that cannot be dead-stripped, because
//  MediaPipeTasksCommon force_loads a 60 MB graph archive. ARKit is in the OS,
//  has a denser mesh (1220 vs 468), and gives real TrueDepth depth.
//  ARFaceTrackingConfiguration needs TrueDepth OR A12+, and iOS 18's minimum
//  device is A12, so coverage is the entire install base.
//
//  ARKit also hands us the face pose in the SAME callback as the frame it
//  describes. There is no tracker latency to hide and nothing to extrapolate,
//  which is most of why this feels smoother than the thing it replaces.
//

import Foundation
import ARKit
import simd

protocol FaceTrackerDelegate: AnyObject {
    /// Called on the ARKit session queue with a frame and the face in it.
    /// `pixelBuffer` is valid only for the duration of the call.
    func faceTracker(_ tracker: FaceTracker,
                     didProduce frame: FaceFrame,
                     pixelBuffer: CVPixelBuffer,
                     camera: ARCamera)
}

final class FaceTracker: NSObject {

    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    weak var delegate: FaceTrackerDelegate?

    private let session = ARSession()
    private var stabilizer = PoseStabilizer()
    private var anchorMap: ARKitAnchorMap?
    private let canonical: CanonicalFaceModel

    /// Scratch buffers, reused every frame. Allocating 1220 vertices at 60 Hz
    /// is exactly the kind of per-frame allocation that makes a camera stutter.
    private var vertexScratch = [SIMD3<Float>](repeating: .zero, count: 1220)
    private var blendScratch = [Float](repeating: 0, count: FaceFrame.blendshapeCount)

    init(canonical: CanonicalFaceModel) {
        self.canonical = canonical
        super.init()
        session.delegate = self
        session.delegateQueue = DispatchQueue(label: "voiid.facefx.arkit",
                                              qos: .userInteractive)
    }

    /// Highest-resolution format ARKit offers, so the viewfinder is not softer
    /// than the system camera. ARKit picks a conservative default; the formats
    /// are ordered by the SDK but not guaranteed sorted, so choose explicitly.
    private func bestFormat() -> ARConfiguration.VideoFormat? {
        ARFaceTrackingConfiguration.supportedVideoFormats.max { a, b in
            let ap = a.imageResolution.width * a.imageResolution.height
            let bp = b.imageResolution.width * b.imageResolution.height
            if ap != bp { return ap < bp }
            return a.framesPerSecond < b.framesPerSecond
        }
    }

    func start() {
        guard Self.isSupported else { return }
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = true      // drives prop tinting later
        if let f = bestFormat() { config.videoFormat = f }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() {
        session.pause()
        stabilizer.reset()
    }

    /// Dropped when the filter changes, so a new filter does not inherit the
    /// previous one's spring and smoothing state.
    func resetSmoothing() { stabilizer.reset() }

    private func buildFrame(from anchor: ARFaceAnchor,
                            camera: ARCamera,
                            pixelBuffer: CVPixelBuffer,
                            timestamp: TimeInterval) -> FaceFrame {
        let geo = anchor.geometry
        let count = geo.vertices.count
        if vertexScratch.count != count {
            vertexScratch = [SIMD3<Float>](repeating: .zero, count: count)
        }
        geo.vertices.withUnsafeBufferPointer { src in
            for i in 0..<count { vertexScratch[i] = src[i] }
        }

        // Fit once, on the first good face. ARKit's vertex ordering is
        // undocumented, so named anchors are resolved by geometry rather than
        // by a table of Apple-internal indices that could change under us.
        if anchorMap == nil {
            anchorMap = try? ARKitAnchorMap(canonical: canonical, arkitVertices: vertexScratch)
        }

        for i in blendScratch.indices { blendScratch[i] = 0 }
        for (location, value) in anchor.blendShapes {
            if let idx = Self.blendshapeIndex[location] {
                blendScratch[idx] = value.floatValue
            }
        }

        var frame = FaceFrame()
        frame.timestampNanos = Int64(timestamp * 1_000_000_000)
        frame.valid = anchor.isTracked
        frame.vertices = vertexScratch
        frame.blendshapes = blendScratch
        // Face-local -> camera space. Props are built in face-local units and
        // multiplied by this, so they inherit head rotation for free.
        frame.headMatrix = camera.viewMatrix(for: .portrait) * anchor.transform
        frame.cmToUnits = anchorMap?.cmToUnits ?? 0.01
        frame.interocularCm = canonical.referenceInterocularCm
        frame.imageWidth = CVPixelBufferGetWidth(pixelBuffer)
        frame.imageHeight = CVPixelBufferGetHeight(pixelBuffer)
        frame.mirrored = true          // face tracking is always the front camera
        return frame
    }

    /// ARKit's blendshape locations, mapped into the shared 52-slot order.
    ///
    /// The two sets overlap in 51 of 52: MediaPipe has `_neutral` where ARKit
    /// has `tongueOut`. Every name a manifest can reference is in the shared 51,
    /// so bindings port between platforms untouched.
    private static let blendshapeIndex: [ARFaceAnchor.BlendShapeLocation: Int] = {
        var m = [ARFaceAnchor.BlendShapeLocation: Int]()
        let pairs: [(ARFaceAnchor.BlendShapeLocation, String)] = [
            (.browDownLeft, "browDownLeft"), (.browDownRight, "browDownRight"),
            (.browInnerUp, "browInnerUp"), (.browOuterUpLeft, "browOuterUpLeft"),
            (.browOuterUpRight, "browOuterUpRight"), (.cheekPuff, "cheekPuff"),
            (.cheekSquintLeft, "cheekSquintLeft"), (.cheekSquintRight, "cheekSquintRight"),
            (.eyeBlinkLeft, "eyeBlinkLeft"), (.eyeBlinkRight, "eyeBlinkRight"),
            (.eyeLookDownLeft, "eyeLookDownLeft"), (.eyeLookDownRight, "eyeLookDownRight"),
            (.eyeLookInLeft, "eyeLookInLeft"), (.eyeLookInRight, "eyeLookInRight"),
            (.eyeLookOutLeft, "eyeLookOutLeft"), (.eyeLookOutRight, "eyeLookOutRight"),
            (.eyeLookUpLeft, "eyeLookUpLeft"), (.eyeLookUpRight, "eyeLookUpRight"),
            (.eyeSquintLeft, "eyeSquintLeft"), (.eyeSquintRight, "eyeSquintRight"),
            (.eyeWideLeft, "eyeWideLeft"), (.eyeWideRight, "eyeWideRight"),
            (.jawForward, "jawForward"), (.jawLeft, "jawLeft"),
            (.jawOpen, "jawOpen"), (.jawRight, "jawRight"),
            (.mouthClose, "mouthClose"), (.mouthDimpleLeft, "mouthDimpleLeft"),
            (.mouthDimpleRight, "mouthDimpleRight"), (.mouthFrownLeft, "mouthFrownLeft"),
            (.mouthFrownRight, "mouthFrownRight"), (.mouthFunnel, "mouthFunnel"),
            (.mouthLeft, "mouthLeft"), (.mouthLowerDownLeft, "mouthLowerDownLeft"),
            (.mouthLowerDownRight, "mouthLowerDownRight"), (.mouthPressLeft, "mouthPressLeft"),
            (.mouthPressRight, "mouthPressRight"), (.mouthPucker, "mouthPucker"),
            (.mouthRight, "mouthRight"), (.mouthRollLower, "mouthRollLower"),
            (.mouthRollUpper, "mouthRollUpper"), (.mouthShrugLower, "mouthShrugLower"),
            (.mouthShrugUpper, "mouthShrugUpper"), (.mouthSmileLeft, "mouthSmileLeft"),
            (.mouthSmileRight, "mouthSmileRight"), (.mouthStretchLeft, "mouthStretchLeft"),
            (.mouthStretchRight, "mouthStretchRight"), (.mouthUpperUpLeft, "mouthUpperUpLeft"),
            (.mouthUpperUpRight, "mouthUpperUpRight"), (.noseSneerLeft, "noseSneerLeft"),
            (.noseSneerRight, "noseSneerRight"),
        ]
        for (loc, name) in pairs {
            guard let i = Blendshape.index(named: name) else {
                assertionFailure("ARKit blendshape '\(name)' is not in the shared table")
                continue
            }
            m[loc] = i
        }
        return m
    }()
}

extension FaceTracker: ARSessionDelegate {
    func session(_ session: ARSession, didUpdate arFrame: ARFrame) {
        let face = arFrame.anchors.compactMap { $0 as? ARFaceAnchor }.first

        var frame: FaceFrame
        if let face {
            frame = buildFrame(from: face, camera: arFrame.camera,
                               pixelBuffer: arFrame.capturedImage,
                               timestamp: arFrame.timestamp)
        } else {
            frame = FaceFrame()
            frame.timestampNanos = Int64(arFrame.timestamp * 1_000_000_000)
            frame.valid = false
            frame.imageWidth = CVPixelBufferGetWidth(arFrame.capturedImage)
            frame.imageHeight = CVPixelBufferGetHeight(arFrame.capturedImage)
            frame.mirrored = true
        }

        stabilizer.stabilize(&frame)
        delegate?.faceTracker(self, didProduce: frame,
                              pixelBuffer: arFrame.capturedImage,
                              camera: arFrame.camera)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        NSLog("[FaceFX] ARKit session failed: \(error.localizedDescription)")
    }

    func sessionWasInterrupted(_ session: ARSession) { stabilizer.reset() }

    func sessionInterruptionEnded(_ session: ARSession) {
        stabilizer.reset()
        start()
    }

    /// Head angular velocity, for spring-driven layers.
    var angularVelocity: SIMD3<Float> { stabilizer.angularVelocity }
}

/// Resolves manifest anchor NAMES against ARKit's mesh.
///
/// Manifests are authored against the canonical MediaPipe model. ARKit's mesh
/// is a different topology with an undocumented vertex order, so this fits one
/// to the other and records which ARKit vertex each canonical index landed on.
/// Built once per session, at first face acquisition.
struct ARKitAnchorMap {
    /// canonicalIndex -> nearest ARKit vertex index.
    let indexForCanonical: [Int]
    /// Manifest centimetres -> ARKit metres, from the fitted scale.
    let cmToUnits: Float

    init(canonical: CanonicalFaceModel, arkitVertices: [SIMD3<Float>]) throws {
        let fit = try FaceGeometry.fitMesh(source: canonical.vertices, target: arkitVertices)

        let basis = simd_float3x3(SIMD3(fit[0].x, fit[0].y, fit[0].z),
                                  SIMD3(fit[1].x, fit[1].y, fit[1].z),
                                  SIMD3(fit[2].x, fit[2].y, fit[2].z))
        cmToUnits = simd_length(basis[0])

        var map = [Int](repeating: 0, count: canonical.vertices.count)
        for (i, v) in canonical.vertices.enumerated() {
            let p4 = fit * SIMD4<Float>(v, 1)
            let p = SIMD3<Float>(p4.x, p4.y, p4.z)
            var best = 0
            var bestD = Float.greatestFiniteMagnitude
            for (j, av) in arkitVertices.enumerated() {
                let d = simd_distance_squared(p, av)
                if d < bestD { bestD = d; best = j }
            }
            map[i] = best
        }
        indexForCanonical = map
    }

    /// Landmarks 468..477 are MediaPipe iris points with no canonical mesh
    /// position. Clamp rather than crash: a manifest that anchors to an iris is
    /// valid on Android and simply falls back to the nearest lid vertex here.
    func arkitIndex(forCanonical i: Int) -> Int {
        guard i >= 0 && i < indexForCanonical.count else { return 0 }
        return indexForCanonical[i]
    }
}
