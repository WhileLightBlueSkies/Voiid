//
//  CarromEngine.swift
//  Voiid Ui
//
//  Carrom rules engine, board layout generator, turn/foul/cover evaluation,
//  and intelligent raycasting Bot AI.
//

import CoreGraphics
import Foundation

// MARK: - Game Mode & Rules Configuration

enum CarromGameMode: String, CaseIterable, Identifiable {
    case classic = "Classic"

    var id: String { rawValue }

    var description: String {
        switch self {
        case .classic: return "You play white. The bot plays black. Cover the queen and clear your colour."
        }
    }
}

enum CarromTurn: Int, CaseIterable, Identifiable {
    case player1 = 0
    case player2 = 1

    var id: Int { rawValue }

    var opposite: CarromTurn {
        self == .player1 ? .player2 : .player1
    }
}

// MARK: - Engine

enum CarromEngine {

    // MARK: - Initial Board Layout

    /// Generates standard 19-piece carrom rosette at board center + striker
    /// Uses authentic Hexagonal Close-Packed (HCP) geometry where every piece is tangent
    static func generateStartingPieces() -> [CarromPiece] {
        var pieces: [CarromPiece] = []
        let center = CGPoint(x: CarromTheme.surfaceSize / 2, y: CarromTheme.surfaceSize / 2) // (180, 180)
        let r = CarromTheme.pieceRadius // 11.5
        var idCounter = 1

        // 1. Center Queen
        pieces.append(CarromPiece(
            id: idCounter,
            type: .queen,
            position: center,
            radius: r,
            mass: CarromTheme.pieceMass
        ))
        idCounter += 1

        // 2. Inner Ring (6 pieces: 3 White, 3 Black alternating)
        // Tangent to queen at distance 2 * r
        let innerDistance = r * 2.0
        for i in 0..<6 {
            let angle = CGFloat(i) * (.pi / 3.0) // 60 deg intervals
            let pos = CGPoint(
                x: center.x + cos(angle) * innerDistance,
                y: center.y + sin(angle) * innerDistance
            )
            let type: CarromPieceType = (i % 2 == 0) ? .white : .black
            pieces.append(CarromPiece(
                id: idCounter,
                type: type,
                position: pos,
                radius: r,
                mass: CarromTheme.pieceMass
            ))
            idCounter += 1
        }

        // 3. Outer Ring (12 pieces in HCP arrangement: 6 corners at 4r, 6 edges at 2*sqrt(3)*r)
        // Alternates White and Black to give 6 White and 6 Black in outer ring (total 9W, 9B, 1Q)
        let cornerDistance = r * 4.0
        let edgeDistance = 2.0 * sqrt(3.0) * r

        var outerSlots: [(pos: CGPoint, type: CarromPieceType)] = []
        for i in 0..<6 {
            let cornerAngle = CGFloat(i) * (.pi / 3.0)
            let cornerPos = CGPoint(
                x: center.x + cos(cornerAngle) * cornerDistance,
                y: center.y + sin(cornerAngle) * cornerDistance
            )
            // Pattern: corner is opposite of inner piece at same angle
            let cornerType: CarromPieceType = (i % 2 == 0) ? .black : .white
            outerSlots.append((pos: cornerPos, type: cornerType))

            let edgeAngle = cornerAngle + (.pi / 6.0)
            let edgePos = CGPoint(
                x: center.x + cos(edgeAngle) * edgeDistance,
                y: center.y + sin(edgeAngle) * edgeDistance
            )
            let edgeType: CarromPieceType = (i % 2 == 0) ? .white : .black
            outerSlots.append((pos: edgePos, type: edgeType))
        }

        for slot in outerSlots {
            pieces.append(CarromPiece(
                id: idCounter,
                type: slot.type,
                position: slot.pos,
                radius: r,
                mass: CarromTheme.pieceMass
            ))
            idCounter += 1
        }

        // 4. Initial Striker on Player 1's baseline
        let strikerPos = baselinePosition(for: .player1, normalizedX: 0.5)
        pieces.append(CarromPiece(
            id: 0,
            type: .striker,
            position: strikerPos,
            radius: CarromTheme.strikerRadius,
            mass: CarromTheme.strikerMass
        ))

        return pieces
    }

    // MARK: - Baseline Geometry

    /// Baseline range: left X = 74, right X = 286
    static let baselineMinX: CGFloat = 74.0
    static let baselineMaxX: CGFloat = CarromTheme.surfaceSize - 74.0

    static func baselineY(for turn: CarromTurn) -> CGFloat {
        if turn == .player1 {
            return CarromTheme.surfaceSize - CarromTheme.baselineInset // Bottom: 308
        } else {
            return CarromTheme.baselineInset // Top: 52
        }
    }

    static func baselinePosition(for turn: CarromTurn, normalizedX: CGFloat) -> CGPoint {
        let clampedX = min(max(normalizedX, 0.0), 1.0)
        let x = baselineMinX + (baselineMaxX - baselineMinX) * clampedX
        let y = baselineY(for: turn)
        return CGPoint(x: x, y: y)
    }

