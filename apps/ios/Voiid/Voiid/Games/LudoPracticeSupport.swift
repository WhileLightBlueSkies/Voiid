//
//  LudoPracticeSupport.swift
//  Voiid
//
//  The LEGACY v1 wire struct, kept ONLY for the offline practice screens (`LudoBotMatch`,
//  `LudoBotView`), which simulate opponents locally and render through the old board canvas.
//  The ONLINE match now speaks schema v2 — see Games/Ludo/LudoModels.swift. Nothing in this
//  file touches networking.
//

import Foundation

/// LEGACY (v1) authoritative Ludo state shape used by the offline practice screens only.
///
/// NOTE WHAT IS ABSENT, AND WHY IT IS THE OPPOSITE OF SEA BATTLE: there is no per-player
/// projection and no hidden field, because Ludo has no hidden player information — every token,
/// roll and capture is public to every seat. The instinct after Sea Battle is that more seats
/// implies per-seat views, and here that would be wrong.
///
/// The only hidden thing is the FUTURE, and it is protected server-side: the RNG seed rides the
/// secret channel and never reaches a client, because mulberry32's state IS its seed and a
/// client holding it could compute every future roll. That is why there is no `seed` here to
/// parse — not an omission, a design property.
struct LudoState {
    /// What just happened, for the animation. Explicit rather than diffed, because a client that
    /// just cold-started has no previous state to diff against.
    struct LastMove {
        let seat: Int
        let token: Int
        let from: Int
        let to: Int
        /// [seat, token] of a token sent home, or nil.
        let captured: [Int]?
    }

    let players: [String]
    let tokensPerPlayer: Int
    /// [seat][token] -> position encoding (see `Ludo` in LudoBoard.swift).
    let tokens: [[Int]]
    let turn: Int
    let turnUserId: String?
    /// "awaitingRoll" | "awaitingMove" | "done".
    let phase: String
    /// The rolled face, once rolled. Nil before the roll and after the turn passes.
    let die: Int?
    /// Token indices legally movable with `die`, as computed by the SERVER.
    ///
    /// The client highlights exactly this set and never re-derives it. Deriving legality here
    /// would put a second copy of the block/exact-entry rules on the phone, and LUDO.md §4.2 is
    /// explicit that one function answers "what can this player do" for all four consumers.
    let legal: [Int]
    let sixStreak: Int
    let extraTurn: Bool
    /// Seats in finishing order.
    let finishedOrder: [Int]
    let deadlineAt: Double?
    let lastMove: LastMove?
    let finished: Bool
    let winnerUserId: String?

    static func parse(_ payload: [String: Any]) -> LudoState? {
        guard let players = payload["players"] as? [String],
              let tokens = payload["tokens"] as? [[Int]] else { return nil }
        var last: LastMove?
        if let m = payload["lastMove"] as? [String: Any],
           let seat = m["seat"] as? Int, let token = m["token"] as? Int,
           let from = m["from"] as? Int, let to = m["to"] as? Int {
            last = LastMove(seat: seat, token: token, from: from, to: to,
                            captured: m["captured"] as? [Int])
        }
        return LudoState(
            players: players,
            tokensPerPlayer: (payload["tokensPerPlayer"] as? Int) ?? tokens.first?.count ?? 4,
            tokens: tokens,
            turn: (payload["turn"] as? Int) ?? 0,
            turnUserId: payload["turnUserId"] as? String,
            phase: (payload["phase"] as? String) ?? "awaitingRoll",
            die: payload["die"] as? Int,
            legal: (payload["legal"] as? [Int]) ?? [],
            sixStreak: (payload["sixStreak"] as? Int) ?? 0,
            extraTurn: (payload["extraTurn"] as? Bool) ?? false,
            finishedOrder: (payload["finishedOrder"] as? [Int]) ?? [],
            deadlineAt: payload["deadlineAt"] as? Double,
            lastMove: last,
            finished: (payload["finished"] as? Bool) ?? false,
            winnerUserId: payload["winnerUserId"] as? String)
    }
}

