//
//  FXManifest.swift
//  Voiid
//
//  The filter contract, parsed. Mirrors packages/facefx/build/schema.mjs and
//  FxManifest.kt. Filter BEHAVIOUR lives here as data — if you find yourself
//  writing `switch manifest.id` in renderer code, the schema is missing
//  something and that is the thing to fix.
//

import Foundation
import simd

enum FXPass: String, Codable, CaseIterable, Comparable {
    case beauty, colour, warp, faceTexture, occluder, props, ambient

    /// Canonical execution order. A manifest lists a subset; the order is fixed.
    var order: Int { FXPass.allCases.firstIndex(of: self)! }
    static func < (a: FXPass, b: FXPass) -> Bool { a.order < b.order }
}

enum FXBillboard: String, Codable { case none, y, full }
enum FXBlend: String, Codable { case normal, multiply, screen, overlay }
enum FXWarpMode: String, Codable { case magnify, pinch, translate }
enum FXPhysicsDriver: String, Codable {
    case headRollVelocity, headYawVelocity, headPitchVelocity
}

/// Which property of a layer a blendshape drives.
enum FXBindingTarget: String, Codable {
    case scaleX = "scale.x", scaleY = "scale.y", scaleUniform = "scale.uniform"
    case opacity
    case offsetX = "offset.x", offsetY = "offset.y", offsetZ = "offset.z"
    case rotationZ = "rotation.z"
    case atlasFrame

    /// Several bindings on one target combine: scale and opacity multiply,
    /// offsets and rotation sum. Defined once here so both platforms agree.
    var isMultiplicative: Bool {
        switch self {
        case .scaleX, .scaleY, .scaleUniform, .opacity: return true
        default: return false
        }
    }
}

/// A barycentric blend of mesh vertices plus a head-local offset.
///
/// Several vertices rather than one, so a single jittery landmark cannot move
/// a prop on its own.
struct FXAnchor: Codable {
    let indices: [Int]
    let weights: [Float]

    func resolve(in vertices: [SIMD3<Float>]) -> SIMD3<Float> {
        var p = SIMD3<Float>.zero
        for (i, idx) in indices.enumerated() where idx < vertices.count {
            p += vertices[idx] * weights[i]
        }
        return p
    }
}

struct FXBinding: Codable {
    let blendshape: String
    let target: FXBindingTarget
    let inRange: [Float]
    let outRange: [Float]

    /// Resolved at load so the hot path never does a dictionary lookup.
    var blendshapeIndex: Int { Blendshape.index(named: blendshape) ?? 0 }

    func evaluate(_ value: Float) -> Float {
        let lo = inRange[0], hi = inRange[1]
        guard hi > lo else { return outRange[0] }
        let t = simd_smoothstep(lo, hi, value)
        return outRange[0] + (outRange[1] - outRange[0]) * t
    }
}

struct FXPhysics: Codable {
    let type: String
    let driver: FXPhysicsDriver
    let stiffness: Float
    let damping: Float
    let maxDeg: Float
}

struct FXLayer: Codable {
    let id: String
    let type: String
    let atlasRect: [Float]
    let anchor: FXAnchor
    let offsetCm: [Float]
    let sizeCm: [Float]
    let rotationDeg: [Float]
    let billboard: FXBillboard
    let depthTest: Bool
    let depthWrite: Bool
    let order: Int
    let physics: FXPhysics?
    let bindings: [FXBinding]?

    var offset: SIMD3<Float> { SIMD3(offsetCm[0], offsetCm[1], offsetCm[2]) }
    var size: SIMD2<Float> { SIMD2(sizeCm[0], sizeCm[1]) }
    var rotationRadians: SIMD3<Float> {
        SIMD3(rotationDeg[0], rotationDeg[1], rotationDeg[2]) * (.pi / 180)
    }
}

