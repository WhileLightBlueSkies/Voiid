//
//  SeaBattleShipArt.swift
//  Voiid
//
//  Hull silhouettes for the five ships (docs/games/VISUALS_AUDIO_AND_PARITY.md §6.3).
//
//  THE STRUCTURAL CHANGE: SHIPS ARE DRAWN PER SHIP, NOT PER CELL.
//
//  The grid renderer loops 0..<100 and draws each square independently, so a cell has no idea it
//  is the bow of a Carrier — a fleet was five runs of identical flat rectangles. A hull cannot be
//  assembled out of squares that do not know about each other, which is why this takes a ship's
//  whole bounding box and returns one path across it.
//
//  `SeaBattleRules.isContiguousLine` already guarantees a ship's cells are collinear and
//  contiguous, so the bounding box IS the ship and there is no geometry to invent here.
//
//  FIVE SILHOUETTES FOR FIVE LENGTHS, matching `fleetSpec = [5, 4, 3, 3, 2]`. The two 3-cell
//  ships are deliberately different shapes — a Cruiser and a Submarine are the same length and
//  must not be the same picture, or the fleet strip teaches nothing.
//
//  Mirrors Android `SeaBattleShipArt.kt`.
//

import SwiftUI

enum SeaBattleShipArt {

    /// A hull in UNIT SPACE: x runs 0...1 bow-to-stern along the ship's length, y runs 0...1
    /// across its beam. The caller scales it into the ship's bounding box and rotates for a
    /// vertical ship, so one path serves both orientations.
    ///
    /// `type` is the wire id, matching `SeaBattle.shipNames`.
    static func hull(type: Int) -> Path {
        var p = Path()
        switch type {
        case 0:  carrier(&p)
        case 1:  battleship(&p)
        case 2:  cruiser(&p)
        case 3:  submarine(&p)
        default: destroyer(&p)
        }
        return p
    }

    /// Deck furniture drawn ON TOP of the hull — towers, turrets, funnels. Separate from the
    /// hull so a damaged ship can scorch the hull and keep its silhouette readable.
    static func details(type: Int) -> [Path] {
        switch type {
        case 0:  return carrierDetails()
        case 1:  return battleshipDetails()
        case 2:  return cruiserDetails()
        case 3:  return submarineDetails()
        default: return destroyerDetails()
        }
    }

    // MARK: - Hulls

    /// CARRIER (5) — a flat deck with a blunt bow. The longest ship reads by its deck, not by
    /// a point.
    private static func carrier(_ p: inout Path) {
        p.move(to: CGPoint(x: 0.02, y: 0.34))
        p.addQuadCurve(to: CGPoint(x: 0.12, y: 0.18),
                       control: CGPoint(x: 0.02, y: 0.22))
        p.addLine(to: CGPoint(x: 0.94, y: 0.20))
        p.addQuadCurve(to: CGPoint(x: 0.98, y: 0.50),
                       control: CGPoint(x: 1.00, y: 0.34))
        p.addQuadCurve(to: CGPoint(x: 0.94, y: 0.80),
                       control: CGPoint(x: 1.00, y: 0.66))
        p.addLine(to: CGPoint(x: 0.12, y: 0.82))
        p.addQuadCurve(to: CGPoint(x: 0.02, y: 0.66),
                       control: CGPoint(x: 0.02, y: 0.78))
        p.closeSubpath()
    }

    /// BATTLESHIP (4) — a pointed bow and a squared stern. The classic warship profile.
    private static func battleship(_ p: inout Path) {
        p.move(to: CGPoint(x: 0.01, y: 0.50))
        p.addQuadCurve(to: CGPoint(x: 0.22, y: 0.19),
                       control: CGPoint(x: 0.06, y: 0.24))
        p.addLine(to: CGPoint(x: 0.93, y: 0.22))
        p.addLine(to: CGPoint(x: 0.97, y: 0.50))
        p.addLine(to: CGPoint(x: 0.93, y: 0.78))
        p.addLine(to: CGPoint(x: 0.22, y: 0.81))
        p.addQuadCurve(to: CGPoint(x: 0.01, y: 0.50),
                       control: CGPoint(x: 0.06, y: 0.76))
        p.closeSubpath()
    }

    /// CRUISER (3) — narrower than the battleship, with a raked bow.
    private static func cruiser(_ p: inout Path) {
        p.move(to: CGPoint(x: 0.02, y: 0.50))
        p.addQuadCurve(to: CGPoint(x: 0.26, y: 0.25),
                       control: CGPoint(x: 0.07, y: 0.29))
        p.addLine(to: CGPoint(x: 0.92, y: 0.28))
        p.addLine(to: CGPoint(x: 0.96, y: 0.50))
        p.addLine(to: CGPoint(x: 0.92, y: 0.72))
        p.addLine(to: CGPoint(x: 0.26, y: 0.75))
        p.addQuadCurve(to: CGPoint(x: 0.02, y: 0.50),
                       control: CGPoint(x: 0.07, y: 0.71))
        p.closeSubpath()
    }

