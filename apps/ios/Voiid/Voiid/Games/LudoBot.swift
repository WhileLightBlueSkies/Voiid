//
//  LudoBot.swift
//  Voiid
//
//  The practice opponent (docs/games/future/LUDO.md §11).
//
//  DIFFICULTY NEVER TOUCHES THE DICE, AT ANY LEVEL, EVER. A bot that rolls better is not a
//  harder bot, it is a cheat — and in a game where players already suspect the dice it is the
//  single most damaging thing that could be built. Every band below varies MOVE SELECTION only;
//  the die comes from the same uniform draw the human gets.
//
//  THE HONEST PART, which matters more here than for any other bot in this app: Ludo is roughly
//  80% dice and 20% decisions. In a 4-player game the baseline win rate is 25% and a perfect
//  player against three random ones wins about 33-36%. That is the entire value of playing well
//  — eight to eleven percentage points.
//
//      The hardest Ludo bot will lose to a beginner about six times in ten. That is not a
//      weakness in the bot. It is the game.
//
//  So difficulty is presented as PLAYSTYLE, NOT STRENGTH (§11.2) — "Careless / Steady / Cautious
//  / Sharp" rather than Easy/Hard. Naming it by strength promises something the game cannot
//  deliver, and a player who loses to "Easy" will correctly conclude the labels are meaningless.
//
//  Mirrors Android `LudoBot.kt`.
//

import Foundation

struct LudoBot {
    /// 0...1, matching the continuous-slider convention every other bot here uses.
    let skill: Double

    /// Playstyle names for the four bands (§11.2).
    ///
    /// Deliberately NOT the shared BotDifficulty labels, which read Easy/Moderate/Hard. Those are
    /// honest for Tic Tac Toe, where skill decides the game; they would be a promise Ludo cannot
    /// keep.
    static func styleLabel(_ skill: Double) -> String {
        switch skill {
        case ..<0.25: return "Careless"
        case ..<0.5:  return "Steady"
        case ..<0.75: return "Cautious"
        default:      return "Sharp"
        }
    }

    /// Pick one of the server-legal token indices to move.
    ///
    /// `legal` is authoritative and comes from the engine — the bot chooses AMONG it and never
    /// re-derives it. That is the same rule the renderer follows, and it is what keeps one
    /// definition of "what can this player do" (§4.2).
    func chooseMove(
        legal: [Int],
        tokens: [[Int]],
        seat: Int,
        die: Int
    ) -> Int {
        guard let first = legal.first else { return 0 }
        guard legal.count > 1 else { return first }

        // Between bands, the higher policy plays with probability `skill` and the lower
        // otherwise — RpsBot's construction, which makes the scale continuous rather than four
        // steps and makes a mid bot INCONSISTENT rather than uniformly mediocre.
        let roll = Double.random(in: 0...1)

        switch skill {
        case ..<0.25:
            // Random legal move. No preference at all.
            return legal.randomElement()!

        case ..<0.5:
            // Greedy priority: capture > enter home > leave the yard > advance the furthest.
            if roll < skill { return greedy(legal, tokens, seat, die) }
            return legal.randomElement()!

        default:
            // Risk-aware: greedy, plus a threat model that penalises landing in front of an
            // opponent and rewards safe squares and blocks.
            //
            // The doc's top band is a depth-2 expectimax. It is deliberately not built: the
            // measured gap between risk-aware and perfect play in Ludo is a couple of percentage
            // points of win rate (§11.2), which is inside the noise of a single match, and a
            // search that cannot be felt is cost without a benefit. Recorded in §16 rather than
            // quietly skipped.
            if roll < skill { return riskAware(legal, tokens, seat, die) }
            return greedy(legal, tokens, seat, die)
        }
    }

    // MARK: - Policies

    private func greedy(_ legal: [Int], _ tokens: [[Int]], _ seat: Int, _ die: Int) -> Int {
        best(legal, tokens, seat, die) { to, from, _ in
            var score = 0.0
            if to == Ludo.home { score += 100 }
            if capturesAt(to, tokens, seat) { score += 80 }
            if from == Ludo.yard { score += 40 }        // getting a token out is nearly always right
            if Ludo.inColumn(to) { score += 10 }
            if Ludo.onTrack(to) { score += Double(relative(to, seat)) * 0.1 }
            return score
        }
    }

