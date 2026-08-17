//
//  LudoDie.swift
//  Voiid
//
//  A die that tumbles as a SOLID (docs/games/VISUALS_AUDIO_AND_PARITY.md §5.3).
//
//  WHY THIS EXISTS. The die was a flat pip face with a face-swap tumble, and it is the most-
//  watched object in the game — it is on screen for every single turn. Ludo King's die tumbles
//  as a cube, and that is most of why its rolls feel like rolls.
//
//  HAND-PROJECTED, NOT A 3D FRAMEWORK. This is the exact trade `CoinView.kt` already made for
//  the coin: adding Filament (or SceneKit on one platform only) for one spinning object is a
//  bad deal, and a cube is EASIER than a cylinder — eight vertices, a fixed camera, back-face
//  culling, three visible faces. Under a hundred lines, identical on both platforms, no
//  dependency, and no parity asymmetry of the kind the coin had to accept.
//
//  THE LANDED FACE IS THE SERVER'S. The tumble is presentation; the frame is the truth. Nothing
//  in this file ever picks a number — `face` comes in from `LudoState.die` and the rotation
//  settles to show it.
//
//  Mirrors Android `LudoDie.kt`.
//

import SwiftUI

struct LudoDie: View {
    /// The face to land on. The tumble settles to show exactly this.
    let face: Int
    /// 0 = settled, 1 = mid-tumble. Driven by the caller's animation.
    var tumble: Double = 0
    var pipColor: Color = Color(red: 0.16, green: 0.14, blue: 0.18)
    var bodyColor: Color = .white

    var body: some View {
        Canvas { ctx, size in
            draw(ctx: ctx, size: size)
        }
    }

    // MARK: - Geometry

    /// The eight corners of a unit cube.
    private static let corners: [SIMD3<Double>] = [
        SIMD3(-1, -1, -1), SIMD3(1, -1, -1), SIMD3(1, 1, -1), SIMD3(-1, 1, -1),
        SIMD3(-1, -1, 1), SIMD3(1, -1, 1), SIMD3(1, 1, 1), SIMD3(-1, 1, 1),
    ]

    /// The six faces, as corner indices, with the die value each one carries.
    ///
    /// Opposite faces sum to 7, as on a real die. That is not decoration — a player who can see
    /// two faces at once will notice if the arithmetic is wrong.
    private static let faces: [(indices: [Int], value: Int)] = [
        ([4, 5, 6, 7], 1),   // +z
        ([1, 2, 6, 5], 2),   // +x
        ([3, 2, 6, 7], 3),   // +y
        ([0, 1, 5, 4], 4),   // -y
        ([0, 3, 7, 4], 5),   // -x
        ([0, 1, 2, 3], 6),   // -z
    ]

    /// Rotation that brings `value`'s face toward the camera, so the die SETTLES on the server's
    /// number rather than landing on whatever the tumble happened to leave facing out.
    private static func restRotation(for value: Int) -> (x: Double, y: Double) {
        switch value {
        case 1:  return (0, 0)
        case 2:  return (0, -.pi / 2)
        case 3:  return (.pi / 2, 0)
        case 4:  return (-.pi / 2, 0)
        case 5:  return (0, .pi / 2)
        default: return (.pi, 0)
        }
    }

    private func rotate(_ p: SIMD3<Double>, x: Double, y: Double) -> SIMD3<Double> {
        // Y first, then X. Order is fixed so the rest rotations above stay correct.
        let cy = cos(y), sy = sin(y)
        let a = SIMD3(p.x * cy + p.z * sy, p.y, -p.x * sy + p.z * cy)
        let cx = cos(x), sx = sin(x)
        return SIMD3(a.x, a.y * cx - a.z * sx, a.y * sx + a.z * cx)
    }

    /// Weak perspective. A real projection matrix would be more code for a difference nobody
    /// can see on a 64 pt die.
    private func project(_ p: SIMD3<Double>, half: CGFloat) -> CGPoint {
        let depth = 4.2
        let k = depth / (depth - p.z * 0.45)
        return CGPoint(x: half + CGFloat(p.x * k) * half * 0.52,
                       y: half + CGFloat(p.y * k) * half * 0.52)
    }

    private func draw(ctx: GraphicsContext, size: CGSize) {
        let half = min(size.width, size.height) / 2
        let rest = Self.restRotation(for: max(1, min(6, face)))
        // TUMBLE ON TWO AXES, settling to the rest rotation. Two, not one: a die spinning on a
        // single axis reads as a wheel.
        let rx = rest.x + tumble * 4.2 * .pi
        let ry = rest.y + tumble * 3.1 * .pi

        let rotated = Self.corners.map { rotate($0, x: rx, y: ry) }
        let projected = rotated.map { project($0, half: half) }

        // BACK-FACE CULLING by winding order, then paint back-to-front. Three faces are visible
        // on a cube from any angle; drawing all six in order would put a back face over a front.
        var visible: [(z: Double, path: Path, value: Int)] = []
        for face in Self.faces {
            let pts = face.indices.map { projected[$0] }
            // Signed area: negative means the face is turned away.
            var area: CGFloat = 0
            for i in 0..<pts.count {
                let a = pts[i], b = pts[(i + 1) % pts.count]
                area += (b.x - a.x) * (b.y + a.y)
            }
            guard area > 0 else { continue }

            var path = Path()
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            path.closeSubpath()

            let depth = face.indices.map { rotated[$0].z }.reduce(0, +) / Double(face.indices.count)
            visible.append((depth, path, face.value))
        }
        visible.sort { $0.z < $1.z }

        for entry in visible {
            // Faces angled away from the light are darker — one directional shade is what makes
            // the cube read as a solid rather than as three flat quads.
            let shade = 0.72 + 0.28 * ((entry.z + 1) / 2)
            // Fill, then darken with black at the complement — a real multiply, rather than
            // dropping the fill's own alpha, which would let the board show through the die.
            ctx.fill(entry.path, with: .color(bodyColor))
            ctx.fill(entry.path, with: .color(.black.opacity(1 - shade)))
            ctx.stroke(entry.path, with: .color(pipColor.opacity(0.30)), lineWidth: 0.8)
            drawPips(ctx: ctx, in: entry.path.boundingRect, value: entry.value, shade: shade)
        }
    }

    /// Pips on a face, laid out in the face's own bounding box.
    ///
    /// An approximation — the exact thing would project each pip through the same transform —
    /// but at this size the difference is under a pixel and the box is stable.
    private func drawPips(ctx: GraphicsContext, in rect: CGRect, value: Int, shade: Double) {
        let layouts: [Int: [(Int, Int)]] = [
            1: [(1, 1)],
            2: [(0, 0), (2, 2)],
            3: [(0, 0), (1, 1), (2, 2)],
            4: [(0, 0), (2, 0), (0, 2), (2, 2)],
            5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
            6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
        ]
        let unitW = rect.width / 3
        let unitH = rect.height / 3
        let r = min(unitW, unitH) * 0.22
        for p in layouts[value] ?? [] {
            let c = CGPoint(x: rect.minX + (CGFloat(p.0) + 0.5) * unitW,
                            y: rect.minY + (CGFloat(p.1) + 0.5) * unitH)
            ctx.fill(
                Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                with: .color(pipColor.opacity(0.55 + 0.45 * shade)))
        }
    }
}
