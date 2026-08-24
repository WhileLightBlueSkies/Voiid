//
//  LudoBoardGeometry.swift
//  Voiid
//
//  Generated 15×15 board geometry (LUDO_GAME_SPEC.md §3).
//
//  ONE immutable array of 225 addressable nodes, row-major, built from the same tables the
//  backend fixture generator uses. The checked-in fixture (Resources/ludo_board_v2.json,
//  synced from packages/design-tokens/fixtures by tools/sync-ludo-fixture.sh) pins every
//  coordinate; [selfCheck] validates it in DEBUG on first layout so the app can never ship a
//  drifted table.
//
//  The board NEVER rotates per viewer: green top-left, yellow top-right, blue bottom-right,
//  red bottom-left, (0,0) at the physical top-left, x right, y down.
//

import CoreGraphics
import Foundation
extension CGRect {
    /// UIKit has no CGRect.center; the board math reads better with one.
    var midPoint: CGPoint { CGPoint(x: midX, y: midY) }
}


enum LudoBoardGeometry {

    static let side = 15
    static let cellCount = side * side

    enum Role: String {
        case yard
        case yardPocket
        case sharedTrack
        case homeLane
        case center
        case unused
    }

    enum Decoration: String {
        case none
        case star
        case entryChevron
    }

    struct CellNode {
        let id: String
        let x: Int
        let y: Int
        let role: Role
        let seat: Int?
        let trackIndex: Int?
        let homeStep: Int?
        let isSafe: Bool
        let decoration: Decoration
    }

    /// Shared-track absolute index → (x, y). Authoritative table from §3.2.
    static let trackCoords: [(Int, Int)] = [
        (6, 13), (6, 12), (6, 11), (6, 10), (6, 9), (5, 8),
        (4, 8), (3, 8), (2, 8), (1, 8), (0, 8), (0, 7),
        (0, 6), (1, 6), (2, 6), (3, 6), (4, 6), (5, 6),
        (6, 5), (6, 4), (6, 3), (6, 2), (6, 1), (6, 0),
        (7, 0), (8, 0), (8, 1), (8, 2), (8, 3), (8, 4),
        (8, 5), (9, 6), (10, 6), (11, 6), (12, 6), (13, 6),
        (14, 6), (14, 7), (14, 8), (13, 8), (12, 8), (11, 8),
        (10, 8), (9, 8), (8, 9), (8, 10), (8, 11), (8, 12),
        (8, 13), (8, 14), (7, 14), (6, 14),
    ]

    /// Home lane coordinates per seat, OUTSIDE → INSIDE (homeStep 0..4).
    static let homeLaneCoords: [[(Int, Int)]] = [
        [(7, 13), (7, 12), (7, 11), (7, 10), (7, 9)],   // red
        [(1, 7), (2, 7), (3, 7), (4, 7), (5, 7)],       // green
        [(7, 1), (7, 2), (7, 3), (7, 4), (7, 5)],       // yellow
        [(13, 7), (12, 7), (11, 7), (10, 7), (9, 7)],   // blue
    ]

    /// Yard pawn slots per seat, in pawn order.
    static let yardSlots: [[(Int, Int)]] = [
        [(2, 11), (4, 11), (2, 13), (4, 13)],
        [(2, 2), (4, 2), (2, 4), (4, 4)],
        [(10, 2), (12, 2), (10, 4), (12, 4)],
        [(10, 10), (12, 10), (10, 12), (12, 12)],
    ]

    /// Normalized clockwise border anchors (§12.1).
    static let borderAnchors: [CGFloat] = [0.00, 0.25, 0.50, 0.75]

    private static let trackAt: [Int: Int] = {
        var m: [Int: Int] = [:]
        for (i, c) in trackCoords.enumerated() { m[c.0 * 100 + c.1] = i }
        return m
    }()

    private static let laneAt: [Int: (Int, Int)] = {
        var m: [Int: (Int, Int)] = [:]
        for (seat, lane) in homeLaneCoords.enumerated() {
            for (step, c) in lane.enumerated() { m[c.0 * 100 + c.1] = (seat, step) }
        }
        return m
    }()

    private static func isCenter(_ x: Int, _ y: Int) -> Bool {
        (6...8).contains(x) && (6...8).contains(y)
    }

    private static func quadrant(ofX x: Int, y: Int) -> (seat: Int, ox: Int, oy: Int)? {
        if x < 6 && y < 6 { return (1, 0, 0) }
        if x > 8 && y < 6 { return (2, 9, 0) }
        if x < 6 && y > 8 { return (0, 0, 9) }
        if x > 8 && y > 8 { return (3, 9, 9) }
        return nil
    }

