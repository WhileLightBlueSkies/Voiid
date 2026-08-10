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

/// Snake's personal bests, persisted locally.
///
/// Same reasoning as `BotScoreStore` above: a practice match never reaches the backend, so
/// there is nothing to attach a record to and posting one would be an unverifiable claim.
///
/// This exists because a bare final score gives a player no reason to tap again. "You got 84,
/// your best is 87" does — near-misses drive another attempt far more reliably than the raw
/// number, and a new best is worth calling out.
enum SnakeRecordStore {
    private static let bestKey = "voiid.snake.bestLength"
    private static let totalKey = "voiid.snake.totalLength"

    /// Longest snake ever reached.
    static var best: Int { UserDefaults.standard.integer(forKey: bestKey) }

    /// Cumulative length across every match — the basis for unlocks, because it rewards
    /// PLAYING rather than winning. Gating cosmetics on wins punishes exactly the players
    /// most likely to give up.
    static var totalLength: Int { UserDefaults.standard.integer(forKey: totalKey) }

    /// Record a finished match. Returns true when this beat the previous best.
    @discardableResult
    static func record(length: Int) -> Bool {
        let d = UserDefaults.standard
        d.set(d.integer(forKey: totalKey) + length, forKey: totalKey)
        guard length > d.integer(forKey: bestKey) else { return false }
        d.set(length, forKey: bestKey)
        return true
    }
}
