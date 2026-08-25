//
//  LudoDieView.swift
//  Voiid
//
//  The 2.5D projected die (§14). Same cube on both platforms, drawn in Canvas — all six
//  rounded faces and pips code-generated, no texture pipeline, deterministic parity.
//
//  PHYSICALLY CONSISTENT FACES (opposites sum to 7):
//    front +Z = 1   back -Z = 6   right +X = 2   left -X = 5   top -Y = 3   bottom +Y = 4
//
//  At rest the displayed result faces the viewer SQUARE ON and is drawn as a single flat face —
//  the cube projection runs only while the die is tumbling. Pips use the CURRENT ACTIVE HUE on
//  all six faces simultaneously; the body is ONE neutral token in every state and never changes
//  color during a roll or turn change (§1).
//

import SwiftUI

struct LudoDiePose {
    var rotationXDeg: CGFloat = 0
    var rotationYDeg: CGFloat = 0
    var liftPx: CGFloat = 0
    var scaleX: CGFloat = 1
    var scaleY: CGFloat = 1
    /// Non-nil only at rest: draw the flat single face instead of projecting the cube.
    var restingValue: Int?

    /// Rest pose: the result faces the viewer SQUARE ON, no tilt.
    ///
    /// The old rest pose carried a three-quarter tilt (x −8°, y +10°). Every projected face is
    /// drawn as a rounded rect built from the face's axis-aligned bounding box and then clipped
    /// to the face quad — which is exact only when the face is square to the camera. Under the
    /// tilt the bbox was much larger than the quad, so the rounded corners and the pip grid were
    /// laid out against the wrong rectangle and got sliced off: the flat grey slab with pips
    /// crowding its edges. Face-on, bbox and quad coincide and the die reads cleanly.
    static func resting(value: Int) -> LudoDiePose {
        LudoDiePose(rotationXDeg: 0, rotationYDeg: 0, restingValue: value)
    }
}

enum LudoDieView {

    /// Pip layouts as (column,row) in 0..2; grid coordinates at 0.23 / 0.50 / 0.77.
    static let pips: [Int: [(Int, Int)]] = [
        1: [(1, 1)],
        2: [(0, 0), (2, 2)],
        3: [(0, 0), (1, 1), (2, 2)],
        4: [(0, 0), (2, 0), (0, 2), (2, 2)],
        5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
        6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
    ]

    private struct V3 { let x: Double; let y: Double; let z: Double }

    private static func rotate(_ v: V3, rx: Double, ry: Double) -> V3 {
        let cy = cos(rx), sy = sin(rx)
        let y1 = v.y * cy - v.z * sy
        let z1 = v.y * sy + v.z * cy
        let cx = cos(ry), sx = sin(ry)
        let x2 = v.x * cx + z1 * sx
        let z2 = -v.x * sx + z1 * cx
        return V3(x: x2, y: y1, z: z2)
    }

    private static func rad(_ deg: CGFloat) -> Double { Double(deg) * .pi / 180 }

    static func draw(
        _ ctx: inout GraphicsContext,
        size side: CGFloat,
        value: Int,
        pose: LudoDiePose,
        pipColor: Color,
        colors: LudoColors,
    ) {
        var transformed = ctx
        transformed.translateBy(x: 0, y: pose.liftPx)
        transformed.scaleBy(x: pose.scaleX, y: pose.scaleY)
        // At rest one face is all that is visible, so draw it directly. Projecting a face-on
        // cube would give the same picture through eight rotations and a depth sort.
        if let resting = pose.restingValue {
            drawFlatFace(&transformed, side: side, value: resting,
                         pipColor: pipColor, colors: colors)
        } else {
            drawCube(&transformed, side: side, value: value,
                     rx: pose.rotationXDeg, ry: pose.rotationYDeg,
                     pipColor: pipColor, colors: colors)
        }
    }

    /// The resting die: one rounded square, one crisp pip grid, no projection.
    private static func drawFlatFace(
        _ ctx: inout GraphicsContext,
        side s: CGFloat,
        value: Int,
        pipColor: Color,
        colors: LudoColors,
    ) {
        let rect = CGRect(x: 0, y: 0, width: s, height: s)
        let body = RoundedRectangle(cornerRadius: 0.18 * s).path(in: rect)
        ctx.fill(body, with: .color(colors.dieBody))
        ctx.stroke(body, with: .color(colors.dieEdge),
                   style: StrokeStyle(lineWidth: colors.isDark ? 1.25 : 1.0))

        guard let layout = pips[value] else { return }
        let inset = 0.26 * s
        let step = (s - 2 * inset) / 2
        let radius = 0.093 * s

        for (col, row) in layout {
            let cx = inset + CGFloat(col) * step
            let cy = inset + CGFloat(row) * step
            func circle(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) -> Path {
                Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
            }
            // Inset-depth treatment: shadow slightly low, then the pip, then a top-left catch.
            ctx.fill(circle(cx, cy + 0.016 * s, radius), with: .color(.black.opacity(0.18)))
            ctx.fill(circle(cx, cy, radius), with: .color(pipColor))
            ctx.fill(circle(cx - radius * 0.30, cy - radius * 0.30, radius * 0.30),
                     with: .color(.white.opacity(0.14)))
        }
    }