struct FXWarp: Codable {
    let id: String
    let anchor: FXAnchor
    let radiusCm: Float
    let mode: FXWarpMode
    let strength: Float
    let direction: [Float]?
}

struct FXFaceTexture: Codable {
    let id: String
    let atlasRect: [Float]
    let opacity: Float
    let blend: FXBlend
}

struct FXParticleEmitter: Codable {
    struct Trigger: Codable { let blendshape: String; let above: Float }
    let id: String
    let atlasRect: [Float]
    let emitAnchor: FXAnchor
    let trigger: Trigger
    let rate: Float
    let lifetimeMs: Float
    let gravityCm: [Float]
    let speedCm: [Float]
    let maxParticles: Int
}

struct FXBeauty: Codable {
    let smooth: Float
    let brighten: Float
    static let none = FXBeauty(smooth: 0, brighten: 0)
}

struct FXColour: Codable {
    let lut: String?
    let saturation: Float
    let contrast: Float
    static let none = FXColour(lut: nil, saturation: 1, contrast: 1)
}

struct FXManifest: Codable {
    let schema: Int
    let id: String
    let version: Int
    let name: String
    let tier: Int
    let bundled: Bool
    let passes: [FXPass]
    let atlas: String?
    let atlasSize: [Int]?
    let beauty: FXBeauty?
    let colour: FXColour?
    let warps: [FXWarp]?
    let faceTextures: [FXFaceTexture]?
    let layers: [FXLayer]?
    let particles: [FXParticleEmitter]?

    static let currentSchema = 1

    /// Layers in draw order, resolved once at load.
    var sortedLayers: [FXLayer] { (layers ?? []).sorted { $0.order < $1.order } }

    func has(_ pass: FXPass) -> Bool { passes.contains(pass) }

    /// Rejects a manifest the renderer could not honour.
    ///
    /// Deliberately strict and total: a manifest is either applied whole or
    /// skipped whole. Partially applying one produces a filter that is subtly
    /// wrong in a way nobody can debug from a screenshot.
    func validate() throws {
        guard schema == Self.currentSchema else {
            throw FXManifestError.unsupportedSchema(schema)
        }
        guard passes == passes.sorted() else {
            throw FXManifestError.passesOutOfOrder(id)
        }
        for b in (layers ?? []).flatMap({ $0.bindings ?? [] }) {
            guard Blendshape.index(named: b.blendshape) != nil else {
                throw FXManifestError.unknownBlendshape(b.blendshape)
            }
        }
        for e in particles ?? [] {
            guard Blendshape.index(named: e.trigger.blendshape) != nil else {
                throw FXManifestError.unknownBlendshape(e.trigger.blendshape)
            }
        }
        var seen = Set<Int>()
        for l in layers ?? [] {
            guard seen.insert(l.order).inserted else {
                throw FXManifestError.duplicateLayerOrder(l.order)
            }
            guard abs(l.anchor.weights.reduce(0, +) - 1) <= 0.001 else {
                throw FXManifestError.anchorWeightsNotNormalised(l.id)
            }
        }
    }

    static func decode(_ data: Data) throws -> FXManifest {
        let m = try JSONDecoder().decode(FXManifest.self, from: data)
        try m.validate()
        return m
    }
}

enum FXManifestError: Error, CustomStringConvertible {
    case unsupportedSchema(Int)
    case passesOutOfOrder(String)
    case unknownBlendshape(String)
    case duplicateLayerOrder(Int)
    case anchorWeightsNotNormalised(String)

    var description: String {
        switch self {
        case .unsupportedSchema(let v):        return "unsupported manifest schema \(v)"
        case .passesOutOfOrder(let id):        return "\(id): passes are not in canonical order"
        case .unknownBlendshape(let n):        return "unknown blendshape '\(n)'"
        case .duplicateLayerOrder(let o):      return "two layers share order \(o)"
        case .anchorWeightsNotNormalised(let l): return "layer '\(l)': anchor weights do not sum to 1"
        }
    }
}
