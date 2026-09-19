//
//  CarromPhysics.swift
//  Voiid Ui
//
//  Deterministic, high-performance 2D rigid body physics engine for Carrom.
//  Handles circle-circle collisions, cushion bounces, boric powder sliding friction,
//  pocket gravity wells, and aim raycasting with wall reflection.
//

import CoreGraphics
import Foundation

// MARK: - 2D Vector Math Extensions

extension CGPoint {
    var vector: CGVector { CGVector(dx: x, dy: y) }
    var lengthSquared: CGFloat { x * x + y * y }

    func dot(with other: CGPoint) -> CGFloat { x * other.x + y * other.y }
    func dot(with other: CGVector) -> CGFloat { x * other.dx + y * other.dy }

    func normalized() -> CGPoint {
        let len = length
        guard len > 0.0001 else { return .zero }
        return CGPoint(x: x / len, y: y / len)
    }

    static func + (lhs: CGPoint, rhs: CGVector) -> CGPoint {
        CGPoint(x: lhs.x + rhs.dx, y: lhs.y + rhs.dy)
    }
    static func - (lhs: CGPoint, rhs: CGVector) -> CGPoint {
        CGPoint(x: lhs.x - rhs.dx, y: lhs.y - rhs.dy)
    }
}

extension CGVector {
    var point: CGPoint { CGPoint(x: dx, y: dy) }

    static func + (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx + rhs.dx, dy: lhs.dy + rhs.dy)
    }
    static func - (lhs: CGVector, rhs: CGVector) -> CGVector {
        CGVector(dx: lhs.dx - rhs.dx, dy: lhs.dy - rhs.dy)
    }
    static func * (lhs: CGVector, rhs: CGFloat) -> CGVector {
        CGVector(dx: lhs.dx * rhs, dy: lhs.dy * rhs)
    }
    static func / (lhs: CGVector, rhs: CGFloat) -> CGVector {
        CGVector(dx: lhs.dx / rhs, dy: lhs.dy / rhs)
    }
    var lengthSquared: CGFloat { dx * dx + dy * dy }
    var length: CGFloat { sqrt(lengthSquared) }

    func normalized() -> CGVector {
        let len = length
        guard len > 0.0001 else { return .zero }
        return CGVector(dx: dx / len, dy: dy / len)
    }

    func dot(with other: CGVector) -> CGFloat {
        dx * other.dx + dy * other.dy
    }
    func dot(with other: CGPoint) -> CGFloat {
        dx * other.x + dy * other.y
    }

    var angle: CGFloat {
        atan2(dy, dx)
    }

    static func fromAngle(_ angle: CGFloat, length: CGFloat = 1.0) -> CGVector {
        CGVector(dx: cos(angle) * length, dy: sin(angle) * length)
    }
}

// MARK: - Piece Model

enum CarromPieceType: String, CaseIterable, Identifiable, Hashable {
    case white
    case black
    case queen
    case striker

    var id: String { rawValue }

    var isCarromMan: Bool { self != .striker }
}

struct CarromPiece: Identifiable, Equatable {
    let id: Int
    let type: CarromPieceType
    var position: CGPoint
    var velocity: CGVector = .zero
    var radius: CGFloat
    var mass: CGFloat

    var isPocketed: Bool = false
    var sinkProgress: CGFloat = 0.0 // 0.0 = on board, 1.0 = fully in pocket
    var pocketIndex: Int? = nil

    var isMoving: Bool {
        velocity.lengthSquared > 1.0
    }
}

// MARK: - Aim Guide Prediction Model

struct CarromAimResult {
    let strikerPos: CGPoint
    let rayStart: CGPoint
    let rayEnd: CGPoint
    let hasWallHit: Bool
    let wallBounceEnd: CGPoint?
    let targetPieceID: Int?
    let ghostStrikerPos: CGPoint?
    let targetDeflectionEnd: CGPoint?
}

// MARK: - Physics Simulation World

final class CarromPhysicsWorld {

    var pieces: [CarromPiece] = []
    let surfaceSize: CGFloat = CarromTheme.surfaceSize

