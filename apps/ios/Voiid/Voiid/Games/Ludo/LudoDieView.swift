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
    /// Shrinks the cube while it is airborne so its corners stay inside the tray — a rotated
    /// cube spans up to √3 of its own side, which would otherwise be clipped square.
    var depthScale: CGFloat = 1

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

    /// Face values as front, back, right, left, top, bottom — the result on the front, its
    /// complement behind it, and the two remaining opposite pairs on the sides and poles.
    static func faceValues(result: Int) -> [Int] {
        let r = min(6, max(1, result))
        let remaining = [[1, 6], [2, 5], [3, 4]].filter { !$0.contains(r) }
        return [r, 7 - r,
                remaining[0][0], remaining[0][1],
                remaining[1][0], remaining[1][1]]
    }

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

    /// Key light from up and to the left, in front of the die. Normalised so a face square to
    /// the camera — the settled result — returns exactly 1 and takes no shading at all.
    private static let lightDir = (x: -0.30, y: -0.45, z: -1.0)
    private static let lightLen = (0.30 * 0.30 + 0.45 * 0.45 + 1.0) .squareRoot()

    private static func lambert(_ n: V3) -> Double {
        let dot = (n.x * lightDir.x + n.y * lightDir.y + n.z * lightDir.z) / lightLen
        // A face-on normal is (0,0,-1); dividing by that response puts it at exactly 1.
        let frontResponse = 1.0 / lightLen
        return max(0, min(1, dot / frontResponse))
    }

    /// Fraction of the tray the settled die occupies.
    static let restFillFactor: CGFloat = 0.92

    static func draw(
        _ ctx: inout GraphicsContext,
        size side: CGFloat,
        value: Int,
        pose: LudoDiePose,
        pipColor: Color,
        colors: LudoColors,
    ) {
        let drawSide = side * restFillFactor * pose.depthScale

        // Cast shadow on the tray floor. It stays put while the die rises, shrinking and fading
        // with height — the cue that separates a die thrown into the air from a picture being
        // rotated in place. Drawn before the transform so the lift does not move it.
        if pose.liftPx < -0.5 {
            let height = min(1, -Double(pose.liftPx) / 21)
            let r = side * 0.30 * (1 - 0.34 * height)
            let cx = side / 2 + side * 0.05 * height          // light is up-left, so it slides right
            let cy = side * 0.80
            ctx.fill(Path(ellipseIn: CGRect(x: cx - r, y: cy - r * 0.34,
                                            width: r * 2, height: r * 0.68)),
                     with: .color(.black.opacity(0.20 * (1 - 0.65 * height))))
        }

        var transformed = ctx
        // Centre the die in its tray, then squash about that centre. Translating by the lift
        // last keeps the airborne offset independent of the squash.
        transformed.translateBy(x: (side - drawSide) / 2,
                                y: (side - drawSide) / 2 + pose.liftPx)
        transformed.translateBy(x: drawSide / 2, y: drawSide / 2)
        transformed.scaleBy(x: pose.scaleX, y: pose.scaleY)
        transformed.translateBy(x: -drawSide / 2, y: -drawSide / 2)

        // At rest one face is all that is visible, so draw it directly. Projecting a face-on
        // cube would give the same picture through eight rotations and a depth sort.
        if let resting = pose.restingValue {
            drawFlatFace(&transformed, side: drawSide, value: resting,
                         pipColor: pipColor, colors: colors)
        } else {
            drawCube(&transformed, side: drawSide, value: value,
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

        // Face defs: CCW loops seen from OUTSIDE. The values are ROTATED so the rolled result
        // always sits on the front face, with opposites still summing to 7.
        //
        // The alternative — a fixed labelling plus a per-value landing orientation — is what
        // made the die appear to change its number after settling: the tumble ended at whatever
        // angles the pose carried, showing some other face, and the handoff to the flat resting
        // face then snapped to the real result. Turning the labels instead of the cube lets
        // every roll settle at rotation (0,0), square-on and upright, so the tumble and the
        // resting face show the same number in the same place.
        let fv = faceValues(result: value)
        let faces: [(value: Int, normal: V3, corners: [Int])] = [
            (fv[0], V3(x: 0, y: 0, z: 1), [4, 5, 7, 6]),
            (fv[1], V3(x: 0, y: 0, z: -1), [1, 0, 2, 3]),
            (fv[2], V3(x: 1, y: 0, z: 0), [5, 1, 3, 7]),
            (fv[3], V3(x: -1, y: 0, z: 0), [0, 4, 6, 2]),
            (fv[4], V3(x: 0, y: -1, z: 0), [4, 0, 1, 5]),
            (fv[5], V3(x: 0, y: 1, z: 0), [2, 6, 7, 3]),
        ]

        // Project all eight corners with weak perspective into local coordinates.
        var projected: [CGPoint] = []
        projected.reserveCapacity(8)
        for i in 0..<8 {
            let c = corner(i)
            let r = rotate(V3(x: Double(c.x * s / 2), y: Double(c.y * s / 2), z: Double(c.z * s / 2)),
                           rx: rad(rx), ry: rad(ry))
            // Stronger foreshortening than a near-orthographic projection: without it the cube
            // read as a flat square swapping pictures rather than a solid turning over.
            let k = 1.75 / (1.75 + r.z / Double(s))
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

        let edgeWidth: CGFloat = colors.isDark ? 1.25 : 1.0

        for face in visible {
            let pts = face.corners.map { projected[$0] }

            var quadPath = Path()
            quadPath.move(to: pts[0])
            for i in 1..<pts.count { quadPath.addLine(to: pts[i]) }
            quadPath.closeSubpath()

            // The face is the PROJECTED QUAD itself, not a rounded rect sized to its bounding
            // box. The bbox of a turned quad is far larger than the quad, so filling it and
            // clipping to the quad painted a full grey slab with the pip grid laid out against
            // the wrong rectangle — which is why the tumbling die read as a flat square swapping
            // pictures instead of a cube turning over.
            ctx.drawLayer { layer in
                layer.clip(to: quadPath)

                // Body — ONE neutral token on every face, every value (§1).
                layer.fill(quadPath, with: .color(colors.dieBody))

                // Lambert shading against a fixed light, NOT a flat darkening of tilted faces.
                //
                // The old term darkened by how far a face had turned away from the camera, so
                // the face showing the result dimmed as it tumbled and the body read as
                // changing colour — an off-white die. Lighting the cube instead means the face
                // squarest to the light stays exactly the body colour, and the faces around it
                // fall off, which is what makes it look like an object rather than a picture.
                let n = rotate(face.normal, rx: rad(rx), ry: rad(ry))
                let lit = lambert(n)
                let shade = (1 - lit) * 0.42
                if shade > 0.01 {
                    layer.fill(quadPath, with: .color(.black.opacity(shade)))
                }

                // Edge stroke (§14.2).
                layer.stroke(quadPath, with: .color(colors.dieEdge),
                             style: StrokeStyle(lineWidth: edgeWidth, lineJoin: .round))

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
