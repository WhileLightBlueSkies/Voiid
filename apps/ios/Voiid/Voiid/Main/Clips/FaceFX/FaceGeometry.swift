//
//  FaceGeometry.swift
//  Voiid
//
//  Canonical face model, named anchors, and the similarity fit that lets ONE
//  set of manifests drive two different face meshes.
//
//  Pure Swift + simd on purpose: no UIKit, no ARKit, no Metal. It is the piece
//  most worth testing, and keeping it dependency-free means it can be tested
//  on the host with `swift FaceGeometryTests.swift`.
//

import Foundation
import simd

/// The canonical face model shipped in `packages/facefx/canonical/face_model.json`.
///
/// This is MediaPipe's mesh, and it is the coordinate system every manifest is
/// authored against — **centimetres**, origin near the nose bridge, +X to the
/// subject's right in image space, +Y up, +Z out of the face.
///
/// Android renders this mesh directly. iOS uses ARKit's 1220-vertex mesh
/// instead, and reaches it through `AnchorMap` below.
struct CanonicalFaceModel: Decodable {
    let meshVertexCount: Int
    let landmarkCount: Int
    let referenceInterocularCm: Float
    let vertices: [SIMD3<Float>]
    let uvs: [SIMD2<Float>]
    let triangles: [UInt16]
    let loops: [String: [Int]]
    let named: [String: Int]

    private enum CodingKeys: String, CodingKey {
        case meshVertexCount, landmarkCount, referenceInterocularCm
        case vertices, uvs, triangles, loops, named
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        meshVertexCount = try c.decode(Int.self, forKey: .meshVertexCount)
        landmarkCount = try c.decode(Int.self, forKey: .landmarkCount)
        referenceInterocularCm = try c.decode(Float.self, forKey: .referenceInterocularCm)

        let v = try c.decode([[Float]].self, forKey: .vertices)
        vertices = v.map { SIMD3<Float>($0[0], $0[1], $0[2]) }

        let t = try c.decode([[Float]].self, forKey: .uvs)
        uvs = t.map { SIMD2<Float>($0[0], $0[1]) }

        let tri = try c.decode([[Int]].self, forKey: .triangles)
        triangles = tri.flatMap { $0.map(UInt16.init) }

        loops = try c.decode([String: [Int]].self, forKey: .loops)
        named = try c.decode([String: Int].self, forKey: .named)
    }

    static func load(from url: URL) throws -> CanonicalFaceModel {
        try JSONDecoder().decode(CanonicalFaceModel.self, from: Data(contentsOf: url))
    }

    /// Bundled alongside the app. Fatal if missing: every filter depends on it,
    /// so a build that shipped without it is broken in a way worth failing loudly.
    static func loadBundled() throws -> CanonicalFaceModel {
        guard let url = Bundle.main.url(forResource: "face_model", withExtension: "json") else {
            throw FaceGeometryError.canonicalModelMissing
        }
        return try load(from: url)
    }
}

enum FaceGeometryError: Error {
    case canonicalModelMissing
    case degenerateCorrespondences
}

enum FaceGeometry {
    // Indices into the CANONICAL mesh, used directly by the Android path and as
    // the reference for the ARKit fit. Verified against face_model.json.
    static let noseTip = 1
    static let chin = 152
    static let foreheadCenter = 10
    static let faceEdgeLeft = 234
    static let faceEdgeRight = 454
    static let eyeOuterLeft = 33
    static let eyeOuterRight = 263

    /// Seed correspondences for aligning an unknown face mesh to the canonical
    /// one.
    ///
    /// Each is a geometric EXTREME rather than a named landmark, because ARKit's
    /// vertex ordering is undocumented and not contractual — extremity is
    /// something we can evaluate on both meshes without knowing either's layout.
    ///
    /// The extreme is defined *by the operation*, applied to both meshes. Do not
    /// reintroduce a hardcoded canonical index here: the leftmost canonical
    /// vertex is 127 (`templeLeft`, x = −7.743), not 234 (`faceEdgeLeft`,
    /// x = −7.664), and pairing a named index against a located extreme silently
    /// fits mismatched points.
    enum Extreme: CaseIterable {
        case noseTip        // greatest +Z
        case chin           // least  −Y
        case forehead       // greatest +Y
        case edgeLeft       // least  −X
        case edgeRight      // greatest +X

        /// Find this feature on any mesh by its extremity alone.
        func locate(in verts: [SIMD3<Float>]) -> SIMD3<Float> {
            switch self {
            case .noseTip:   return verts.max { $0.z < $1.z } ?? .zero
            case .chin:      return verts.min { $0.y < $1.y } ?? .zero
            case .forehead:  return verts.max { $0.y < $1.y } ?? .zero
            case .edgeLeft:  return verts.min { $0.x < $1.x } ?? .zero
            case .edgeRight: return verts.max { $0.x < $1.x } ?? .zero
            }
        }
    }