    // Pockets: 4 corners
    let pocketCenters: [CGPoint] = [
        CGPoint(x: CarromTheme.pocketInset, y: CarromTheme.pocketInset), // Top-Left
        CGPoint(x: CarromTheme.surfaceSize - CarromTheme.pocketInset, y: CarromTheme.pocketInset), // Top-Right
        CGPoint(x: CarromTheme.surfaceSize - CarromTheme.pocketInset, y: CarromTheme.surfaceSize - CarromTheme.pocketInset), // Bottom-Right
        CGPoint(x: CarromTheme.pocketInset, y: CarromTheme.surfaceSize - CarromTheme.pocketInset) // Bottom-Left
    ]

    /// Callback fired on notable piece-to-piece impacts (impulse magnitude)
    var onPieceCollision: ((CGFloat) -> Void)?
    /// Callback fired on cushion impacts
    var onCushionBounce: (() -> Void)?
    /// Callback fired when a piece drops into a pocket
    var onPiecePocketed: ((CarromPiece, Int) -> Void)?

    // MARK: - Stepping Physics

    /// Step simulation with sub-stepping for tunneling prevention
    func step(dt: CGFloat) {
        guard dt > 0 else { return }
        let subSteps = 4
        let subDt = dt / CGFloat(subSteps)

        for _ in 0..<subSteps {
            subStep(dt: subDt)
        }
    }

    private func subStep(dt: CGFloat) {
        // 1. Integrate position, handle pocket suction, glide friction, and cushion bounce
        for i in pieces.indices {
            guard !pieces[i].isPocketed else { continue }

            // Pocket suction check
            checkPocketSuction(pieceIndex: i, dt: dt)

            if pieces[i].sinkProgress > 0 {
                // Inside pocket gravity well - smoothly gravitate to pocket center
                pieces[i].position = pieces[i].position + (pieces[i].velocity * dt)
                continue
            }

            // Normal surface sliding
            pieces[i].position = pieces[i].position + (pieces[i].velocity * dt)

            // Boric acid powder friction model:
            // Constant Coulomb sliding friction + light viscous resistance
            let speed = pieces[i].velocity.length
            if speed > 1.0 {
                let linearDecel: CGFloat = 310.0 // pt/s^2 (realistic carrom powder glide)
                let dragRate: CGFloat = 0.55     // 1/s (viscous surface drag)
                let totalDecel = (linearDecel + dragRate * speed) * dt

                if speed <= totalDecel {
                    pieces[i].velocity = .zero
                } else {
                    let dir = pieces[i].velocity.normalized()
                    pieces[i].velocity = dir * (speed - totalDecel)
                }
            } else {
                pieces[i].velocity = .zero
            }

            // Cushion wall bounce & boundary clamping
            resolveCushionBounce(pieceIndex: i)
        }

        // 2. Piece-to-Piece Collisions
        resolvePieceCollisions()
    }

    // MARK: - Pocket Gravity & Suction

    private func checkPocketSuction(pieceIndex: Int, dt: CGFloat) {
        let p = pieces[pieceIndex].position
        let r = pieces[pieceIndex].radius
        let suctionRadius = CarromTheme.pocketRadius + (r * 0.40)

        for (idx, pocket) in pocketCenters.enumerated() {
            let dist = p.distance(to: pocket)
            if pieces[pieceIndex].pocketIndex == idx || (pieces[pieceIndex].pocketIndex == nil && dist < suctionRadius) {
                if pieces[pieceIndex].pocketIndex == nil {
                    pieces[pieceIndex].pocketIndex = idx
                }

                // Sinking pull towards pocket center
                let toPocket = (pocket - p).normalized().vector
                let suctionForce: CGFloat = 450.0
                pieces[pieceIndex].velocity = pieces[pieceIndex].velocity + (toPocket * (suctionForce * dt))
                pieces[pieceIndex].velocity = pieces[pieceIndex].velocity * 0.82

                pieces[pieceIndex].sinkProgress += dt * 6.5
                if pieces[pieceIndex].sinkProgress >= 1.0 || dist < (CarromTheme.pocketRadius * 0.55) {
                    pieces[pieceIndex].isPocketed = true
                    pieces[pieceIndex].sinkProgress = 1.0
                    pieces[pieceIndex].velocity = .zero
                    pieces[pieceIndex].position = pocket
                    onPiecePocketed?(pieces[pieceIndex], idx)
                }
                return
            }
        }
    }

