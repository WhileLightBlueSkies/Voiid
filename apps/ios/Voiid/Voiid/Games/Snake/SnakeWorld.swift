//
//  SnakeWorld.swift
//  Voiid
//
//  Simulation engine for Snake Arena with spatial hashing, bot AI, and collision resolution.
//

import CoreGraphics
import Foundation

// MARK: - Spatial hash

struct SpatialHash {
    struct Entry {
        let snake: Int
        let point: CGPoint
        let radius: CGFloat
    }

    private var buckets: [Int: [Entry]] = [:]
    private let cell: CGFloat

    init(cell: CGFloat) { self.cell = cell }

    private func key(_ p: CGPoint) -> Int {
        let gx = Int(floor(p.x / cell)), gy = Int(floor(p.y / cell))
        return gx &* 73_856_093 ^ gy &* 19_349_663
    }

    mutating func removeAll() { buckets.removeAll(keepingCapacity: true) }

    mutating func insert(_ e: Entry) { buckets[key(e.point), default: []].append(e) }

    func nearby(_ p: CGPoint) -> [Entry] {
        var out: [Entry] = []
        let gx = Int(floor(p.x / cell)), gy = Int(floor(p.y / cell))
        for dx in -1...1 {
            for dy in -1...1 {
                let k = (gx + dx) &* 73_856_093 ^ (gy + dy) &* 19_349_663
                if let bucket = buckets[k] { out.append(contentsOf: bucket) }
            }
        }
        return out
    }
}

// MARK: - World

final class SnakeWorld {

    private(set) var snakes: [Snake] = []
    private(set) var food: [Food] = []
    private(set) var tick: Int = 0

    var playerAim: CGFloat?
    var playerBoosting = false
    var isPaused = false
    var activeBotCount = 11
    var playerKills = 0

    private var hash = SpatialHash(cell: 90)
    private var foodHash = SpatialHash(cell: 90)
    private var nextID = 0

    var player: Snake? { snakes.first { $0.isPlayer } }

    private static let botNames = [
        "Vyper", "Kraken", "Nagini", "Coil", "Rattler", "Mamba",
        "Sidewinder", "Boa", "Adder", "Python", "Cobra", "Basilisk",
        "Taipan", "Krait", "Fang"
    ]

    // MARK: Lifecycle

    func reset(botCount: Int = 11) {
        activeBotCount = botCount
        playerKills = 0
        snakes.removeAll()
        food.removeAll()
        nextID = 0
        tick = 0
        isPaused = false

        spawn(isPlayer: true, name: "You")
        for i in 0..<activeBotCount {
            spawn(isPlayer: false, name: Self.botNames[i % Self.botNames.count])
        }
        while food.count < Cfg.foodTarget { food.append(randomPellet()) }
    }

    @discardableResult
    private func spawn(isPlayer: Bool, name: String) -> Snake {
        let id = nextID; nextID += 1
        let angle = CGFloat.random(in: 0..<(.pi * 2))
        let dist = CGFloat.random(in: 0...(Cfg.arenaRadius * 0.72))
        let p = CGPoint.fromAngle(angle, length: dist)
        let s = Snake(id: id, name: name, skin: id % 8, isPlayer: isPlayer,
                      at: p, heading: CGFloat.random(in: 0..<(.pi * 2)))
        snakes.append(s)
        return s
    }

    func respawnPlayer() {
        snakes.removeAll { $0.isPlayer }
        spawn(isPlayer: true, name: "You")
    }

    private func randomPellet() -> Food {
        let angle = CGFloat.random(in: 0..<(.pi * 2))
        let dist = sqrt(CGFloat.random(in: 0...1)) * Cfg.arenaRadius * 0.97
        return Food(position: .fromAngle(angle, length: dist),
                    value: Cfg.foodValue,
                    skin: Int.random(in: 0..<8))
    }

    // MARK: Step

