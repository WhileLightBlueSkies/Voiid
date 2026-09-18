//
//  LudoEngine.swift
//  Voiid
//
//  Pure rules + board topology. Deterministic and unit-testable.
//

import Foundation
import CoreGraphics

// MARK: - Positions

enum LudoPos {
    static let yard = -1
    static let goal = 56
    static let columnStart = 51
    static let ringCount = 52
}

struct GridPoint: Equatable, Hashable {
    let x: Int
    let y: Int
    init(_ x: Int, _ y: Int) { self.x = x; self.y = y }
}

// MARK: - Seats

struct Seat {
    let name: String
    let start: Int              // index into `LudoEngine.ring`
    let yardOrigin: GridPoint   // top-left cell of the 6x6 yard
    let column: [GridPoint]     // five home-column cells, outermost first
}

// MARK: - Move

struct Move: Equatable {
    let token: Int
    let from: Int
    let to: Int

    var leavesYard: Bool { from == LudoPos.yard }
    var reachesHome: Bool { to == LudoPos.goal }
}

// MARK: - State

struct LudoState: Equatable {
    /// positions[seat][token]
    var positions: [[Int]]
    var turn: Int
    var consecutiveSixes: Int

    init() {
        positions = Array(repeating: Array(repeating: LudoPos.yard, count: 4), count: 4)
        turn = 0
        consecutiveSixes = 0
    }

    func homeCount(_ seat: Int) -> Int {
        positions[seat].filter { $0 == LudoPos.goal }.count
    }

    func hasWon(_ seat: Int) -> Bool { homeCount(seat) == 4 }
}

// MARK: - Engine

enum LudoEngine {

    /// The 52-square ring, clockwise, in 15x15 grid coordinates.
    static let ring: [GridPoint] = [
        GridPoint(1,6), GridPoint(2,6), GridPoint(3,6), GridPoint(4,6), GridPoint(5,6),
        GridPoint(6,5), GridPoint(6,4), GridPoint(6,3), GridPoint(6,2), GridPoint(6,1),
        GridPoint(6,0),
        GridPoint(7,0),
        GridPoint(8,0), GridPoint(8,1), GridPoint(8,2), GridPoint(8,3), GridPoint(8,4),
        GridPoint(8,5),
        GridPoint(9,6), GridPoint(10,6), GridPoint(11,6), GridPoint(12,6), GridPoint(13,6),
        GridPoint(14,6),
        GridPoint(14,7),
        GridPoint(14,8),
        GridPoint(13,8), GridPoint(12,8), GridPoint(11,8), GridPoint(10,8), GridPoint(9,8),
        GridPoint(8,9), GridPoint(8,10), GridPoint(8,11), GridPoint(8,12), GridPoint(8,13),
        GridPoint(8,14),
        GridPoint(7,14),
        GridPoint(6,14), GridPoint(6,13), GridPoint(6,12), GridPoint(6,11), GridPoint(6,10),
        GridPoint(6,9),
        GridPoint(5,8), GridPoint(4,8), GridPoint(3,8), GridPoint(2,8), GridPoint(1,8),
        GridPoint(0,8),
        GridPoint(0,7),
        GridPoint(0,6)
    ]

    /// Squares where a token cannot be captured: the four start squares
    /// and the four stars sitting eight ahead of each.
    static let safeSquares: Set<Int> = [0, 8, 13, 21, 26, 34, 39, 47]

    static let seats: [Seat] = [
        Seat(name: "Red",   start: 0,  yardOrigin: GridPoint(0,0),
             column: [GridPoint(1,7), GridPoint(2,7), GridPoint(3,7),
                      GridPoint(4,7), GridPoint(5,7)]),
        Seat(name: "Green", start: 13, yardOrigin: GridPoint(9,0),
             column: [GridPoint(7,1), GridPoint(7,2), GridPoint(7,3),
                      GridPoint(7,4), GridPoint(7,5)]),
        Seat(name: "Amber", start: 26, yardOrigin: GridPoint(9,9),
             column: [GridPoint(13,7), GridPoint(12,7), GridPoint(11,7),
                      GridPoint(10,7), GridPoint(9,7)]),
        Seat(name: "Blue",  start: 39, yardOrigin: GridPoint(0,9),
             column: [GridPoint(7,13), GridPoint(7,12), GridPoint(7,11),
                      GridPoint(7,10), GridPoint(7,9)])
    ]

    /// Where each token parks inside its yard, in cell units from the yard origin.
    static let yardSlots: [CGPoint] = [
        CGPoint(x: 2, y: 2), CGPoint(x: 4, y: 2),
        CGPoint(x: 2, y: 4), CGPoint(x: 4, y: 4)
    ]

