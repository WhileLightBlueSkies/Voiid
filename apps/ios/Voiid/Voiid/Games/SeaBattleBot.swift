//
//  SeaBattleBot.swift
//  Voiid
//
//  The practice opponent (docs/games/future/SEA_BATTLE.md §11).
//
//  SEA BATTLE IS THE HAPPY CASE FOR A DIFFICULTY SLIDER, and that is worth stating because the
//  other bots in this app are careful about the opposite. RpsBot refuses to fake a scale at all
//  ("against a truly random opponent, RPS has no skill... a difficulty slider over it would be a
//  lie"), and Snake's difficulty maps to BOT COUNT only, so "hard" means more opponents of
//  identical ability. Here there is a genuine, well-understood skill gradient, and EVERY LEVEL OF
//  IT IS A DIFFERENT ALGORITHM rather than the same algorithm with a knob.
//
//  IT CANNOT SEE YOUR SHIPS. Every level computes from public information only — the same shots,
//  results and sunk lists a human player has. The fleet is never consulted. That is not a
//  courtesy, it is the one property that makes the board worth reasoning about: the belief that
//  the board is fixed and you are finding it.
//
//  IT NEVER RE-ROLLS ITS FLEET. The temptation with a hidden-state bot is to leave the fleet
//  undetermined and materialise ships away from incoming fire. That is cheating, it is
//  undetectable, and it would poison the only thing this game has.
//
//  Mirrors Android `SeaBattleBot.kt`.
//

import Foundation

struct SeaBattleBot {
    /// 0...1, matching the continuous-slider convention the other bots use.
    let skill: Double

    // MARK: - Targeting

    /// The next square to fire at, given only what a player could see.
    ///
    /// `shots`/`results` are the bot's own history against the human; `sunkCells` are outlines
    /// the human's fleet has already revealed. Nothing here reads the human's ships.
    func chooseShot(shots: [Int], results: [Int], sunkCells: [Int], fleetSpec: [Int]) -> Int {
        let fired = Set(shots)
        let available = (0..<SeaBattle.cells).filter { !fired.contains($0) }
        guard !available.isEmpty else { return 0 }

        // Between bands the higher algorithm plays with probability `skill` and the lower
        // otherwise — the same construction RpsBot.chooseThrow uses. It makes the scale
        // continuous instead of four steps, and makes a mid-skill bot feel INCONSISTENT rather
        // than uniformly mediocre, which is much closer to how a human plays.
        let roll = Double.random(in: 0...1)

        // Live hits: hit cells that are not part of an already-sunk ship. These are the trail
        // that hunting follows, and excluding sunk outlines is what stops the bot re-probing
        // around a ship it has already finished.
        let sunk = Set(sunkCells)
        var liveHits: [Int] = []
        for (i, cell) in shots.enumerated() where i < results.count {
            if results[i] > 0 && !sunk.contains(cell) { liveHits.append(cell) }
        }

        switch skill {
        case ..<0.25:
            // Uniform random over unfired cells. No hunt at all — a hit is not followed up.
            // ~95 shots to win, which is what random shooting costs.
            return available.randomElement()!

        case ..<0.5:
            // Random search, then HUNT: on a hit, queue the four orthogonal neighbours. ~65.
            if roll < skill, let target = hunt(liveHits, fired: fired) { return target }
            return available.randomElement()!

        case ..<0.75:
            // PARITY search + hunt + LINE-LOCK. ~52.
            if roll < skill {
                if let target = lineLock(liveHits, fired: fired) { return target }
                if let target = hunt(liveHits, fired: fired) { return target }
                if let target = parity(available) { return target }
            }
            if let target = hunt(liveHits, fired: fired) { return target }
            return available.randomElement()!

        default:
            // PROBABILITY DENSITY. For every remaining ship, count every legal placement
            // consistent with all known hits, misses and sinks; fire at the cell appearing in
            // the most placements. ~42, close to the practical optimum for a solver that sees
            // only hits and misses.
            if roll < skill {
                if let target = lineLock(liveHits, fired: fired) { return target }
                if let target = density(
                    fired: fired, shots: shots, results: results,
                    sunkCells: sunk, fleetSpec: fleetSpec, liveHits: liveHits) { return target }
            }
            if let target = hunt(liveHits, fired: fired) { return target }
            return available.randomElement()!
        }
    }

