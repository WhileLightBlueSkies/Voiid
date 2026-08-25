//
//  LudoPawnShape.swift
//  Voiid
//
//  The code-drawn pawn silhouette (§4): circular dome head, tapered body, broad rimmed base,
//  small contact shadow. ONE normalized Path for all colors; surfaces stay BLANK.
//

import SwiftUI

enum LudoPawnShape {

    // 80% of the cell, so a token sits INSIDE its square instead of spilling over its
    // neighbours. The pin is drawn at 0.8 of the size it was first cut at.
    static let widthFactor: CGFloat = 0.62
    static let heightFactor: CGFloat = 0.82

    /// Map-pin silhouette: a disc with a tail drawn down to a point, over a ground ellipse.
    ///
    /// Built as a circle plus the two tangents to the tip, so the tail meets the disc smoothly
    /// at any proportion rather than at a visible seam. Everything is normalised to the box, so
    /// one path serves every size the board asks for.
    static func pinPath(width w: CGFloat, height h: CGFloat) -> Path {
        let cx = 0.5 * w
        let cy = 0.36 * h
        let r = 0.33 * w
        let tipY = 0.80 * h
        let d = tipY - cy                                   // centre → tip
        // Angle between centre→tip and centre→tangent-point.
        let beta = d > r ? acos(min(1, r / d)) : 0
        let betaDeg = beta * 180 / .pi

        var p = Path()
        // Increasing angle from 90+β sweeps left, over the top, back to the right tangent.
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(90 + betaDeg),
                 endAngle: .degrees(450 - betaDeg),
                 clockwise: false)
        p.addLine(to: CGPoint(x: cx, y: tipY))
        p.closeSubpath()
        return p
    }

    /// The hollow centre of the pin head.
    static func holeRect(width w: CGFloat, height h: CGFloat) -> CGRect {
        let r = 0.132 * w
        return CGRect(x: 0.5 * w - r, y: 0.36 * h - r, width: r * 2, height: r * 2)
    }

    /// The ground ellipse the pin stands on, so a token reads as placed rather than floating.
    static func baseRect(width w: CGFloat, height h: CGFloat) -> CGRect {
        let rx = 0.30 * w
        let ry = 0.115 * w
        return CGRect(x: 0.5 * w - rx, y: 0.845 * h - ry, width: rx * 2, height: ry * 2)
    }

    /// Draws one token into `ctx`, which the caller has already translated to the token's box.
    ///
    /// Layering runs widest-first — outline, then white border, then the colour — so the border
    /// comes from three strokes of ONE path instead of three separately inset paths that would
    /// drift apart at small sizes.
    static func draw(
        _ ctx: inout GraphicsContext,
        width w: CGFloat,
        height h: CGFloat,
        hue: Color,
        active: Bool,
        colors: LudoColors,
    ) {
        let pin = pinPath(width: w, height: h)
        let base = Path(ellipseIn: baseRect(width: w, height: h))
        let border = max(1.2, w * 0.085)
        let outline = max(0.7, w * 0.032)
        let fill = active ? hue : colors.mutedHue(hue)

        // Contact shadow first, under everything.
        ctx.fill(Path(ellipseIn: baseRect(width: w, height: h).insetBy(dx: -w * 0.02, dy: -w * 0.01)
                        .offsetBy(dx: 0, dy: h * 0.012)),
                 with: .color(.black.opacity(0.16)))

        // Active glow: concentric strokes fading outward. Cheaper than a real blur in Canvas and
        // it stays crisp at every board size.
        if active {
            for step in stride(from: 3, through: 1, by: -1) {
                let spread = border + CGFloat(step) * w * 0.055
                ctx.stroke(pin, with: .color(hue.opacity(0.052 * Double(4 - step) + 0.03)),
                           style: StrokeStyle(lineWidth: spread * 2, lineJoin: .round))
            }
        }

        for shape in [base, pin] {
            ctx.stroke(shape, with: .color(colors.pawnOutline),
                       style: StrokeStyle(lineWidth: border * 2 + outline * 2, lineJoin: .round))
            ctx.stroke(shape, with: .color(colors.pawnBorder),
                       style: StrokeStyle(lineWidth: border * 2, lineJoin: .round))
        }
        ctx.fill(base, with: .color(fill))
        ctx.fill(pin, with: .color(fill))

        // Hollow centre, in the border colour so it reads as a hole punched through.
        ctx.fill(Path(ellipseIn: holeRect(width: w, height: h)), with: .color(colors.pawnBorder))
    }

    /// Desaturated, muted version of a seat hue for a token that cannot move this turn.
    static func muted(_ base: Color) -> Color {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(base).getRed(&r, green: &g, blue: &b, alpha: &a)
        let luma = 0.299 * r + 0.587 * g + 0.114 * b
        // Partway to its own grey, then lifted slightly. Enough desaturation to read as "not
        // playable this turn", but the seat is still identifiable at a glance — a token pulled
        // all the way to grey loses which player it belongs to.
        func mix(_ c: CGFloat) -> Double { Double(c * 0.58 + luma * 0.42) * 0.80 + 0.15 }
        return Color(red: mix(r), green: mix(g), blue: mix(b), opacity: 1)
        #else
        return base.opacity(0.45)
        #endif
    }
}

