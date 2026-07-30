//
//  CricketBot.swift
//  Voiid
//
//  Local bot for Hand Cricket (docs/GAMES_HAND_CRICKET.md).
//
//  THE STRATEGIC PROBLEM IS ASYMMETRIC, unlike RPS, and that is what makes this bot interesting.
//  The two roles want different things from the same pick:
//
//    * BOWLING, the bot wants to MATCH the batter's number (a match is a wicket).
//    * BATTING, the bot wants to AVOID the bowler's number, and among the safe numbers prefer the
//      big ones (6 scores six; a match on 6 costs the same wicket as a match on 1).
//
//  So difficulty is again exploitation of human non-randomness, applied to opposite goals
//  depending on who is batting.
//
//  The scale is honest about its ceiling:
//    skill 0.0 → uniform random over 0...6. A wicket is then a 1-in-7 coincidence.
//    skill 1.0 → bowls at your most likely number and bats away from it. Still cannot beat a truly
//                random human, because nothing can — with both sides uniform, every ball is a 1/7
//                wicket chance regardless of strategy.
//
//  Mirrors Android `CricketBot.kt`.
//

import Foundation

enum CricketBot {

    /// Legal picks, inclusive. 0 is a closed fist — a dot ball, and out if matched.
    static let minPick = 0
    static let maxPick = 6
    private static let all = Array(minPick...maxPick)

    /// Choose a pick.
    ///
    /// `humanHistory` is the HUMAN's past picks in this role, most recent last. Kept per role by
    /// the caller: how someone bats says little about how they bowl, so mixing the two would blur
    /// the model into noise.
    ///
    /// `botIsBatting` flips the objective — match to take a wicket, or dodge to score.
    static func choosePick(humanHistory: [Int], skill: Double, botIsBatting: Bool) -> Int {
        // Nothing to exploit yet, or the dice said play it straight. A bot that "reads" you on
        // ball one would be inventing a pattern that cannot exist.
        if humanHistory.isEmpty || Double.random(in: 0...1) > skill {
            return botIsBatting ? weightedByRuns(all) : all.randomElement()!
        }

        let predicted = predict(humanHistory)
        if botIsBatting {
            // Avoid the predicted bowl; among what's left, favour the big scores.
            return weightedByRuns(all.filter { $0 != predicted })
        }
        // Bowl AT the predicted bat. This is the only pick that can take a wicket.
        return predicted
    }

    /// The human's most likely next pick, by frequency weighted toward recent balls: the last 5
    /// count double, because people drift within an innings and a pick from twenty balls ago says
    /// little about the next one. (Same model as `RpsBot`, same reason.)
    private static func predict(_ history: [Int]) -> Int {
        var weights = [Int](repeating: 0, count: maxPick + 1)
        for (i, p) in history.enumerated() where p >= minPick && p <= maxPick {
            weights[p] += (i >= history.count - 5) ? 2 : 1
        }
        let best = weights.enumerated().max { $0.element < $1.element }?.offset
        return best ?? all.randomElement()!
    }

    /// Pick from `candidates` with weight proportional to run value, so 6 is likeliest and 0 is a
    /// rare defensive choice. `+1` keeps 0 reachable rather than impossible.
    private static func weightedByRuns(_ candidates: [Int]) -> Int {
        guard !candidates.isEmpty else { return all.randomElement()! }
        let total = candidates.reduce(0) { $0 + $1 + 1 }
        var roll = Int.random(in: 0..<total)
        for c in candidates {
            roll -= (c + 1)
            if roll < 0 { return c }
        }
        return candidates.last!
    }

    /// True if these two picks are a wicket. The one place the rule lives.
    static func isWicket(batterPick: Int, bowlerPick: Int) -> Bool { batterPick == bowlerPick }

    /// Which wicket animation this ball earns (docs/GAMES_HAND_CRICKET.md §5). Chosen by the
    /// MATCHED NUMBER, so it is deterministic from the ball itself and needs no extra state.
    static func wicketIsCatch(matchedPick: Int) -> Bool { matchedPick <= 2 }
}