    /// The four orthogonal neighbours of any live hit.
    private func hunt(_ liveHits: [Int], fired: Set<Int>) -> Int? {
        var candidates: [Int] = []
        for hit in liveHits {
            for n in neighbours(hit) where !fired.contains(n) { candidates.append(n) }
        }
        return candidates.randomElement()
    }

    /// After two collinear hits, extend along that line and stop probing perpendicular.
    ///
    /// This is the single biggest jump in a Battleship solver's efficiency: without it, a bot
    /// that has found a 4-long ship still wastes shots checking above and below every hit.
    private func lineLock(_ liveHits: [Int], fired: Set<Int>) -> Int? {
        guard liveHits.count >= 2 else { return nil }
        let hits = Set(liveHits)

        for hit in liveHits {
            // Horizontal pair?
            if hits.contains(hit + 1) && SeaBattle.cy(hit) == SeaBattle.cy(hit + 1) {
                if let t = extend(hits: hits, fired: fired, from: hit, step: 1) { return t }
            }
            // Vertical pair?
            if hits.contains(hit + SeaBattle.size) {
                if let t = extend(hits: hits, fired: fired, from: hit, step: SeaBattle.size) { return t }
            }
        }
        return nil
    }

    /// Walk both ends of a contiguous run of hits and return the first unfired cell.
    private func extend(hits: Set<Int>, fired: Set<Int>, from: Int, step: Int) -> Int? {
        let horizontal = step == 1

        var low = from
        while hits.contains(low - step), sameLine(low, low - step, horizontal) { low -= step }
        var high = from
        while hits.contains(high + step), sameLine(high, high + step, horizontal) { high += step }

        for candidate in [low - step, high + step] {
            guard candidate >= 0, candidate < SeaBattle.cells else { continue }
            guard sameLine(candidate == low - step ? low : high, candidate, horizontal) else { continue }
            if !fired.contains(candidate) { return candidate }
        }
        return nil
    }

    /// Row wrap check: cells 9 and 10 are consecutive integers on DIFFERENT rows.
    private func sameLine(_ a: Int, _ b: Int, _ horizontal: Bool) -> Bool {
        horizontal ? SeaBattle.cy(a) == SeaBattle.cy(b) : SeaBattle.cx(a) == SeaBattle.cx(b)
    }

    /// Only cells where `(x + y) % 2 == 0`.
    ///
    /// The smallest ship is 2 long, so it cannot hide entirely inside one parity class — which
    /// means half the board can be skipped during the search phase for free.
    private func parity(_ available: [Int]) -> Int? {
        let even = available.filter { (SeaBattle.cx($0) + SeaBattle.cy($0)) % 2 == 0 }
        return even.randomElement() ?? available.randomElement()
    }