    private func riskAware(_ legal: [Int], _ tokens: [[Int]], _ seat: Int, _ die: Int) -> Int {
        best(legal, tokens, seat, die) { to, from, token in
            var score = 0.0
            if to == Ludo.home { score += 100 }
            if capturesAt(to, tokens, seat) { score += 80 }
            if from == Ludo.yard { score += 40 }
            if Ludo.inColumn(to) { score += 25 }         // a column is permanently safe
            if Ludo.isSafe(to) { score += 18 }
            if Ludo.onTrack(to) { score += Double(relative(to, seat)) * 0.1 }

            // THE THREAT MODEL. For each opponent token 1-6 squares behind this destination,
            // there is a 1/6 chance per token of being captured before our next turn. Safe
            // squares and the home column are immune.
            if Ludo.onTrack(to) && !Ludo.isSafe(to) {
                var exposure = 0.0
                for (other, row) in tokens.enumerated() where other != seat {
                    for p in row where Ludo.onTrack(p) {
                        let gap = (to - p + Ludo.track) % Ludo.track
                        if gap >= 1 && gap <= 6 { exposure += 1.0 / 6.0 }
                    }
                }
                score -= exposure * 45
            }

            // Forming a block: two of ours on one square, which nobody can land on or pass.
            // The only defensive action in the game, so it is worth real weight.
            let ownThere = tokens[seat].enumerated()
                .filter { $0.offset != token && $0.element == to }.count
            if ownThere >= 1 && Ludo.onTrack(to) && !Ludo.isSafe(to) { score += 22 }

            // Leaving a block that is currently holding an opponent back has a cost — but a
            // blocking player must still move if it is their only legal move, which the engine
            // enforces, so this is a preference rather than a veto.
            let ownAtSource = tokens[seat].enumerated()
                .filter { $0.offset != token && $0.element == from }.count
            if ownAtSource >= 1 && Ludo.onTrack(from) && !Ludo.isSafe(from) { score -= 12 }

            return score
        }
    }

    /// Score every legal move and take the best, with a small deliberate wobble at high skill.
    private func best(
        _ legal: [Int], _ tokens: [[Int]], _ seat: Int, _ die: Int,
        _ score: (_ to: Int, _ from: Int, _ token: Int) -> Double
    ) -> Int {
        var ranked: [(token: Int, value: Double)] = []
        for token in legal {
            guard tokens.indices.contains(seat), tokens[seat].indices.contains(token) else { continue }
            let from = tokens[seat][token]
            guard let to = destination(from, die, seat) else { continue }
            ranked.append((token, score(to, from, token)))
        }
        guard !ranked.isEmpty else { return legal.first ?? 0 }
        ranked.sort { $0.value > $1.value }

        // THE BOT OCCASIONALLY TAKES THE SECOND-BEST MOVE at high skill — 8% of the time, when
        // the gap is small (§11.3). Perfect consistency is the tell that you are playing a
        // machine, and Ludo's decisions are close enough that a small deviation costs nearly
        // nothing.
        if skill >= 0.75, ranked.count > 1, Double.random(in: 0...1) < 0.08,
           abs(ranked[0].value - ranked[1].value) < 20 {
            return ranked[1].token
        }
        return ranked[0].token
    }

    // MARK: - Board maths, mirroring the server

    private func capturesAt(_ to: Int, _ tokens: [[Int]], _ seat: Int) -> Bool {
        guard Ludo.onTrack(to), !Ludo.isSafe(to) else { return false }
        for (other, row) in tokens.enumerated() where other != seat {
            // Exactly one opponent token is a capture; two or more is a block and is not legal
            // to land on, so it is not a capture either.
            if row.filter({ $0 == to }).count == 1 { return true }
        }
        return false
    }

    private func relative(_ absolute: Int, _ seat: Int) -> Int {
        (absolute - Ludo.entrySquare(seat) + Ludo.track) % Ludo.track
    }

    /// The same movement rule as `backend/games/src/engine/ludo/board.ts`.
    ///
    /// A MIRROR, NOT AN AUTHORITY: the bot only ever chooses among the server's own `legal` set,
    /// so this is used to compare destinations, never to decide legality.
    private func destination(_ pos: Int, _ die: Int, _ seat: Int) -> Int? {
        if Ludo.isHome(pos) { return nil }
        if Ludo.inYard(pos) { return die == 6 ? Ludo.entrySquare(seat) : nil }
        if Ludo.inColumn(pos) {
            let step = pos - Ludo.columnBase + die
            if step == Ludo.column { return Ludo.home }
            if step > Ludo.column { return nil }
            return Ludo.columnBase + step
        }
        let travelled = relative(pos, seat)
        let next = travelled + die
        if next == Ludo.track + Ludo.column { return Ludo.home }
        if next > Ludo.track + Ludo.column { return nil }
        if next >= Ludo.track { return Ludo.columnBase + (next - Ludo.track) }
        return (Ludo.entrySquare(seat) + next) % Ludo.track
    }

    /// 700–1600 ms, randomised, plus the roll animation.
    ///
    /// PRESENTATION, NOT FAIRNESS. An instant move reads as a lookup table.
    static func thinkingDelay() -> Double {
        Double.random(in: 0.7...1.6)
    }
}