    // MARK: Coordinates

    /// Converts a seat-relative ring position into an absolute ring index.
    static func absoluteRing(seat: Int, rel: Int) -> Int {
        (seats[seat].start + rel) % LudoPos.ringCount
    }

    /// The centre of a token, in cell units (0...15 on both axes).
    static func centre(seat: Int, token: Int, rel: Int) -> CGPoint {
        if rel == LudoPos.yard {
            let o = seats[seat].yardOrigin
            let s = yardSlots[token]
            return CGPoint(x: CGFloat(o.x) + s.x, y: CGFloat(o.y) + s.y)
        }
        if rel == LudoPos.goal {
            let fan: [CGPoint] = [CGPoint(x: -0.44, y: -0.44), CGPoint(x: 0.44, y: -0.44),
                                  CGPoint(x: -0.44, y:  0.44), CGPoint(x: 0.44, y:  0.44)]
            return CGPoint(x: 7.5 + fan[token].x, y: 7.5 + fan[token].y)
        }
        if rel >= LudoPos.columnStart {
            let p = seats[seat].column[rel - LudoPos.columnStart]
            return CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5)
        }
        let p = ring[absoluteRing(seat: seat, rel: rel)]
        return CGPoint(x: CGFloat(p.x) + 0.5, y: CGFloat(p.y) + 0.5)
    }

    // MARK: Rules

    /// Every move this seat may legally make with this die.
    static func legalMoves(_ state: LudoState, seat: Int, die: Int) -> [Move] {
        var out: [Move] = []
        var yardAdded = false

        for token in 0..<4 {
            let rel = state.positions[seat][token]
            if rel == LudoPos.goal { continue }

            if rel == LudoPos.yard {
                if die == 6 && !yardAdded {
                    out.append(Move(token: token, from: LudoPos.yard, to: 0))
                    yardAdded = true
                }
                continue
            }

            let dest = rel + die
            if dest <= LudoPos.goal {
                out.append(Move(token: token, from: rel, to: dest))
            }
        }
        return out
    }

    /// Opponent tokens sent back to the yard by landing on `dest`.
    static func captures(_ state: LudoState, seat: Int, dest: Int) -> [(seat: Int, token: Int)] {
        guard dest <= 50 else { return [] }
        let square = absoluteRing(seat: seat, rel: dest)
        guard !safeSquares.contains(square) else { return [] }

        var hits: [(seat: Int, token: Int)] = []
        for other in 0..<4 where other != seat {
            for token in 0..<4 {
                let rel = state.positions[other][token]
                guard rel >= 0, rel <= 50 else { continue }
                if absoluteRing(seat: other, rel: rel) == square {
                    hits.append((other, token))
                }
            }
        }
        return hits
    }

    /// How many tokens share the square this one is on, and which of them it is.
    static func stack(_ state: LudoState, seat: Int, token: Int) -> (count: Int, index: Int) {
        let rel = state.positions[seat][token]
        guard rel >= 0, rel <= 50 else { return (1, 0) }
        let square = absoluteRing(seat: seat, rel: rel)

        var count = 0, index = 0
        for s in 0..<4 {
            for t in 0..<4 {
                let r = state.positions[s][t]
                guard r >= 0, r <= 50 else { continue }
                if absoluteRing(seat: s, rel: r) == square {
                    if s == seat && t == token { index = count }
                    count += 1
                }
            }
        }
        return (count, index)
    }

    static func earnsAnotherRoll(die: Int, captured: Bool, reachedHome: Bool) -> Bool {
        die == 6 || captured || reachedHome
    }

    // MARK: Bot

    static func botChoice(_ state: LudoState, seat: Int, moves: [Move], difficulty: String = "easy") -> Move {
        if difficulty == "easy" {
            // Relaxed bot: gentle random moves, rarely aggressive
            return moves.randomElement() ?? moves[0]
        }
        func score(_ m: Move) -> Double {
            var v = 0.0
            let isCapturing = !captures(state, seat: seat, dest: m.to).isEmpty
            if isCapturing { v += (difficulty == "hard" ? 160 : 100) }
            if m.reachesHome { v += 80 }
            if m.leavesYard { v += 45 }
            if m.to > 50 { v += 30 }
            if m.to <= 50, safeSquares.contains(absoluteRing(seat: seat, rel: m.to)) { v += 18 }
            return v + Double(m.to) * 0.3
        }
        return moves.max { score($0) < score($1) } ?? moves[0]
    }
}