/// Stacking and hit-target resolution (§4, §17): pairs at 82% offset ±0.14 cellSide
/// perpendicular to travel; safe-cell coexistence fans 2×2 at 68%; hit-testing resolves ONLY
/// among server-legal tokens.
enum LudoPawnLayer {

    struct PlacedPawn {
        let seat: Int
        let pawnIndex: Int
        var center: CGPoint
        var scale: CGFloat
    }

    static func layout(
        state: LudoGameStateV2,
        layout: LudoBoardGeometry.Layout,
        droppedSeats: Set<Int>,
        /// Pawns currently in transit. They are drawn where the motion says, at full size —
        /// a pawn mid-flight is not part of any stack, so it must not inherit a stack's scale.
        displayOverrides: [(seat: Int, pawn: Int, center: CGPoint)] = [],
    ) -> [PlacedPawn] {
        var out: [PlacedPawn] = []

        struct Entry { let seat: Int; let pawn: Int; let center: CGPoint }
        var groups: [Int: [Entry]] = [:]
        var order: [Int] = []

        func group(_ pos: Int, _ e: Entry) {
            if groups[pos] == nil { order.append(pos) }
            groups[pos, default: []].append(e)
        }

        for (seat, row) in state.tokens.enumerated() where !droppedSeats.contains(seat) {
            for (pawn, pos) in row.enumerated() {
                switch pos {
                case LudoRules.yard:
                    let c = layout.yardSlotCenter(seat: seat, pawn: pawn)
                    out.append(PlacedPawn(seat: seat, pawnIndex: pawn, center: c, scale: 1))
                case LudoRules.finished:
                    let rect = LudoCellView.finishSlotRect(seat: seat, pawnIndex: pawn,
                                                           centerRect: LudoCellView.centerRect(for: layout))
                    out.append(PlacedPawn(seat: seat, pawnIndex: pawn,
                                          center: CGPoint(x: rect.midX, y: rect.midY), scale: 0.52))
                default:
                    let coord: (Int, Int)
                    if pos >= LudoRules.homeLaneBase,
                       pos < LudoRules.homeLaneBase + LudoRules.homeLaneCount {
                        coord = LudoBoardGeometry.homeLaneCoords[seat][pos - LudoRules.homeLaneBase]
                    } else if pos >= 0 && pos < LudoRules.trackCount {
                        coord = LudoBoardGeometry.trackCoords[pos]
                    } else {
                        continue
                    }
                    let r = layout.rect(of: LudoBoardGeometry.cell(coord.0, coord.1))
                    group(pos, Entry(seat: seat, pawn: pawn,
                                     center: CGPoint(x: r.midX, y: r.midY)))
                }
            }
        }

        for pos in order {
            guard let entries = groups[pos] else { continue }
            let unit = layout.unit
            if entries.count == 2 && entries[0].seat == entries[1].seat
                && !LudoRules.safeIndices.contains(pos) {
                // Same-colour block: 82%, offset ±0.14 cellSide perpendicular to travel.
                let dir = travelDirection(seat: entries[0].seat, pos: pos)
                let off = 0.14 * unit
                out.append(PlacedPawn(seat: entries[0].seat, pawnIndex: entries[0].pawn,
                                      center: entries[0].center.applying(.init(translationX: -dir.y * off, y: dir.x * off)),
                                      scale: 0.82))
                out.append(PlacedPawn(seat: entries[1].seat, pawnIndex: entries[1].pawn,
                                      center: entries[1].center.applying(.init(translationX: dir.y * off, y: -dir.x * off)),
                                      scale: 0.82))
            } else if entries.count > 1 {
                let grid = entries.count <= 4 ? 2 : entries.count <= 9 ? 3 : 4
                let scale: CGFloat = entries.count <= 4 ? 0.58 : entries.count <= 9 ? 0.40 : 0.30
                let spacing = unit * (grid == 2 ? 0.28 : grid == 3 ? 0.22 : 0.17)
                for (i, e) in entries.enumerated() {
                    let col = CGFloat(i % grid) - CGFloat(grid - 1) / 2
                    let row = CGFloat(i / grid) - CGFloat(grid - 1) / 2
                    out.append(PlacedPawn(seat: e.seat, pawnIndex: e.pawn,
                                          center: CGPoint(x: e.center.x + col * spacing,
                                                          y: e.center.y + row * spacing),
                                          scale: scale))
                }
            } else if let e = entries.first {
                out.append(PlacedPawn(seat: e.seat, pawnIndex: e.pawn, center: e.center, scale: 1))
            }
        }

        // Pawns in transit win their slot visually, and at full scale: the destination cell may
        // already have fanned them into a stack, and a pawn still travelling toward it should
        // not be drawn shrunk into a stack it has not joined yet.
        if !displayOverrides.isEmpty {
            return out.map { p in
                guard let o = displayOverrides.first(where: {
                    $0.seat == p.seat && $0.pawn == p.pawnIndex
                }) else { return p }
                return PlacedPawn(seat: p.seat, pawnIndex: p.pawnIndex, center: o.center, scale: 1)
            }.sorted { ($0.seat * 10 + $0.pawnIndex) < ($1.seat * 10 + $1.pawnIndex) }
        }
        return out.sorted { ($0.seat * 10 + $0.pawnIndex) < ($1.seat * 10 + $1.pawnIndex) }
    }