    /// Validates striker doesn't overlap any piece on the board
    static func isStrikerPlacementValid(at pos: CGPoint, pieces: [CarromPiece]) -> Bool {
        let strikerRadius = CarromTheme.strikerRadius
        for p in pieces where p.type != .striker && !p.isPocketed {
            let dist = pos.distance(to: p.position)
            if dist < (strikerRadius + p.radius + 1.0) {
                return false // Overlapping
            }
        }
        return true
    }

    // MARK: - Bot AI

    struct BotShot {
        let baselineX: CGFloat       // Normalized 0.0 ... 1.0
        let aimDirection: CGVector   // Vector to strike
        let power: CGFloat           // 300 ... 800 pt/s
    }

    /// Evaluates board and generates intelligent bot strike
    static func calculateBotShot(pieces: [CarromPiece], difficulty: Int = 2) -> BotShot {
        let pockets = [
            CGPoint(x: CarromTheme.pocketInset, y: CarromTheme.pocketInset),
            CGPoint(x: CarromTheme.surfaceSize - CarromTheme.pocketInset, y: CarromTheme.pocketInset),
            CGPoint(x: CarromTheme.surfaceSize - CarromTheme.pocketInset, y: CarromTheme.surfaceSize - CarromTheme.pocketInset),
            CGPoint(x: CarromTheme.pocketInset, y: CarromTheme.surfaceSize - CarromTheme.pocketInset)
        ]

        let availablePieces = pieces.filter { ($0.type == .black || $0.type == .queen) && !$0.isPocketed }
        guard !availablePieces.isEmpty else {
            return BotShot(baselineX: 0.5, aimDirection: CGVector(dx: 0, dy: 1), power: 500)
        }

        var bestTarget: CarromPiece? = nil
        var bestPocket: CGPoint = pockets[2]
        var bestBaselineNormX: CGFloat = 0.5
        var bestScore: CGFloat = -1000

        // Prioritize Queen if on board, then White / Black
        let testPositions = stride(from: 0.1, through: 0.9, by: 0.1).map { CGFloat($0) }

        for target in availablePieces {
            let priorityWeight: CGFloat = (target.type == .queen) ? 1.8 : 1.0

            for pocket in pockets {
                let toPocket = (pocket - target.position).normalized()
                // Ghost striker position behind the target piece
                let ghostPos = target.position - (toPocket * (CarromTheme.strikerRadius + target.radius))

                for normX in testPositions {
                    let strikerPos = baselinePosition(for: .player2, normalizedX: normX)

                    // Striker must shoot DOWNWARDS toward bottom of board
                    let shotVec = ghostPos - strikerPos
                    if shotVec.y < 20 { continue } // Can't shoot backwards

                    let shotDist = shotVec.length
                    let pocketDist = target.position.distance(to: pocket)
                    let alignment = shotVec.normalized().dot(with: toPocket)

                    // Scoring heuristic
                    let score = (alignment * 200.0) - (shotDist * 0.4) - (pocketDist * 0.3) + (priorityWeight * 60.0)

                    if score > bestScore && isStrikerPlacementValid(at: strikerPos, pieces: pieces) {
                        bestScore = score
                        bestTarget = target
                        bestPocket = pocket
                        bestBaselineNormX = normX
                    }
                }
            }
        }

        guard let target = bestTarget else {
            // Fallback shot toward center
            let freeX = stride(from: 0.0, through: 1.0, by: 0.01).map { CGFloat($0) }.first {
                isStrikerPlacementValid(at: baselinePosition(for: .player2, normalizedX: $0), pieces: pieces)
            } ?? 0.5
            let strikerPos = baselinePosition(for: .player2, normalizedX: freeX)
            let center = CGPoint(x: CarromTheme.surfaceSize / 2, y: CarromTheme.surfaceSize / 2)
            let dir = (center - strikerPos).normalized().vector
            return BotShot(baselineX: freeX, aimDirection: dir, power: 550)
        }

        let strikerPos = baselinePosition(for: .player2, normalizedX: bestBaselineNormX)
        let toPocket = (bestPocket - target.position).normalized()
        let ghostPos = target.position - (toPocket * (CarromTheme.strikerRadius + target.radius))
        var aimDir = (ghostPos - strikerPos).normalized().vector

        // Apply realistic humanized variance according to difficulty
        let jitterScale: CGFloat = (difficulty == 1) ? 0.07 : (difficulty == 2) ? 0.03 : 0.008
        let jitterAngle = CGFloat.random(in: -jitterScale...jitterScale)
        let cosA = cos(jitterAngle), sinA = sin(jitterAngle)
        aimDir = CGVector(dx: aimDir.dx * cosA - aimDir.dy * sinA,
                          dy: aimDir.dx * sinA + aimDir.dy * cosA)

        let power = CGFloat.random(in: 560...720)
        return BotShot(baselineX: bestBaselineNormX, aimDirection: aimDir, power: power)
    }
}
