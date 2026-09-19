//
//  FaceFrame.swift
//  Voiid
//
//  The one structure the tracker produces and the renderer consumes.
//  Mirrored field-for-field by FaceFrame.kt on Android — if you change one,
//  change both, or the shared manifests stop meaning the same thing.
//

import Foundation
import simd

/// A single tracked face at a single instant.
///
/// Units are load-bearing. `vertices` are **centimetres in canonical-model
/// space** (origin near the nose bridge, face ≈15.3 cm wide), and `headMatrix`
/// maps that space into metric camera space. Manifest offsets are in the same
/// centimetres and are applied *before* `headMatrix`, which is what makes a
/// prop inherit head rotation without any per-prop maths.
struct FaceFrame {
    /// Capture time, not receipt time. Extrapolation is only correct against
    /// the instant the photons arrived.
    var timestampNanos: Int64 = 0

    /// False when no face is present. The renderer must show a clean camera,
    /// not the last known pose.
    var valid: Bool = false

    /// 478 landmarks. 0..<468 are canonical mesh vertices; 468..<478 are iris
    /// points that have no mesh position and are never rendered as geometry.
    var vertices: [SIMD3<Float>] = []

    /// 52 coefficients, 0…1, in `Blendshape` order.
    var blendshapes: [Float] = []

    /// Canonical space → metric camera space.
    var headMatrix: simd_float4x4 = matrix_identity_float4x4

    var imageWidth: Int = 0
    var imageHeight: Int = 0

    /// True for the front camera. The renderer mirrors at the very end, so
    /// every coordinate in this struct is in unmirrored image space.
    var mirrored: Bool = false

    static let landmarkCount = 478
    static let meshVertexCount = 468
    static let blendshapeCount = 52

    /// Distance between the outer eye corners in canonical centimetres.
    /// Used to scale warp radii and to clamp extrapolation, so both stay
    /// correct as the subject moves toward or away from the camera.
    var interocularCm: Float {
        guard vertices.count > FaceGeometry.eyeOuterRight else { return 8.892 }
        return simd_distance(vertices[FaceGeometry.eyeOuterLeft],
                             vertices[FaceGeometry.eyeOuterRight])
    }
}

/// MediaPipe's 52 blendshapes, in its fixed output order.
///
/// Manifests reference these by NAME and the loader resolves to an index once,
/// so a MediaPipe release that reorders them fails loudly at load rather than
/// silently driving the wrong effect.
enum Blendshape: Int, CaseIterable {
    case neutral = 0
    case browDownLeft, browDownRight, browInnerUp, browOuterUpLeft, browOuterUpRight
    case cheekPuff, cheekSquintLeft, cheekSquintRight
    case eyeBlinkLeft, eyeBlinkRight
    case eyeLookDownLeft, eyeLookDownRight, eyeLookInLeft, eyeLookInRight
    case eyeLookOutLeft, eyeLookOutRight, eyeLookUpLeft, eyeLookUpRight
    case eyeSquintLeft, eyeSquintRight, eyeWideLeft, eyeWideRight
    case jawForward, jawLeft, jawOpen, jawRight
    case mouthClose, mouthDimpleLeft, mouthDimpleRight
    case mouthFrownLeft, mouthFrownRight, mouthFunnel, mouthLeft
    case mouthLowerDownLeft, mouthLowerDownRight
    case mouthPressLeft, mouthPressRight, mouthPucker, mouthRight
    case mouthRollLower, mouthRollUpper, mouthShrugLower, mouthShrugUpper
    case mouthSmileLeft, mouthSmileRight, mouthStretchLeft, mouthStretchRight
    case mouthUpperUpLeft, mouthUpperUpRight
    case noseSneerLeft, noseSneerRight

    /// The exact strings MediaPipe emits, which are also the strings manifests use.
    static let names: [String] = [
        "_neutral", "browDownLeft", "browDownRight", "browInnerUp", "browOuterUpLeft",
        "browOuterUpRight", "cheekPuff", "cheekSquintLeft", "cheekSquintRight",
        "eyeBlinkLeft", "eyeBlinkRight", "eyeLookDownLeft", "eyeLookDownRight",
        "eyeLookInLeft", "eyeLookInRight", "eyeLookOutLeft", "eyeLookOutRight",
        "eyeLookUpLeft", "eyeLookUpRight", "eyeSquintLeft", "eyeSquintRight",
        "eyeWideLeft", "eyeWideRight", "jawForward", "jawLeft", "jawOpen", "jawRight",
        "mouthClose", "mouthDimpleLeft", "mouthDimpleRight", "mouthFrownLeft",
        "mouthFrownRight", "mouthFunnel", "mouthLeft", "mouthLowerDownLeft",
        "mouthLowerDownRight", "mouthPressLeft", "mouthPressRight", "mouthPucker",
        "mouthRight", "mouthRollLower", "mouthRollUpper", "mouthShrugLower",
        "mouthShrugUpper", "mouthSmileLeft", "mouthSmileRight", "mouthStretchLeft",
        "mouthStretchRight", "mouthUpperUpLeft", "mouthUpperUpRight", "noseSneerLeft",
        "noseSneerRight",
    ]

    private static let byName: [String: Int] = {
        var m = [String: Int](minimumCapacity: names.count)
        for (i, n) in names.enumerated() { m[n] = i }
        return m
    }()

    static func index(named name: String) -> Int? { byName[name] }
}