    /// Count every legal placement of every remaining ship, consistent with what is known.
    private func density(
        fired: Set<Int>, shots: [Int], results: [Int],
        sunkCells: Set<Int>, fleetSpec: [Int], liveHits: [Int]
    ) -> Int? {
        // Which cells are known EMPTY: fired and missed.
        var misses = Set<Int>()
        for (i, cell) in shots.enumerated() where i < results.count {
            if results[i] == 0 { misses.insert(cell) }
        }

        // Which ships are still afloat. Derived from what has been sunk, which is public.
        var remaining = fleetSpec
        // Each sunk ship accounts for `length` cells of sunkCells; approximate by removing the
        // longest ships that fit the revealed outlines. Exact bookkeeping is not needed here —
        // an over-estimate of remaining fleet only makes the heatmap slightly less sharp.
        var sunkBudget = sunkCells.count
        remaining.sort(by: >)
        var afloat: [Int] = []
        for length in remaining {
            if sunkBudget >= length { sunkBudget -= length } else { afloat.append(length) }
        }
        if afloat.isEmpty { afloat = [2] }

        var heat = [Int](repeating: 0, count: SeaBattle.cells)
        let hits = Set(liveHits)

        for length in afloat {
            for y in 0..<SeaBattle.size {
                for x in 0..<SeaBattle.size {
                    for horizontal in [true, false] {
                        if horizontal && x + length > SeaBattle.size { continue }
                        if !horizontal && y + length > SeaBattle.size { continue }
                        let cells = (0..<length).map {
                            horizontal ? SeaBattle.packed(x + $0, y) : SeaBattle.packed(x, y + $0)
                        }
                        // A placement is impossible if it covers a known miss or a sunk cell.
                        if cells.contains(where: { misses.contains($0) || sunkCells.contains($0) }) {
                            continue
                        }
                        // A placement that covers a live hit is much more likely — weight it, so
                        // the solver finishes wounded ships rather than opening new fronts.
                        let overlapsHit = cells.contains(where: { hits.contains($0) })
                        let weight = overlapsHit ? 12 : 1
                        for c in cells where !fired.contains(c) { heat[c] += weight }
                    }
                }
            }
        }

        let best = heat.indices
            .filter { !fired.contains($0) && heat[$0] > 0 }
            .max(by: { heat[$0] < heat[$1] })
        return best
    }

    private func neighbours(_ cell: Int) -> [Int] {
        let x = SeaBattle.cx(cell), y = SeaBattle.cy(cell)
        var out: [Int] = []
        if x > 0 { out.append(SeaBattle.packed(x - 1, y)) }
        if x < SeaBattle.size - 1 { out.append(SeaBattle.packed(x + 1, y)) }
        if y > 0 { out.append(SeaBattle.packed(x, y - 1)) }
        if y < SeaBattle.size - 1 { out.append(SeaBattle.packed(x, y + 1)) }
        return out
    }

    // MARK: - Its own placement

    /// AXIS 2 OF DIFFICULTY (§11.1), and it matters more than it sounds: half of losing to a good
    /// Battleship player is that their fleet was hard to find.
    ///
    /// Weak bots place uniformly at random, which clusters and hugs edges. Strong bots reject
    /// placements that are statistically easy to find — nothing wholly on an edge row, and a bias
    /// away from the centre 4x4, which is where the density solver and most humans look first.
    func placeFleet() -> [SeaBattleShip] {
        guard skill >= 0.5 else { return SeaBattleRules.randomFleet() }

        // Sample several fleets and keep the one that looks hardest to find. Cheap — this runs
        // once per match, not per turn.
        var best = SeaBattleRules.randomFleet()
        var bestScore = -Double.infinity
        for _ in 0..<24 {
            let candidate = SeaBattleRules.randomFleet()
            let score = awkwardness(candidate)
            if score > bestScore { bestScore = score; best = candidate }
        }
        return best
    }

    /// Higher is harder to find.
    private func awkwardness(_ fleet: [SeaBattleShip]) -> Double {
        var score = 0.0
        var edgeShips = 0
        for ship in fleet {
            let allEdge = ship.cells.allSatisfy { c in
                let x = SeaBattle.cx(c), y = SeaBattle.cy(c)
                return x == 0 || y == 0 || x == SeaBattle.size - 1 || y == SeaBattle.size - 1
            }
            if allEdge { edgeShips += 1 }
            // Distance from the centre 4x4, where everyone looks first.
            for c in ship.cells {
                let dx = abs(Double(SeaBattle.cx(c)) - 4.5)
                let dy = abs(Double(SeaBattle.cy(c)) - 4.5)
                score += min(dx, dy) * 0.15
            }
        }
        // A ship entirely on an edge is the single most-guessed layout, so it is penalised
        // rather than rewarded despite being "away from centre".
        score -= Double(edgeShips) * 2.0
        return score
    }

    // MARK: - Presentation

    /// 600–1400 ms, randomised.
    ///
    /// PRESENTATION, NOT FAIRNESS, and it is stated here so nobody later "optimises" it away: an
    /// instant answer reads as a lookup table and destroys the fiction that someone is thinking.
    static func thinkingDelay() -> Double {
        Double.random(in: 0.6...1.4)
    }
}
