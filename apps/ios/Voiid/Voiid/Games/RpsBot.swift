//
//  RpsBot.swift
//  Voiid
//
//  Local bot for Rock Paper Scissors.
//
//  THE HONEST PROBLEM: against a truly random opponent, RPS has no skill — every strategy
//  wins exactly a third of the time. A "hard" bot that just played randomly would be
//  indistinguishable from an easy one, and a difficulty slider over it would be a lie.
//
//  So difficulty here is EXPLOITATION OF HUMAN NON-RANDOMNESS, which is how the game is
//  actually played well. People repeat throws, avoid repeating three times, and switch
//  after losses. This bot tracks the player's throw frequencies and, at `skill`
//  probability, plays the counter to their MOST LIKELY next throw; otherwise it throws at
//  random.
//
//  That makes the scale meaningful and honest:
//    skill 0.0 → pure random, genuinely a coin flip
//    skill 1.0 → punishes any pattern in your play, but still cannot beat a truly random
//                human — which is correct, because nothing can. It is NOT "unbeatable" the
//                way the Tic Tac Toe bot is, and pretending otherwise would be dishonest.
//
//  Mirrors Android `RpsBot.kt`.
//

import Foundation

enum RpsBot {
    /// Index convention shared with the server: 0 rock, 1 paper, 2 scissors.
    static let rock = 0
    static let paper = 1
    static let scissors = 2

    static let names = ["rock", "paper", "scissors"]

    /// What beats `throwIdx`. Rock < Paper < Scissors < Rock.
    static func counter(_ throwIdx: Int) -> Int { (throwIdx + 1) % 3 }

    /// 1 if `a` beats `b`, -1 if it loses, 0 for a tie. The single place the rules live, so
    /// the screen never re-derives them.
    static func compare(_ a: Int, _ b: Int) -> Int {
        if a == b { return 0 }
        return counter(b) == a ? 1 : -1
    }

    /// Choose a throw. `history` is the HUMAN's past throws, most recent last.
    ///
    /// With no history there is nothing to exploit, so it falls through to random — a bot
    /// that "reads" you on move one would be inventing a pattern that cannot exist yet.
    static func chooseThrow(history: [Int], skill: Double) -> Int {
        if history.isEmpty || Double.random(in: 0...1) > skill {
            return Int.random(in: 0...2)
        }
        // Frequency model weighted toward recent throws: the last 5 count double, because
        // people drift and a throw from twenty rounds ago says little about the next one.
        var weights = [0, 0, 0]
        for (i, t) in history.enumerated() where (0...2).contains(t) {
            weights[t] += (i >= history.count - 5) ? 2 : 1
        }
        let predicted = weights.firstIndex(of: weights.max() ?? 0) ?? Int.random(in: 0...2)
        return counter(predicted)
    }

    /// Emoji for a throw; `nil` renders the closed fist used during the shake.
    static func emoji(_ throwIdx: Int?) -> String {
        switch throwIdx {
        case paper:    return "✋"
        case scissors: return "✌️"
        default:       return "✊"
        }
    }
}