    /// Travel direction at an absolute track position for a seat's clockwise route.
    static func travelDirection(seat: Int, pos: Int) -> CGPoint {
        let cur = LudoBoardGeometry.trackCoords[pos]
        let nextProgress = (LudoRules.progressOf(pos, seat: seat) + 1) % LudoRules.trackCount
        let absNext = (LudoRules.startIndex(seat) + nextProgress) % LudoRules.trackCount
        let nxt = LudoBoardGeometry.trackCoords[absNext]
        let dx = CGFloat(nxt.0 - cur.0)
        let dy = CGFloat(nxt.1 - cur.1)
        let len = max(sqrt(dx * dx + dy * dy), 0.001)
        return CGPoint(x: dx / len, y: dy / len)
    }

    /// Hit-test resolving to the LOWEST legal token whose circle contains the point (§17).
    static func hitTest(
        placed: [PlacedPawn],
        unit: CGFloat,
        point: CGPoint,
        legalTokensBySeat: [Int: Set<Int>],
    ) -> (seat: Int, pawn: Int)? {
        // NEAREST legal pawn wins, not the first one in seat order. Two legal pawns can sit a
        // fraction of a cell apart — a stack fanned out, or adjacent track cells — and picking
        // by index moved a pawn the player had not aimed at.
        let r = max(unit * 0.75, 22)
        var best: (seat: Int, pawn: Int)?
        var bestDistance = r * r
        for p in placed {
            guard let legal = legalTokensBySeat[p.seat], legal.contains(p.pawnIndex) else { continue }
            let dx = point.x - p.center.x
            let dy = point.y - p.center.y
            let d = dx * dx + dy * dy
            if d <= bestDistance {
                bestDistance = d
                best = (p.seat, p.pawnIndex)
            }
        }
        return best
    }
}