    /// SUBMARINE (3) — ROUNDED AT BOTH ENDS, no deck. Same length as the cruiser and a
    /// completely different silhouette, which is the whole point.
    private static func submarine(_ p: inout Path) {
        p.move(to: CGPoint(x: 0.14, y: 0.30))
        p.addLine(to: CGPoint(x: 0.86, y: 0.30))
        p.addQuadCurve(to: CGPoint(x: 0.86, y: 0.70),
                       control: CGPoint(x: 1.02, y: 0.50))
        p.addLine(to: CGPoint(x: 0.14, y: 0.70))
        p.addQuadCurve(to: CGPoint(x: 0.14, y: 0.30),
                       control: CGPoint(x: -0.02, y: 0.50))
        p.closeSubpath()
    }

    /// DESTROYER (2) — small and sharp. At two cells there is no room for anything else.
    private static func destroyer(_ p: inout Path) {
        p.move(to: CGPoint(x: 0.03, y: 0.50))
        p.addQuadCurve(to: CGPoint(x: 0.30, y: 0.27),
                       control: CGPoint(x: 0.08, y: 0.30))
        p.addLine(to: CGPoint(x: 0.90, y: 0.30))
        p.addLine(to: CGPoint(x: 0.95, y: 0.50))
        p.addLine(to: CGPoint(x: 0.90, y: 0.70))
        p.addLine(to: CGPoint(x: 0.30, y: 0.73))
        p.addQuadCurve(to: CGPoint(x: 0.03, y: 0.50),
                       control: CGPoint(x: 0.08, y: 0.70))
        p.closeSubpath()
    }

    // MARK: - Deck detail

    private static func carrierDetails() -> [Path] {
        // Island tower at 60% of the length, plus two aircraft on the deck.
        var tower = Path()
        tower.addRoundedRect(in: CGRect(x: 0.55, y: 0.10, width: 0.11, height: 0.24),
                             cornerSize: CGSize(width: 0.02, height: 0.02))
        var planeA = Path()
        planeA.addRoundedRect(in: CGRect(x: 0.22, y: 0.44, width: 0.13, height: 0.05),
                              cornerSize: CGSize(width: 0.02, height: 0.02))
        var planeB = Path()
        planeB.addRoundedRect(in: CGRect(x: 0.40, y: 0.56, width: 0.13, height: 0.05),
                              cornerSize: CGSize(width: 0.02, height: 0.02))
        return [tower, planeA, planeB]
    }

    private static func battleshipDetails() -> [Path] {
        var bridge = Path()
        bridge.addRoundedRect(in: CGRect(x: 0.46, y: 0.34, width: 0.14, height: 0.32),
                              cornerSize: CGSize(width: 0.03, height: 0.03))
        var turretA = Path()
        turretA.addEllipse(in: CGRect(x: 0.28, y: 0.40, width: 0.10, height: 0.20))
        var turretB = Path()
        turretB.addEllipse(in: CGRect(x: 0.70, y: 0.40, width: 0.10, height: 0.20))
        return [turretA, bridge, turretB]
    }

    private static func cruiserDetails() -> [Path] {
        var turret = Path()
        turret.addEllipse(in: CGRect(x: 0.33, y: 0.40, width: 0.11, height: 0.20))
        var mast = Path()
        mast.addRoundedRect(in: CGRect(x: 0.58, y: 0.32, width: 0.06, height: 0.36),
                            cornerSize: CGSize(width: 0.02, height: 0.02))
        return [turret, mast]
    }

    private static func submarineDetails() -> [Path] {
        // A conning tower and nothing else — a submarine has no deck to furnish.
        var tower = Path()
        tower.addRoundedRect(in: CGRect(x: 0.44, y: 0.16, width: 0.14, height: 0.20),
                             cornerSize: CGSize(width: 0.04, height: 0.04))
        return [tower]
    }

    private static func destroyerDetails() -> [Path] {
        var funnel = Path()
        funnel.addRoundedRect(in: CGRect(x: 0.52, y: 0.34, width: 0.10, height: 0.32),
                              cornerSize: CGSize(width: 0.03, height: 0.03))
        return [funnel]
    }

    // MARK: - Placement

    /// The rect a ship occupies, and whether it runs horizontally.
    ///
    /// `cells` is guaranteed contiguous and collinear by `SeaBattleRules`, so min/max IS the
    /// hull's extent — there is nothing to infer.
    static func frame(cells: [Int], cellSize: CGFloat) -> (rect: CGRect, horizontal: Bool)? {
        guard !cells.isEmpty else { return nil }
        let xs = cells.map { SeaBattle.cx($0) }
        let ys = cells.map { SeaBattle.cy($0) }
        guard let minX = xs.min(), let maxX = xs.max(),
              let minY = ys.min(), let maxY = ys.max() else { return nil }
        // A one-cell ship does not exist in this fleet, so a single row means horizontal.
        let horizontal = (maxY - minY) == 0
        return (
            CGRect(x: CGFloat(minX) * cellSize, y: CGFloat(minY) * cellSize,
                   width: CGFloat(maxX - minX + 1) * cellSize,
                   height: CGFloat(maxY - minY + 1) * cellSize),
            horizontal
        )
    }

    // MARK: - Palette

    static let hullBody = Color(red: 0.30, green: 0.34, blue: 0.38)
    static let hullLit = Color(red: 0.44, green: 0.49, blue: 0.53)
    static let hullDeck = Color(red: 0.53, green: 0.56, blue: 0.58)
    static let hullInk = Color(red: 0.10, green: 0.12, blue: 0.14)
    /// A sunk hull desaturates and darkens rather than vanishing — the wreck is information.
    static let hullSunk = Color(red: 0.20, green: 0.18, blue: 0.18)
}
