import Foundation
import simd

// Standalone harness: concatenated with FaceGeometry.swift so the real code is
// what gets exercised, not a copy of it.

func fail(_ m: String) -> Never { print("FAIL: \(m)"); exit(1) }
var checks = 0
func expect(_ cond: Bool, _ m: String) {
    checks += 1
    if !cond { fail(m) }
}

let modelURL = URL(fileURLWithPath: "packages/facefx/canonical/face_model.json")
let model = try! CanonicalFaceModel.load(from: modelURL)
print("loaded canonical model: \(model.vertices.count) verts, \(model.triangles.count/3) tris")
expect(model.vertices.count == 468, "expected 468 canonical vertices")
expect(model.uvs.count == 468, "expected 468 UVs")
expect(model.triangles.count == 898 * 3, "expected 898 triangles")

// --- 1. SVD correctness on a known matrix -----------------------------------
do {
    let m = simd_float3x3(SIMD3<Float>(4, 0, 3), SIMD3<Float>(0, 5, 0), SIMD3<Float>(3, 0, 1))
    let (u, s, vt) = FaceGeometry.svd3(m)
    let recon = u * simd_float3x3(diagonal: s) * vt
    var maxErr: Float = 0
    for c in 0..<3 { for r in 0..<3 { maxErr = max(maxErr, abs(recon[c][r] - m[c][r])) } }
    print(String(format: "  svd3 reconstruction error: %.2e", maxErr))
    expect(maxErr < 1e-4, "svd3 does not reconstruct its input (err \(maxErr))")
    // U and V must be orthonormal
    let uo = u.transpose * u, vo = vt * vt.transpose
    for i in 0..<3 {
        expect(abs(uo[i][i] - 1) < 1e-4, "U not orthonormal")
        expect(abs(vo[i][i] - 1) < 1e-4, "V not orthonormal")
    }
}

// --- 2. Similarity fit recovers a KNOWN transform ----------------------------
// Synthesise an "ARKit-like" mesh: canonical cm -> metres, rotated, translated.
func makeTransform(scale: Float, yawDeg: Float, t: SIMD3<Float>) -> simd_float4x4 {
    let a = yawDeg * .pi / 180
    let r = simd_float3x3(SIMD3<Float>(cos(a), 0, -sin(a)),
                          SIMD3<Float>(0, 1, 0),
                          SIMD3<Float>(sin(a), 0, cos(a)))
    let sr = r * scale
    return simd_float4x4(SIMD4<Float>(sr[0], 0), SIMD4<Float>(sr[1], 0),
                         SIMD4<Float>(sr[2], 0), SIMD4<Float>(t, 1))
}

for (scale, yaw, tv) in [(Float(0.01), Float(0), SIMD3<Float>(0, 0, 0)),
                         (Float(0.01), Float(0), SIMD3<Float>(0, -0.03, 0.02)),
                         (Float(0.0085), Float(11), SIMD3<Float>(0.004, -0.02, 0.05))] {
    let M = makeTransform(scale: scale, yawDeg: yaw, t: tv)
    let fake = model.vertices.map { v -> SIMD3<Float> in
        let p = M * SIMD4<Float>(v, 1); return SIMD3<Float>(p.x, p.y, p.z)
    }

    let fit = try! FaceGeometry.fitMesh(source: model.vertices, target: fake)

    // Every canonical vertex must land on its counterpart.
    var worst: Float = 0
    for (i, v) in model.vertices.enumerated() {
        let p = fit * SIMD4<Float>(v, 1)
        worst = max(worst, simd_distance(SIMD3<Float>(p.x, p.y, p.z), fake[i]))
    }
    let worstMm = worst * 1000 / scale * 0.01   // back to canonical cm, then mm
    print(String(format: "  fit scale=%.4f yaw=%4.1f°  worst vertex error %.3f mm (head-scale)", scale, yaw, worstMm))
    expect(worstMm < 2.0, "similarity fit error \(worstMm) mm exceeds 2 mm")
}

// --- 3. Named-anchor resolution by nearest vertex ----------------------------
do {
    let M = makeTransform(scale: 0.0092, yawDeg: 6, t: SIMD3<Float>(0.002, -0.025, 0.031))
    let fake = model.vertices.map { v -> SIMD3<Float> in
        let p = M * SIMD4<Float>(v, 1); return SIMD3<Float>(p.x, p.y, p.z)
    }
    let fit = try! FaceGeometry.fitMesh(source: model.vertices, target: fake)

    var wrong = 0
    for (name, canonicalIdx) in model.named.sorted(by: { $0.key < $1.key }) {
        let p4 = fit * SIMD4<Float>(model.vertices[canonicalIdx], 1)
        let target = SIMD3<Float>(p4.x, p4.y, p4.z)
        var best = 0
        var bestD = Float.greatestFiniteMagnitude
        for (i, fv) in fake.enumerated() {
            let d = simd_distance_squared(fv, target)
            if d < bestD { bestD = d; best = i }
        }
        if best != canonicalIdx { wrong += 1; print("    mismatch \(name): got \(best) want \(canonicalIdx)") }
    }
    print("  named anchors resolved: \(model.named.count - wrong)/\(model.named.count)")
    expect(wrong == 0, "\(wrong) named anchors resolved to the wrong vertex")
}

// --- 4. Reflection guard ------------------------------------------------------
do {
    // A mirrored mesh must NOT be fitted with a reflection -- that would swap
    // left and right silently, which is the worst possible failure here.
    let mirrored = model.vertices.map { SIMD3<Float>(-$0.x, $0.y, $0.z) }
    let fit = try! FaceGeometry.fitMesh(source: model.vertices, target: mirrored)
    let lin = simd_float3x3(SIMD3<Float>(fit[0].x, fit[0].y, fit[0].z),
                            SIMD3<Float>(fit[1].x, fit[1].y, fit[1].z),
                            SIMD3<Float>(fit[2].x, fit[2].y, fit[2].z))
    print(String(format: "  determinant on mirrored input: %+.4f (must be > 0)", simd_determinant(lin)))
    expect(simd_determinant(lin) > 0, "fit produced a reflection -- left/right would be swapped")
}

print("\n\(checks) checks passed")