    func step(dt: CGFloat) {
        guard !isPaused else { return }
        tick += 1
        let dt = min(dt, 1.0 / 30)

        steerPlayer()
        for s in snakes where !s.isPlayer { think(s, dt: dt) }

        for s in snakes { advance(s, dt: dt) }

        rebuildHashes()
        resolveCollisions()
        consumeFood(dt: dt)

        while food.count < Cfg.foodTarget { food.append(randomPellet()) }
    }

    private func steerPlayer() {
        guard let p = player else { return }
        if let aim = playerAim { p.desiredHeading = aim }
        p.boosting = playerBoosting
    }

    private func advance(_ s: Snake, dt: CGFloat) {
        guard s.alive else { return }

        let maxTurn = Cfg.turnRate(radius: s.radius) * dt
        let delta = angleDelta(from: s.heading, to: s.desiredHeading)
        s.heading += clamp(delta, -maxTurn, maxTurn)

        if s.isBoostingEffective {
            s.mass = max(Cfg.minMass, s.mass - Cfg.boostMassPerSecond * dt)
            s.boostClock += dt
            if s.boostClock >= Cfg.boostPelletInterval {
                s.boostClock = 0
                let behind = s.body.count > 3 ? s.body[s.body.count - 1] : s.head
                food.append(Food(position: behind,
                                 value: Cfg.boostPelletValue,
                                 skin: s.skin))
            }
        }

        s.head = s.head + .fromAngle(s.heading, length: s.speed * dt)
        s.trail.record(s.head, minStep: max(2, s.radius * 0.25))
        s.trail.trim(toLength: CGFloat(s.segmentCount + 4) * s.spacing)
        s.rebuildBody()
    }

    private func rebuildHashes() {
        hash.removeAll()
        for s in snakes where s.alive {
            for (i, p) in s.body.enumerated() where i > 2 {
                hash.insert(.init(snake: s.id, point: p, radius: s.radius))
            }
        }
        foodHash.removeAll()
    }

    // MARK: Collisions

    private func resolveCollisions() {
        var doomed: Set<Int> = []

        for s in snakes where s.alive {
            // Wall
            if s.head.length + s.radius * 0.5 > Cfg.arenaRadius {
                doomed.insert(s.id)
                continue
            }
            // Bodies
            for e in hash.nearby(s.head) where e.snake != s.id {
                let reach = s.radius * 0.72 + e.radius * 0.85
                if s.head.distanceSquared(to: e.point) < reach * reach {
                    doomed.insert(s.id)
                    if let player = player, e.snake == player.id, !s.isPlayer {
                        playerKills += 1
                    }
                    break
                }
            }
        }

        guard !doomed.isEmpty else { return }
        for s in snakes where doomed.contains(s.id) { kill(s) }
        snakes.removeAll { !$0.alive && !$0.isPlayer }

        while snakes.filter({ !$0.isPlayer }).count < activeBotCount {
            spawn(isPlayer: false, name: Self.botNames.randomElement() ?? "Bot")
        }
    }

    private func kill(_ s: Snake) {
        s.alive = false
        let total = s.mass * Cfg.corpseValueFactor
        let pellets = max(4, Int(total / Cfg.corpsePelletValue))
        guard !s.body.isEmpty else { return }
        for i in 0..<pellets {
            let t = CGFloat(i) / CGFloat(max(pellets - 1, 1))
            let idx = Int(t * CGFloat(s.body.count - 1))
            let jitter = CGPoint(x: .random(in: -6...6), y: .random(in: -6...6))
            food.append(Food(position: s.body[idx] + jitter,
                             value: Cfg.corpsePelletValue,
                             skin: s.skin,
                             velocity: jitter * 3))
        }
    }

    // MARK: Food