    // MARK: - Cushion Bounces & Boundary Clamping

    private func resolveCushionBounce(pieceIndex: Int) {
        guard pieces[pieceIndex].sinkProgress == 0 else { return }

        let r = pieces[pieceIndex].radius
        var pos = pieces[pieceIndex].position
        var vel = pieces[pieceIndex].velocity
        let restitution: CGFloat = 0.74 // Natural rubber cushion elasticity
        var bounced = false

        // Left cushion (x = r)
        if pos.x - r < 0 {
            pos.x = r
            if vel.dx < 0 {
                vel.dx = -vel.dx * restitution
                bounced = true
            }
        }

        // Right cushion (x = surfaceSize - r)
        if pos.x + r > surfaceSize {
            pos.x = surfaceSize - r
            if vel.dx > 0 {
                vel.dx = -vel.dx * restitution
                bounced = true
            }
        }

        // Top cushion (y = r)
        if pos.y - r < 0 {
            pos.y = r
            if vel.dy < 0 {
                vel.dy = -vel.dy * restitution
                bounced = true
            }
        }

        // Bottom cushion (y = surfaceSize - r)
        if pos.y + r > surfaceSize {
            pos.y = surfaceSize - r
            if vel.dy > 0 {
                vel.dy = -vel.dy * restitution
                bounced = true
            }
        }

        pieces[pieceIndex].position = pos
        pieces[pieceIndex].velocity = vel

        if bounced && vel.length > 25 {
            onCushionBounce?()
        }
    }

    private func clampPieceToSurface(pieceIndex: Int) {
        guard pieces[pieceIndex].sinkProgress == 0 else { return }
        let r = pieces[pieceIndex].radius
        pieces[pieceIndex].position.x = min(max(pieces[pieceIndex].position.x, r), surfaceSize - r)
        pieces[pieceIndex].position.y = min(max(pieces[pieceIndex].position.y, r), surfaceSize - r)
    }

    // MARK: - Circle-Circle Collisions

