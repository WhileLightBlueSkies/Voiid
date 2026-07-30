//
//  BotScoreStore.swift
//  Voiid
//
//  Local, persisted record of practice results — docs/GAMES.md §1 (bot play is
//  deliberately client-only).
//
//  WHY USERDEFAULTS AND NOT THE SERVER. A bot match never reaches the backend: there is no
//  match row to attach a result to, and posting one would let a client inflate its own
//  record for free — exactly the unverifiable claim the online game is server-authoritative
//  to prevent. So practice results stay on the device and are never mixed into the friends
//  leaderboard, which counts only refereed matches.
//
//  Kept per difficulty because "12 wins" means nothing without knowing whether they came
//  against the easy bot or the near-perfect one.
//
//  Mirrors Android `BotGameState.kt`.
//

import Foundation

struct BotRecord {
    let wins: Int
    let draws: Int
    let losses: Int
    var played: Int { wins + draws + losses }
}

enum BotScoreStore {
    private static let defaults = UserDefaults.standard
    private static func key(_ level: BotDifficulty, _ suffix: String) -> String {
        "voiid.bot.\(level.rawValue).\(suffix)"
    }

    static func record(_ level: BotDifficulty) -> BotRecord {
        BotRecord(
            wins: defaults.integer(forKey: key(level, "w")),
            draws: defaults.integer(forKey: key(level, "d")),
            losses: defaults.integer(forKey: key(level, "l")))
    }

    /// `outcome` is +1 human win, 0 draw, -1 bot win.
    static func add(_ level: BotDifficulty, outcome: Int) {
        let suffix = outcome > 0 ? "w" : (outcome < 0 ? "l" : "d")
        let k = key(level, suffix)
        defaults.set(defaults.integer(forKey: k) + 1, forKey: k)
    }
}