    /// The 225 nodes, row-major, ids "cell-x-y". Built once; immutable afterwards.
    static let cells: [CellNode] = {
        var out: [CellNode] = []
        out.reserveCapacity(cellCount)
        for y in 0..<side {
            for x in 0..<side {
                var role = Role.unused
                var seat: Int?
                var trackIndex: Int?
                var homeStep: Int?
                var isSafe = false
                var decoration = Decoration.none

                if isCenter(x, y) {
                    role = .center
                } else if let idx = trackAt[x * 100 + y] {
                    role = .sharedTrack
                    trackIndex = idx
                    isSafe = LudoRules.safeIndices.contains(idx)
                    if LudoRules.entryIndices.contains(idx) {
                        decoration = .entryChevron
                    } else if LudoRules.starIndices.contains(idx) {
                        decoration = .star
                    }
                } else if let (s, step) = laneAt[x * 100 + y] {
                    role = .homeLane
                    seat = s
                    homeStep = step
                } else if let q = quadrant(ofX: x, y: y) {
                    let lx = x - q.ox
                    let ly = y - q.oy
                    seat = q.seat
                    role = (lx >= 1 && lx <= 4 && ly >= 1 && ly <= 4) ? .yardPocket : .yard
                }

                out.append(CellNode(
                    id: "cell-\(x)-\(y)",
                    x: x, y: y,
                    role: role,
                    seat: seat,
                    trackIndex: trackIndex,
                    homeStep: homeStep,
                    isSafe: isSafe,
                    decoration: decoration))
            }
        }
        return out
    }()

    private static let cellByCoord: [Int: CellNode] = {
        Dictionary(uniqueKeysWithValues: cells.map { ($0.x * 100 + $0.y, $0) })
    }()

    static func cell(_ x: Int, _ y: Int) -> CellNode { cellByCoord[x * 100 + y]! }

    /// Rect mapping derived each layout pass (§3.3): one logical unit is side/15.
    struct Layout {
        let sideLength: CGFloat
        let unit: CGFloat
        private var rects: [CGRect] = []

        init(sideLength: CGFloat) {
            self.sideLength = sideLength
            self.unit = sideLength / CGFloat(LudoBoardGeometry.side)
            rects.reserveCapacity(cellCount)
            for node in LudoBoardGeometry.cells {
                rects.append(CGRect(
                    x: CGFloat(node.x) * unit,
                    y: CGFloat(node.y) * unit,
                    width: unit,
                    height: unit))
            }
        }

        func rect(of node: CellNode) -> CGRect { rects[node.y * LudoBoardGeometry.side + node.x] }

        func cell(at point: CGPoint) -> CellNode? {
            guard point.x >= 0, point.y >= 0,
                  point.x < sideLength, point.y < sideLength else { return nil }
            let cx = min(Int(point.x / unit), LudoBoardGeometry.side - 1)
            let cy = min(Int(point.y / unit), LudoBoardGeometry.side - 1)
            return LudoBoardGeometry.cell(cx, cy)
        }

        func yardSlotCenter(seat: Int, pawn: Int) -> CGPoint {
            let slot = LudoBoardGeometry.yardSlots[seat % 4][pawn]
            return rect(of: LudoBoardGeometry.cell(slot.0, slot.1)).midPoint
        }
    }

    // MARK: Fixture parity

    private static func fixtureCells() -> [[String: Any?]]? {
        #if DEBUG
        guard let url = Bundle.main.url(forResource: "ludo_board_v2", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["cells"] as? [[String: Any]] else { return nil }
        return arr.map { f in
            [
                "id": f["id"] as? String,
                "x": f["x"] as? Int,
                "y": f["y"] as? Int,
                "role": f["role"] as? String,
                "seat": f["seat"] as? Int,
                "trackIndex": f["trackIndex"] as? Int,
                "homeStep": f["homeStep"] as? Int,
                "isSafe": f["isSafe"] as? Bool,
                "decoration": f["decoration"] as? String,
            ]
        }
        #else
        return nil
        #endif
    }

    /// Parity check against the checked-in fixture (§19). DEBUG-only runtime assertion so no
    /// build can ship a geometry that disagrees with iOS/Android/backend tables.
    static func selfCheck() {
        #if DEBUG
        guard let fixture = fixtureCells() else { return }
        precondition(fixture.count == cellCount, "ludo fixture must hold 225 cells")
        for (i, node) in cells.enumerated() {
            let f = fixture[i]
            func eq<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a == b }
            precondition(eq(f["id"] as? String, node.id), "fixture drift at \(i)")
            precondition(eq(f["x"] as? Int, node.x) && eq(f["y"] as? Int, node.y), "fixture drift at \(i)")
            precondition(eq(f["role"] as? String, node.role.rawValue), "fixture drift at \(i)")
            precondition(eq(f["seat"] as? Int, node.seat), "fixture drift at \(i)")
            precondition(eq(f["trackIndex"] as? Int, node.trackIndex), "fixture drift at \(i)")
            precondition(eq(f["homeStep"] as? Int, node.homeStep), "fixture drift at \(i)")
            precondition(eq(f["isSafe"] as? Bool, node.isSafe), "fixture drift at \(i)")
            precondition(eq(f["decoration"] as? String, node.decoration.rawValue), "fixture drift at \(i)")
        }
        #endif
    }
}


extension Array {
    /// Safe index access used across the Ludo feature's frame math.
    subscript(ludoSafe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