    /// Fit `source` onto `target`: five extremes for a coarse seed, then ICP to
    /// refine.
    ///
    /// The seed alone is exact only when the two meshes share an orientation.
    /// Face-local spaces conventionally do, but "conventionally" is not a
    /// guarantee worth betting every anchor on, and axis-aligned extremes are
    /// not preserved under rotation. ICP costs a few milliseconds ONCE, at first
    /// face acquisition, and removes the assumption.
    static func fitMesh(source: [SIMD3<Float>],
                        target: [SIMD3<Float>],
                        iterations: Int = 12) throws -> simd_float4x4 {
        let seedSrc = Extreme.allCases.map { $0.locate(in: source) }
        let seedDst = Extreme.allCases.map { $0.locate(in: target) }
        var fit = try similarityTransform(from: seedSrc, to: seedDst)

        guard !target.isEmpty else { return fit }

        var prev = Float.greatestFiniteMagnitude
        for _ in 0..<iterations {
            var moved = [SIMD3<Float>](); moved.reserveCapacity(source.count)
            var pairs = [SIMD3<Float>](); pairs.reserveCapacity(source.count)
            var rms: Float = 0

            for v in source {
                let p4 = fit * SIMD4<Float>(v, 1)
                let p = SIMD3<Float>(p4.x, p4.y, p4.z)
                var best = target[0]
                var bestD = Float.greatestFiniteMagnitude
                for t in target {
                    let d = simd_distance_squared(p, t)
                    if d < bestD { bestD = d; best = t }
                }
                moved.append(v)
                pairs.append(best)
                rms += bestD
            }
            rms = (rms / Float(source.count)).squareRoot()
            fit = try similarityTransform(from: moved, to: pairs)
            // Converged once the residual stops improving materially.
            if abs(prev - rms) < prev * 1e-4 { break }
            prev = rms
        }
        return fit
    }

    /// Umeyama similarity fit: the rotation, uniform scale and translation that
    /// best map `from` onto `to` in a least-squares sense.
    ///
    /// Used to express the canonical model in ARKit's face space without any
    /// hardcoded Apple-internal vertex indices — those are undocumented and not
    /// contractual, so deriving the mapping is more durable than tabulating it.
    static func similarityTransform(from src: [SIMD3<Float>],
                                    to dst: [SIMD3<Float>]) throws -> simd_float4x4 {
        precondition(src.count == dst.count && src.count >= 3)
        let n = Float(src.count)

        let muS = src.reduce(SIMD3<Float>.zero, +) / n
        let muD = dst.reduce(SIMD3<Float>.zero, +) / n

        var sigmaS: Float = 0
        var cov = simd_float3x3(0)
        for i in 0..<src.count {
            let a = src[i] - muS
            let b = dst[i] - muD
            sigmaS += simd_length_squared(a)
            cov += simd_float3x3(b * a.x, b * a.y, b * a.z)   // outer product b·aᵀ
        }
        sigmaS /= n
        cov *= (1 / n)

        guard sigmaS > 1e-12 else { throw FaceGeometryError.degenerateCorrespondences }

        let (u, s, vt) = svd3(cov)
        // Guard against a reflection: a mirrored fit would silently swap left
        // and right, which is the single most confusing failure mode here.
        var d = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))
        if simd_determinant(u) * simd_determinant(vt) < 0 { d[2][2] = -1 }

        let r = u * d * vt
        let scale = (s.x * d[0][0] + s.y * d[1][1] + s.z * d[2][2]) / sigmaS
        let t = muD - scale * (r * muS)

        let sr = r * scale
        return simd_float4x4(
            SIMD4<Float>(sr[0], 0), SIMD4<Float>(sr[1], 0),
            SIMD4<Float>(sr[2], 0), SIMD4<Float>(t, 1))
    }

    /// One-sided Jacobi SVD for the 3×3 case. Small, exact enough, and avoids
    /// pulling in Accelerate for nine numbers.
    static func svd3(_ m: simd_float3x3) -> (u: simd_float3x3, s: SIMD3<Float>, vt: simd_float3x3) {
        var a = m
        var v = simd_float3x3(diagonal: SIMD3<Float>(1, 1, 1))

        for _ in 0..<32 {
            var off: Float = 0
            for p in 0..<2 {
                for q in (p + 1)..<3 {
                    let apq = simd_dot(a[p], a[q])
                    off += apq * apq
                    guard abs(apq) > 1e-12 else { continue }
                    let app = simd_length_squared(a[p])
                    let aqq = simd_length_squared(a[q])
                    let tau = (aqq - app) / (2 * apq)
                    let t = (tau >= 0 ? 1 : -1) / (abs(tau) + (1 + tau * tau).squareRoot())
                    let c = 1 / (1 + t * t).squareRoot()
                    let s = c * t
                    let ap = a[p], aq = a[q]
                    a[p] = c * ap - s * aq
                    a[q] = s * ap + c * aq
                    let vp = v[p], vq = v[q]
                    v[p] = c * vp - s * vq
                    v[q] = s * vp + c * vq
                }
            }
            if off < 1e-18 { break }
        }

        var s = SIMD3<Float>(simd_length(a[0]), simd_length(a[1]), simd_length(a[2]))
        var u = a
        for i in 0..<3 {
            if s[i] > 1e-12 { u[i] = a[i] / s[i] } else { u[i] = SIMD3<Float>(i == 0 ? 1 : 0, i == 1 ? 1 : 0, i == 2 ? 1 : 0); s[i] = 0 }
        }
        return (u, s, v.transpose)
    }
}
