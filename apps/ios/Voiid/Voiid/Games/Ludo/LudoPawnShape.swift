//
//  LudoPawnShape.swift
//  Voiid
//
//  The code-drawn pawn silhouette (§4): circular dome head, tapered body, broad rimmed base,
//  small contact shadow. ONE normalized Path for all colors; surfaces stay BLANK.
//

import SwiftUI

enum LudoPawnShape {

    /// Visual box is 0.82 × 1.18 cellSide, centered on the cell, allowed to rise above it (§4).
    static let widthFactor: CGFloat = 0.82
    static let heightFactor: CGFloat = 1.18

    /// Normalized path over a box of width w and height h per §4's construction.
    static func path(width: CGFloat, height: CGFloat) -> Path {
        var p = Path()
        let w = width, h = height

        // Base body — rounded trapezoid y=0.78H..0.98H, x=0.05W..0.95W, corner 0.09W.
        let baseTopY = 0.78 * h
        let baseBotY = 0.98 * h
        let corner = 0.09 * w

        p.move(to: CGPoint(x: 0.05 * w + corner, y: baseBotY))
        p.addLine(to: CGPoint(x: 0.95 * w - corner, y: baseBotY))
        p.addCurve(
            to: CGPoint(x: 0.87 * w, y: baseTopY + 0.02 * h),
            control1: CGPoint(x: 0.95 * w, y: baseBotY),
            control2: CGPoint(x: 0.95 * w, y: baseBotY - corner))
        p.addLine(to: CGPoint(x: 0.78 * w, y: baseTopY))
        // Right flare up to the neck.
        p.addCurve(
            to: CGPoint(x: 0.575 * w, y: 0.345 * h),
            control1: CGPoint(x: 0.72 * w, y: 0.70 * h),
            control2: CGPoint(x: 0.56 * w, y: 0.44 * h))
        p.addLine(to: CGPoint(x: 0.425 * w, y: 0.345 * h))
        // Mirror down the left side.
        p.addCurve(
            to: CGPoint(x: 0.22 * w, y: baseTopY),
            control1: CGPoint(x: 0.44 * w, y: 0.44 * h),
            control2: CGPoint(x: 0.28 * w, y: 0.70 * h))
        p.addLine(to: CGPoint(x: 0.13 * w, y: baseTopY + 0.02 * h))
        p.addCurve(
            to: CGPoint(x: 0.05 * w + corner, y: baseBotY),
            control1: CGPoint(x: 0.05 * w, y: baseBotY - corner),
            control2: CGPoint(x: 0.05 * w, y: baseBotY))
        p.closeSubpath()
        return p
    }

    /// Base top rim ellipse spanning x=0.11W..0.89W centered y=0.79H, height 0.16H.
    static func rimPath(width: CGFloat, height: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: 0.11 * width,
            y: 0.79 * height - 0.08 * height,
            width: 0.78 * width,
            height: 0.16 * height))
    }

    /// Restrained head highlight: white arc at 14%/10% opacity, stroke 0.035W, upper-left 70°.
    static func highlightArc(width: CGFloat, height: CGFloat) -> Path {
        let cx = 0.50 * width
        let cy = 0.20 * height
        let r = 0.185 * height
        var p = Path()
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(-200), endAngle: .degrees(-130), clockwise: false)
        return p
    }

    /// Darker same-hue rim line color: RGB × 0.78 light / 0.72 dark (§4).
    static func rimColor(_ base: Color, darkTheme: Bool) -> Color {
        let f: Double = darkTheme ? 0.72 : 0.78
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(base).getRed(&r, green: &g, blue: &b, alpha: &a)
        return Color(red: Double(r) * f, green: Double(g) * f, blue: Double(b) * f, opacity: 1)
        #else
        return base.opacity(f)
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
        displayOverride: (seat: Int, pawn: Int, center: CGPoint)? = nil,
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
                // Safe-cell coexistence (any colours): 2×2 fan at 68%.
                for (i, e) in entries.enumerated() {
                    let dx: CGFloat = i % 2 == 0 ? -1 : 1
                    let dy: CGFloat = i < 2 ? -1 : 1
                    let off = 0.16 * unit
                    out.append(PlacedPawn(seat: e.seat, pawnIndex: e.pawn,
                                          center: CGPoint(x: e.center.x + dx * off,
                                                          y: e.center.y + dy * off),
                                          scale: 0.68))
                }
            } else if let e = entries.first {
                out.append(PlacedPawn(seat: e.seat, pawnIndex: e.pawn, center: e.center, scale: 1))
            }
        }

        // One display pawn may be mid-hop; it wins its slot visually.
        if let o = displayOverride {
            return out.map {
                ($0.seat == o.seat && $0.pawnIndex == o.pawn)
                    ? PlacedPawn(seat: $0.seat, pawnIndex: $0.pawnIndex, center: o.center, scale: $0.scale)
                    : $0
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
        let r = max(unit * 0.75, 22)
        for p in placed.sorted(by: { ($0.seat * 10 + $0.pawnIndex) < ($1.seat * 10 + $1.pawnIndex) }) {
            guard let legal = legalTokensBySeat[p.seat], legal.contains(p.pawnIndex) else { continue }
            let dx = point.x - p.center.x
            let dy = point.y - p.center.y
            if dx * dx + dy * dy <= r * r { return (p.seat, p.pawnIndex) }
        }
        return nil
    }
}
