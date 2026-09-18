//
//  SnakeCore.swift
//  Voiid
//
//  Maths, tuning, and entities for the continuous slither battle arena.
//

import CoreGraphics
import Foundation

// MARK: - Vector helpers

extension CGPoint {
    static func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
    static func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
    static func * (a: CGPoint, s: CGFloat) -> CGPoint { CGPoint(x: a.x * s, y: a.y * s) }

    var length: CGFloat { sqrt(x * x + y * y) }
    var angle: CGFloat { atan2(y, x) }

    func distance(to p: CGPoint) -> CGFloat { (self - p).length }
    func distanceSquared(to p: CGPoint) -> CGFloat {
        let dx = x - p.x, dy = y - p.y
        return dx * dx + dy * dy
    }
    func lerp(to p: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: x + (p.x - x) * t, y: y + (p.y - y) * t)
    }

    static func fromAngle(_ a: CGFloat, length: CGFloat = 1) -> CGPoint {
        CGPoint(x: cos(a) * length, y: sin(a) * length)
    }
}

func angleDelta(from: CGFloat, to: CGFloat) -> CGFloat {
    var d = (to - from).truncatingRemainder(dividingBy: .pi * 2)
    if d > .pi { d -= .pi * 2 }
    if d < -.pi { d += .pi * 2 }
    return d
}

func clamp<T: Comparable>(_ v: T, _ lo: T, _ hi: T) -> T { min(max(v, lo), hi) }

// MARK: - Tuning

enum Cfg {
    static let arenaRadius: CGFloat = 2400

    static let startMass: CGFloat = 14
    static let minMass: CGFloat = 10
    static let maxMass: CGFloat = 4000

    static let baseSpeed: CGFloat = 205
    static let boostSpeed: CGFloat = 355
    static let boostMassPerSecond: CGFloat = 14
    static let boostPelletInterval: CGFloat = 0.11
    static let boostPelletValue: CGFloat = 1.3

    static func turnRate(radius: CGFloat) -> CGFloat {
        clamp(5.6 - radius * 0.055, 1.9, 5.6)
    }

    static func radius(mass: CGFloat) -> CGFloat {
        9 * pow(max(mass, minMass) / startMass, 0.29)
    }

    static func segmentSpacing(radius: CGFloat) -> CGFloat { radius * 0.58 }

    static func segmentCount(mass: CGFloat) -> Int {
        Int(clamp(10 + mass * 0.42, 10, 320))
    }

    // Food
    static let foodTarget = 620
    static let foodRadius: CGFloat = 5.5
    static let foodValue: CGFloat = 1.0
    static let magnetRange: CGFloat = 4.2
    static let magnetSpeed: CGFloat = 430

    // Death scatter
    static let corpseValueFactor: CGFloat = 0.62
    static let corpsePelletValue: CGFloat = 3.0

    static var botCount = 11
    static let botThinkInterval: CGFloat = 0.09
}

// MARK: - Trail

struct Trail {
    private(set) var points: [CGPoint] = []

    mutating func reset(at p: CGPoint) { points = [p, p] }

    mutating func record(_ p: CGPoint, minStep: CGFloat) {
        guard points.count >= 2 else { points = [p, p]; return }
        let anchor = points[points.count - 2]
        if anchor.distance(to: p) >= minStep {
            points.append(p)
        } else {
            points[points.count - 1] = p
        }
    }

    mutating func trim(toLength maxLength: CGFloat) {
        guard points.count > 2 else { return }
        var acc: CGFloat = 0
        var i = points.count - 1
        while i > 0 {
            acc += points[i].distance(to: points[i - 1])
            if acc >= maxLength { break }
            i -= 1
        }
        if i > 1 { points.removeFirst(i - 1) }
    }

    func sample(spacing: CGFloat, count: Int) -> [CGPoint] {
        var out: [CGPoint] = []
        out.reserveCapacity(count)
        guard let head = points.last else { return out }
        out.append(head)
        guard count > 1 else { return out }

        var i = points.count - 1
        var cursor = head
        var need = spacing

        while out.count < count {
            if i == 0 {
                out.append(points[0])
                continue
            }
            let next = points[i - 1]
            let seg = cursor.distance(to: next)
            if seg >= need {
                let t = need / max(seg, 0.0001)
                cursor = cursor.lerp(to: next, t: t)
                out.append(cursor)
                need = spacing
            } else {
                need -= seg
                cursor = next
                i -= 1
            }
        }
        return out
    }
}

// MARK: - Entities

final class Snake {
    let id: Int
    let name: String
    let skin: Int
    let isPlayer: Bool

    var head: CGPoint
    var heading: CGFloat
    var desiredHeading: CGFloat
    var mass: CGFloat = Cfg.startMass
    var boosting = false
    var alive = true

    var trail = Trail()
    var body: [CGPoint] = []

    var boostClock: CGFloat = 0
    var thinkClock: CGFloat = 0

    init(id: Int, name: String, skin: Int, isPlayer: Bool, at p: CGPoint, heading: CGFloat) {
        self.id = id
        self.name = name
        self.skin = skin
        self.isPlayer = isPlayer
        self.head = p
        self.heading = heading
        self.desiredHeading = heading
        trail.reset(at: p)
    }

    var radius: CGFloat { Cfg.radius(mass: mass) }
    var spacing: CGFloat { Cfg.segmentSpacing(radius: radius) }
    var segmentCount: Int { Cfg.segmentCount(mass: mass) }
    var score: Int { Int(mass) }

    var isBoostingEffective: Bool { boosting && mass > Cfg.minMass + 2 }
    var speed: CGFloat { isBoostingEffective ? Cfg.boostSpeed : Cfg.baseSpeed }

    func rebuildBody() {
        body = trail.sample(spacing: spacing, count: segmentCount)
    }
}

struct Food {
    var position: CGPoint
    var value: CGFloat
    var skin: Int
    var velocity: CGPoint = .zero

    var radius: CGFloat { Cfg.foodRadius * (1 + (value - 1) * 0.16) }
}
