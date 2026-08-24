//
//  LudoCellView.swift
//  Voiid
//
//  Keyed cell drawing (§3.3). Every node draws from ITS OWN rect — highlights, pulses and
//  semantics stay per-cell; a flattened bitmap or one unaddressable path is forbidden.
//

import SwiftUI

enum LudoCellView {

    static func fill(_ node: LudoBoardGeometry.CellNode, _ c: LudoColors) -> Color {
        switch node.role {
        case .sharedTrack:
            return node.isSafe ? c.safeCellFill : c.trackCellFill
        case .homeLane:
            return c.homeLane(node.seat ?? 0)
        case .center, .unused:
            return c.unusedCellFill
        default:
            return c.trackCellFill
        }
    }

    /// Yard fields tint with their owner hue; a DROPPED seat desaturates to inactiveYard (§13).
    static func yardFill(_ node: LudoBoardGeometry.CellNode, dropped: Set<Int>, _ c: LudoColors) -> Color {
        guard let owner = node.seat else { return c.unusedCellFill }
        return dropped.contains(owner) ? c.inactiveYard : c.yard(owner)
    }

    @inline(__always)
    static func draw(
        _ ctx: inout GraphicsContext,
        node: LudoBoardGeometry.CellNode,
        rect: CGRect,
        colors: LudoColors,
        pressed: Bool,
        highlight: Color?,
        highContrast: Bool,
        darkTheme: Bool,
    ) {
        let radius = min(LudoDimens.cellCornerRadiusFactor * rect.width, 2)
        let cellPath = RoundedRectangle(cornerRadius: radius).path(in: rect)
        ctx.fill(cellPath, with: .color(pressed ? colors.trackCellPressed : fill(node, colors)))
        // Cell rule line; high contrast raises it (§17).
        ctx.stroke(cellPath, with: .color(colors.trackCellBorder),
                   lineWidth: highContrast ? 1.5 : (darkTheme ? 1 : 0.75))
        if let highlight {
            ctx.stroke(cellPath, with: .color(highlight.opacity(0.45)), lineWidth: 2.5)
        }
    }

    // MARK: Safe decorations — Paths, never glyphs (§1).

    /// Five-point star for indices {8,21,34,47}; outer radius = 0.28 × cellSide.
    static func safeStarPath(in rect: CGRect) -> Path {
        let outer = 0.28 * rect.width
        let inner = outer * 0.42
        let cx = rect.midX, cy = rect.midY
        var p = Path()
        for i in 0..<10 {
            let angle = Double.pi / 2 + Double(i) * Double.pi / 5   // point up
            let r = i % 2 == 0 ? outer : inner
            let px = cx + CGFloat(r * cos(angle))
            let py = cy - CGFloat(r * sin(angle))
            if i == 0 { p.move(to: CGPoint(x: px, y: py)) } else { p.addLine(to: CGPoint(x: px, y: py)) }
        }
        p.closeSubpath()
        return p
    }

    /// Filled chevron in the owner hue pointing along the seat's travel direction into the board.
    static func entryChevronPath(in rect: CGRect, seat: Int) -> Path {
        let dir: CGPoint = {
            switch seat % 4 {
            case 0: return CGPoint(x: 0, y: -1)   // red start (6,13) travels up
            case 1: return CGPoint(x: 1, y: 0)    // green start (1,6) travels right
            case 2: return CGPoint(x: 0, y: 1)    // yellow start (8,1) travels down
            default: return CGPoint(x: -1, y: 0)  // blue start (13,8) travels left
            }
        }()
        let size = rect.width * 0.42
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let tip = CGPoint(x: c.x + dir.x * size * 0.6, y: c.y + dir.y * size * 0.6)
        let perp = CGPoint(x: -dir.y, y: dir.x)
        func pt(_ dx: CGFloat, _ dy: CGFloat) -> CGPoint { CGPoint(x: dx, y: dy) }
        let backL = pt(tip.x - dir.x * size - perp.x * size * 0.8,
                       tip.y - dir.y * size - perp.y * size * 0.8)
        let backMid = pt(tip.x - dir.x * size * 0.45, tip.y - dir.y * size * 0.45)
        let backR = pt(tip.x - dir.x * size + perp.x * size * 0.8,
                       tip.y - dir.y * size + perp.y * size * 0.8)
        var p = Path()
        p.move(to: backL)
        p.addLine(to: tip)
        p.addLine(to: backR)
        p.addLine(to: backMid)
        p.closeSubpath()
        return p
    }

    /// Center triangles: green from left, yellow from top, blue from right, red from bottom.
    static func centerTrianglePath(seat: Int, centerRect: CGRect) -> Path {
        var p = Path()
        let cx = centerRect.midX, cy = centerRect.midY
        switch seat % 4 {
        case 1:
            p.move(to: CGPoint(x: centerRect.minX, y: centerRect.minY))
            p.addLine(to: CGPoint(x: centerRect.minX, y: centerRect.maxY))
            p.addLine(to: CGPoint(x: cx, y: cy))
        case 2:
            p.move(to: CGPoint(x: centerRect.minX, y: centerRect.minY))
            p.addLine(to: CGPoint(x: centerRect.maxX, y: centerRect.minY))
            p.addLine(to: CGPoint(x: cx, y: cy))
        case 3:
            p.move(to: CGPoint(x: centerRect.maxX, y: centerRect.minY))
            p.addLine(to: CGPoint(x: centerRect.maxX, y: centerRect.maxY))
            p.addLine(to: CGPoint(x: cx, y: cy))
        default:
            p.move(to: CGPoint(x: centerRect.minX, y: centerRect.maxY))
            p.addLine(to: CGPoint(x: centerRect.maxX, y: centerRect.maxY))
            p.addLine(to: CGPoint(x: cx, y: cy))
        }
        p.closeSubpath()
        return p
    }

    /// The 2×2 finish slots inside each triangle; a finished pawn shrinks into one at 52% (§3.2).
    static func finishSlotRect(seat: Int, pawnIndex: Int, centerRect: CGRect) -> CGRect {
        let w = centerRect.width / 4
        let h = centerRect.height / 4
        let col = pawnIndex % 2
        let row = pawnIndex / 2
        var left = centerRect.minX + CGFloat(col) * w
        var top = centerRect.minY + CGFloat(row) * h
        switch seat % 4 {
        case 3: left = centerRect.maxX - CGFloat(col + 1) * w
        case 0: top = centerRect.maxY - CGFloat(row + 1) * h
        default: break
        }
        return CGRect(x: left, y: top, width: w, height: h)
    }

    static func centerRect(for layout: LudoBoardGeometry.Layout) -> CGRect {
        let a = layout.rect(of: LudoBoardGeometry.cell(6, 6))
        let b = layout.rect(of: LudoBoardGeometry.cell(8, 8))
        return CGRect(x: a.minX, y: a.minY, width: b.maxX - a.minX, height: b.maxY - a.minY)
    }
}