    private func resolvePieceCollisions() {
        let count = pieces.count
        guard count > 1 else { return }

        // Two passes of relaxation for cluster dynamics
        for _ in 0..<2 {
            for i in 0..<count {
                guard !pieces[i].isPocketed, pieces[i].sinkProgress == 0 else { continue }

                for j in (i + 1)..<count {
                    guard !pieces[j].isPocketed, pieces[j].sinkProgress == 0 else { continue }

                    let delta = pieces[j].position - pieces[i].position
                    let distSq = delta.lengthSquared
                    let minDist = pieces[i].radius + pieces[j].radius

                    if distSq < (minDist * minDist) && distSq > 0.0001 {
                        let dist = sqrt(distSq)
                        let normal = (delta * (1.0 / dist)).vector // Direction from i to j
                        let overlap = minDist - dist

                        // Separate positions proportionally by inverse mass
                        let invMassI = 1.0 / pieces[i].mass
                        let invMassJ = 1.0 / pieces[j].mass
                        let invMassSum = invMassI + invMassJ

                        let moveI = overlap * (invMassI / invMassSum)
                        let moveJ = overlap * (invMassJ / invMassSum)

                        pieces[i].position = pieces[i].position - (normal * moveI)
                        pieces[j].position = pieces[j].position + (normal * moveJ)

                        // Boundary clamp prevents pieces pushing through cushions
                        clampPieceToSurface(pieceIndex: i)
                        clampPieceToSurface(pieceIndex: j)

                        // Relative velocity along collision normal
                        let relVel = pieces[i].velocity - pieces[j].velocity
                        let velAlongNormal = relVel.dot(with: normal)

                        // Only apply impulse if pieces are moving towards each other
                        if velAlongNormal > 0 {
                            let restitution: CGFloat = 0.74 // Natural wooden piece restitution
                            let impulseMagnitude = (1.0 + restitution) * velAlongNormal / invMassSum

                            let impulse = normal * impulseMagnitude
                            pieces[i].velocity = pieces[i].velocity - (impulse * invMassI)
                            pieces[j].velocity = pieces[j].velocity + (impulse * invMassJ)

                            if impulseMagnitude > 20 {
                                onPieceCollision?(impulseMagnitude)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Raycast Aim Prediction

    func predictAim(from origin: CGPoint, direction: CGVector, maxDist: CGFloat = 500) -> CarromAimResult {
        let dir = direction.normalized()
        guard dir.lengthSquared > 0.1 else {
            return CarromAimResult(strikerPos: origin, rayStart: origin, rayEnd: origin,
                                   hasWallHit: false, wallBounceEnd: nil,
                                   targetPieceID: nil, ghostStrikerPos: nil,
                                   targetDeflectionEnd: nil)
        }

        let strikerRadius = CarromTheme.strikerRadius
        var nearestHitDist = maxDist
        var hitPiece: CarromPiece? = nil

        // Check intersection with all other active carrom pieces
        for piece in pieces where piece.type != .striker && !piece.isPocketed {
            // Circle ray intersection: |(P + t*D) - C|^2 = (r1 + r2)^2
            let oc = piece.position - origin
            let tca = oc.dot(with: dir)
            if tca < 0 { continue } // Behind striker

            let d2 = oc.lengthSquared - (tca * tca)
            let combinedRadius = strikerRadius + piece.radius
            let r2 = combinedRadius * combinedRadius
            if d2 > r2 { continue } // Ray misses piece

            let thc = sqrt(max(0, r2 - d2))
            let t = tca - thc
            if t > 0 && t < nearestHitDist {
                nearestHitDist = t
                hitPiece = piece
            }
        }

        if let target = hitPiece {
            // Striker hits a piece directly
            let rayEnd = origin + (dir * nearestHitDist)
            let ghostStrikerPos = rayEnd

            // Deflection of target piece: along vector from ghost striker to target piece center
            let normal = (target.position - ghostStrikerPos).normalized()
            let deflectionEnd = target.position + (normal.vector * 52.0)

            return CarromAimResult(
                strikerPos: origin,
                rayStart: origin,
                rayEnd: rayEnd,
                hasWallHit: false,
                wallBounceEnd: nil,
                targetPieceID: target.id,
                ghostStrikerPos: ghostStrikerPos,
                targetDeflectionEnd: deflectionEnd
            )
        }

        // Ray hits a cushion wall first
        var wallT = maxDist
        var wallNormal = CGVector.zero

        // Left
        if dir.dx < 0 {
            let t = (strikerRadius - origin.x) / dir.dx
            if t > 0 && t < wallT { wallT = t; wallNormal = CGVector(dx: 1, dy: 0) }
        }
        // Right
        if dir.dx > 0 {
            let t = (surfaceSize - strikerRadius - origin.x) / dir.dx
            if t > 0 && t < wallT { wallT = t; wallNormal = CGVector(dx: -1, dy: 0) }
        }
        // Top
        if dir.dy < 0 {
            let t = (strikerRadius - origin.y) / dir.dy
            if t > 0 && t < wallT { wallT = t; wallNormal = CGVector(dx: 0, dy: 1) }
        }
        // Bottom
        if dir.dy > 0 {
            let t = (surfaceSize - strikerRadius - origin.y) / dir.dy
            if t > 0 && t < wallT { wallT = t; wallNormal = CGVector(dx: 0, dy: -1) }
        }

        let rayEnd = origin + (dir * wallT)
        // Calculate reflection
        let dot = dir.dot(with: wallNormal)
        let bounceDir = dir - (wallNormal * (2.0 * dot))
        let bounceEnd = rayEnd + (bounceDir.normalized() * 60.0)

        return CarromAimResult(
            strikerPos: origin,
            rayStart: origin,
            rayEnd: rayEnd,
            hasWallHit: true,
            wallBounceEnd: bounceEnd,
            targetPieceID: nil,
            ghostStrikerPos: nil,
            targetDeflectionEnd: nil
        )
    }

    /// Are all pieces settled and stationary?
    var isSettled: Bool {
        for p in pieces where !p.isPocketed {
            if p.velocity.lengthSquared > 2.0 || p.sinkProgress > 0 {
                return false
            }
        }
        return true
    }
}