    private func consumeFood(dt: CGFloat) {
        guard !food.isEmpty else { return }
        var eaten = Set<Int>()

        for s in snakes where s.alive {
            let pull = s.radius * Cfg.magnetRange
            let pullSq = pull * pull
            let bite = s.radius + Cfg.foodRadius

            for i in food.indices where !eaten.contains(i) {
                let d2 = food[i].position.distanceSquared(to: s.head)
                guard d2 < pullSq else { continue }

                if d2 < bite * bite {
                    s.mass = min(Cfg.maxMass, s.mass + food[i].value)
                    eaten.insert(i)
                } else {
                    let dir = s.head - food[i].position
                    let n = dir * (1 / max(dir.length, 0.001))
                    food[i].position = food[i].position + n * (Cfg.magnetSpeed * dt)
                }
            }
        }

        for i in food.indices where food[i].velocity.length > 1 {
            food[i].position = food[i].position + food[i].velocity * dt
            food[i].velocity = food[i].velocity * 0.88
        }

        if !eaten.isEmpty {
            var kept: [Food] = []
            kept.reserveCapacity(food.count - eaten.count)
            for (i, f) in food.enumerated() where !eaten.contains(i) { kept.append(f) }
            food = kept
        }
    }

    // MARK: Bots

    private func think(_ s: Snake, dt: CGFloat) {
        guard s.alive else { return }
        s.thinkClock += dt
        guard s.thinkClock >= Cfg.botThinkInterval else { return }
        s.thinkClock = 0

        let look = s.radius * 7 + 60
        let offsets: [CGFloat] = [0, -0.35, 0.35, -0.75, 0.75, -1.25, 1.25, -1.9, 1.9]
        var best: (angle: CGFloat, clearance: CGFloat)?

        for off in offsets {
            let a = s.heading + off
            let clearance = probe(from: s, angle: a, distance: look)
            if clearance >= look {
                best = (a, clearance)
                break
            }
            if best == nil || clearance > best!.clearance { best = (a, clearance) }
        }

        let blocked = (best?.clearance ?? 0) < look
        if blocked, let b = best {
            s.desiredHeading = b.angle
            s.boosting = false
            return
        }

        var target: CGPoint?
        var bestScore = CGFloat.greatestFiniteMagnitude
        let searchSq: CGFloat = 700 * 700
        for f in food {
            let d2 = f.position.distanceSquared(to: s.head)
            guard d2 < searchSq else { continue }
            let score = d2 / (f.value * f.value)
            if score < bestScore { bestScore = score; target = f.position }
        }

        if let t = target {
            let aim = (t - s.head).angle
            if probe(from: s, angle: aim, distance: look * 0.8) >= look * 0.8 {
                s.desiredHeading = aim
            }
        } else {
            if s.head.length > Cfg.arenaRadius * 0.8 {
                s.desiredHeading = (CGPoint.zero - s.head).angle
            }
        }

        s.boosting = s.mass > 60 && bestScore < 200 * 200 && Int.random(in: 0..<7) == 0
    }

    private func probe(from s: Snake, angle: CGFloat, distance: CGFloat) -> CGFloat {
        let steps = 6
        for i in 1...steps {
            let t = distance * CGFloat(i) / CGFloat(steps)
            let p = s.head + .fromAngle(angle, length: t)

            if p.length + s.radius > Cfg.arenaRadius { return t }

            for e in hash.nearby(p) where e.snake != s.id {
                let reach = s.radius + e.radius * 1.15
                if p.distanceSquared(to: e.point) < reach * reach { return t }
            }
        }
        return distance
    }

    // MARK: Readouts

    func leaderboard(limit: Int = 5) -> [(name: String, score: Int, isPlayer: Bool)] {
        snakes.filter { $0.alive }
            .sorted { $0.mass > $1.mass }
            .prefix(limit)
            .map { ($0.name, $0.score, $0.isPlayer) }
    }

    func rank(of s: Snake) -> Int {
        1 + snakes.filter { $0.alive && $0.mass > s.mass }.count
    }
}
