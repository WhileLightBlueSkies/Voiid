//
//  LudoPawnShape.swift
//  Voiid
//
//  The code-drawn pawn silhouette (§4): circular dome head, tapered body, broad rimmed base,
//  small contact shadow. ONE normalized Path for all colors; surfaces stay BLANK.
//

import SwiftUI

enum LudoPawnShape {

    static let widthFactor: CGFloat = 0.64
    static let heightFactor: CGFloat = 1.14

    /// Normalized path over a box of width w and height h per §4's construction.
    static func path(width: CGFloat, height: CGFloat) -> Path {
        var p = Path()
        let w = width, h = height

        p.move(to: CGPoint(x: 0.32 * w, y: 0.31 * h))
        p.addLine(to: CGPoint(x: 0.68 * w, y: 0.31 * h))
        p.addCurve(to: CGPoint(x: 0.85 * w, y: 0.71 * h),
                   control1: CGPoint(x: 0.73 * w, y: 0.52 * h),
                   control2: CGPoint(x: 0.78 * w, y: 0.64 * h))
        p.addCurve(to: CGPoint(x: w, y: 0.82 * h),
                   control1: CGPoint(x: 0.96 * w, y: 0.71 * h),
                   control2: CGPoint(x: w, y: 0.76 * h))
        p.addLine(to: CGPoint(x: w, y: 0.89 * h))
        p.addCurve(to: CGPoint(x: 0.50 * w, y: h),
                   control1: CGPoint(x: 0.82 * w, y: 0.99 * h),
                   control2: CGPoint(x: 0.68 * w, y: h))
        p.addCurve(to: CGPoint(x: 0, y: 0.89 * h),
                   control1: CGPoint(x: 0.32 * w, y: h),
                   control2: CGPoint(x: 0.18 * w, y: 0.99 * h))
        p.addLine(to: CGPoint(x: 0, y: 0.82 * h))
        p.addCurve(to: CGPoint(x: 0.15 * w, y: 0.71 * h),
                   control1: CGPoint(x: 0, y: 0.76 * h),
                   control2: CGPoint(x: 0.04 * w, y: 0.71 * h))
        p.addCurve(to: CGPoint(x: 0.32 * w, y: 0.31 * h),
                   control1: CGPoint(x: 0.22 * w, y: 0.64 * h),
                   control2: CGPoint(x: 0.27 * w, y: 0.52 * h))
        p.closeSubpath()
        p.addEllipse(in: CGRect(x: 0.5 * w - 0.175 * h, y: 0,
                                width: 0.35 * h, height: 0.35 * h))
        return p
    }

    /// Visible lower half of the base top ellipse.
    static func rimPath(width: CGFloat, height: CGFloat) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 0.04 * width, y: 0.735 * height))
        p.addCurve(to: CGPoint(x: 0.96 * width, y: 0.735 * height),
                   control1: CGPoint(x: 0.20 * width, y: 0.82 * height),
                   control2: CGPoint(x: 0.80 * width, y: 0.82 * height))
        return p
    }

    /// Lower head contact line.
    static func highlightArc(width: CGFloat, height: CGFloat) -> Path {
        let cx = 0.50 * width
        let cy = 0.175 * height
        let r = 0.175 * height
        var p = Path()
        p.addArc(center: CGPoint(x: cx, y: cy), radius: r,
                 startAngle: .degrees(20), endAngle: .degrees(160), clockwise: false)
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