    private static func drawCube(
        _ ctx: inout GraphicsContext,
        side s: CGFloat,
        value: Int,
        rx: CGFloat,
        ry: CGFloat,
        pipColor: Color,
        colors: LudoColors,
    ) {
        // Corner index → sign vector: bit0 x, bit1 y, bit2 z.
        func corner(_ i: Int) -> V3 {
            V3(x: (i & 1 == 0) ? -1 : 1,
               y: (i & 2 == 0) ? -1 : 1,
               z: (i & 4 == 0) ? -1 : 1)
        }

        // Face defs: CCW loops seen from OUTSIDE; physically consistent values.
        let faces: [(value: Int, normal: V3, corners: [Int])] = [
            (1, V3(x: 0, y: 0, z: 1), [4, 5, 7, 6]),
            (6, V3(x: 0, y: 0, z: -1), [1, 0, 2, 3]),
            (2, V3(x: 1, y: 0, z: 0), [5, 1, 3, 7]),
            (5, V3(x: -1, y: 0, z: 0), [0, 4, 6, 2]),
            (3, V3(x: 0, y: -1, z: 0), [4, 0, 1, 5]),
            (4, V3(x: 0, y: 1, z: 0), [2, 6, 7, 3]),
        ]

        // Project all eight corners with weak perspective into local coordinates.
        var projected: [CGPoint] = []
        projected.reserveCapacity(8)
        for i in 0..<8 {
            let c = corner(i)
            let r = rotate(V3(x: Double(c.x * s / 2), y: Double(c.y * s / 2), z: Double(c.z * s / 2)),
                           rx: rad(rx), ry: rad(ry))
            let k = 3.4 / (3.4 + r.z / Double(s))
            projected.append(CGPoint(x: CGFloat(s / 2 + r.x * k), y: CGFloat(s / 2 + r.y * k)))
        }

        // Back-face cull by winding against the view axis; sort visible far → near.
        let visible = faces.compactMap { f -> (value: Int, normal: V3, corners: [Int], depth: Double)? in
            let n = rotate(f.normal, rx: rad(rx), ry: rad(ry))
            guard n.z < 0.02 else { return nil }
            let depth = f.corners.reduce(0.0) { acc, ci in
                acc + rotate(corner(ci), rx: rad(rx), ry: rad(ry)).z
            }
            return (f.value, f.normal, f.corners, depth)
        }.sorted { $0.depth > $1.depth }

        let radius: CGFloat = 0.10 * s
        let edgeWidth: CGFloat = colors.isDark ? 1.25 : 1.0

        for face in visible {
            let pts = face.corners.map { projected[$0] }

            var quadPath = Path()
            quadPath.move(to: pts[0])
            for i in 1..<pts.count { quadPath.addLine(to: pts[i]) }
            quadPath.closeSubpath()

            let minX = pts.map(\.x).min() ?? 0
            let minY = pts.map(\.y).min() ?? 0
            let maxX = pts.map(\.x).max() ?? s
            let maxY = pts.map(\.y).max() ?? s
            let rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            let rounded = RoundedRectangle(cornerRadius: radius).path(in: rect)

            // Draw each face into a clipped layer so pips never bleed past the rounded square.
            ctx.drawLayer { layer in
                layer.clip(to: quadPath)

                // Body — ONE neutral token on every face, every value (§1).
                layer.fill(rounded, with: .color(colors.dieBody))

                // Directional shade ≤14% black on tilted faces: lighting, not a color change.
                let n = rotate(face.normal, rx: rad(rx), ry: rad(ry))
                let shade = max(0, min(1, -n.z)) * 0.14
                if shade > 0.01 {
                    layer.fill(rounded, with: .color(.black.opacity(shade)))
                }

                // Edge stroke (§14.2).
                layer.stroke(rounded, with: .color(colors.dieEdge),
                             style: StrokeStyle(lineWidth: edgeWidth))

                guard let layout = pips[face.value] else { return }
                let inset = 0.23 * s
                let step = (s - 2 * inset) / 2
                let diameter = 0.18 * s

                func bilinear(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
                    func lerp(_ a: CGPoint, _ b: CGPoint, _ t: CGFloat) -> CGPoint {
                        CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)
                    }
                    let top = lerp(pts[0], pts[1], u)
                    let bottom = lerp(pts[3], pts[2], u)
                    return lerp(top, bottom, v)
                }

                func circle(at cx: CGFloat, cy: CGFloat, radius r: CGFloat) -> Path {
                    Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                }

                for (col, row) in layout {
                    let u = (inset + CGFloat(col) * step) / s
                    let v = (inset + CGFloat(row) * step) / s
                    let c = bilinear(u, v)

                    // Inset-depth treatment: dark shadow slightly low + top-left highlight.
                    layer.fill(circle(at: c.x, cy: c.y + 0.018 * s, radius: diameter / 2),
                               with: .color(.black.opacity(0.18)))
                    layer.fill(circle(at: c.x, cy: c.y, radius: diameter / 2),
                               with: .color(pipColor))
                    layer.fill(circle(at: c.x - diameter * 0.16, cy: c.y - diameter * 0.16,
                                      radius: diameter * 0.28),
                               with: .color(.white.opacity(0.12)))
                }
            }
        }
    }
}

/// SwiftUI wrapper for the projected cube.
struct LudoDieCanvas: View {
    let value: Int
    let pose: LudoDiePose
    /// True when no decision is open — pips render with the NEUTRAL token (§1).
    let pipsNeutral: Bool
    /// Active seat whose hue colors ALL pips simultaneously.
    let activeSeat: Int?
    let side: CGFloat

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Canvas { ctx, size in
            var ctx = ctx
            let colors = LudoColors.resolve(scheme)
            let pipColor: Color = (pipsNeutral || activeSeat == nil)
                ? colors.dieNeutralPip
                : colors.hue(activeSeat!)
            LudoDieView.draw(&ctx, size: min(size.width, size.height), value: value,
                             pose: pose, pipColor: pipColor, colors: colors)
        }
        .frame(width: side, height: side)
    }
}
