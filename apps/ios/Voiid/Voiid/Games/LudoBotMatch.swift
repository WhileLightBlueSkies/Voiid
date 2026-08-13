//
//  LudoBotMatch.swift
//  Voiid
//
//  The local match state machine for a Ludo practice game — the offline counterpart to
//  GamesEngine's server-fed state.
//
//  IT PRODUCES THE SAME SHAPE THE RENDERER CONSUMES. `LudoBoardView` draws from a `LudoState`,
//  so this builds one: the board, the die and the strips are the same code in practice and
//  online, and a fix to one is a fix to both.
//
//  THIS IS THE ONE PLACE THE LUDO RULES ARE DUPLICATED, and it is worth being blunt about that.
//  The engine in `backend/games/src/engine/ludo/` is the authority for every online match; this
//  is a second implementation so practice can run with no server. They must agree, so the rules
//  here are written against that file line for line — the same entry-on-six, the same exact-roll
//  home, the same block semantics, the same three-sixes forfeit, the same composing extra turns.
//  `LudoBotMatchTests` asserts the movement maths against the same cases the engine's own suite
//  uses; where the two ever disagree, the SERVER is right and this file is the bug.
//
//  Mirrors Android `LudoBotMatch.kt`.
//

import Foundation
import Combine

@MainActor
final class LudoBotMatch: ObservableObject {
    static let humanSeat = 0

    @Published private(set) var state: LudoState
    /// True while a bot seat is "thinking" — the die is locked so a fast tapper cannot roll for it.
    @Published private(set) var botThinking = false
    @Published var paused = false

    private(set) var level: BotDifficulty
    private(set) var skill: Double
    private var bot: LudoBot
    private var recorded = false

    /// Seats after the human are bots. Four seats is the doc's default shape for a group game.
    private let seatCount: Int
    private let tokensPerPlayer: Int

    init(level: BotDifficulty = .moderate, skill: Double? = nil, seats: Int = 4, tokens: Int = 2) {
        self.level = level
        self.skill = skill ?? level.skill
        self.bot = LudoBot(skill: skill ?? level.skill)
        self.seatCount = max(2, min(Ludo.maxSeats, seats))
        // 2 tokens at 3-4 players, 4 at two — the same default the engine clamps to, and the
        // reason is the same: no default configuration should run past ~20 minutes.
        self.tokensPerPlayer = tokens
        self.state = Self.freshState(seats: self.seatCount, tokens: tokens)
    }

    func configure(level: BotDifficulty, skill: Double) {
        self.level = level
        self.skill = skill
        self.bot = LudoBot(skill: skill)
    }

    private static func freshState(seats: Int, tokens: Int) -> LudoState {
        LudoState(
            players: (0..<seats).map { $0 == humanSeat ? "you" : "bot\($0)" },
            tokensPerPlayer: tokens,
            tokens: (0..<seats).map { _ in [Int](repeating: Ludo.yard, count: tokens) },
            turn: 0,
            turnUserId: "you",
            phase: "awaitingRoll",
            die: nil,
            legal: [],
            sixStreak: 0,
            extraTurn: false,
            finishedOrder: [],
            deadlineAt: nil,
            lastMove: nil,
            finished: false,
            winnerUserId: nil)
    }

    var canRoll: Bool {
        !state.finished && !botThinking && !paused
            && state.phase == "awaitingRoll" && state.turn == Self.humanSeat
    }

    var canMove: Bool {
        !state.finished && !botThinking && !paused
            && state.phase == "awaitingMove" && state.turn == Self.humanSeat
    }

    func restart() {
        botThinking = false
        paused = false
        recorded = false
        state = Self.freshState(seats: seatCount, tokens: tokensPerPlayer)
    }

    // MARK: - The human's turn

    func roll() {
        guard canRoll else { return }
        performRoll()
        // Zero legal moves auto-passes inside performRoll, which may hand the turn to a bot.
        driveBotsIfNeeded()
    }

    func move(token: Int) {
        guard canMove, state.legal.contains(token) else { return }
        performMove(token: token)
        driveBotsIfNeeded()
    }

    // MARK: - Bot seats

    /// Run bot turns until it is the human's turn again, or the match ends.
    private func driveBotsIfNeeded() {
        guard !state.finished, state.turn != Self.humanSeat else { return }
        botThinking = true
        Task { @MainActor in
            while !self.state.finished, self.state.turn != Self.humanSeat, !self.paused {
                try? await Task.sleep(
                    nanoseconds: UInt64(LudoBot.thinkingDelay() * 1_000_000_000))
                guard !self.paused, !self.state.finished else { break }

                if self.state.phase == "awaitingRoll" {
                    self.performRoll()
                } else if self.state.phase == "awaitingMove" {
                    let seat = self.state.turn
                    let pick = self.bot.chooseMove(
                        legal: self.state.legal, tokens: self.state.tokens,
                        seat: seat, die: self.state.die ?? 0)
                    self.performMove(token: pick)
                } else {
                    break
                }
            }
            self.botThinking = false
        }
    }

    // MARK: - Rules
    //
    // Written against backend/games/src/engine/ludo/. Every rule below has a counterpart there.

    private func performRoll() {
        let seat = state.turn
        // A UNIFORM DRAW, AT EVERY DIFFICULTY. The bot's skill never touches this line — see
        // LudoBot's header for why that is the most important property in the file.
        let die = Int.random(in: 1...6)
        var sixStreak = state.sixStreak
        var s = state

        if die == 6 {
            sixStreak += 1
            // Three consecutive sixes forfeits the turn AND the third six is not used.
            if sixStreak >= 3 {
                s = withState(s, die: nil, legal: [], sixStreak: 0)
                state = passTurn(s)
                return
            }
        } else {
            sixStreak = 0
        }

        let legal = legalMoves(seat: seat, die: die, tokens: s.tokens)

        if legal.isEmpty {
            // Zero legal moves passes automatically, in the same beat as the roll — a "you have
            // no moves, tap to continue" prompt is a tap that changes nothing.
            s = withState(s, die: die, legal: [], sixStreak: sixStreak)
            state = passTurn(s)
            return
        }

        state = LudoState(
            players: s.players, tokensPerPlayer: s.tokensPerPlayer, tokens: s.tokens,
            turn: seat, turnUserId: s.players[seat], phase: "awaitingMove",
            die: die, legal: legal, sixStreak: sixStreak, extraTurn: s.extraTurn,
            finishedOrder: s.finishedOrder, deadlineAt: nil, lastMove: s.lastMove,
            finished: false, winnerUserId: nil)
    }

    private func performMove(token: Int) {
        let seat = state.turn
        guard let die = state.die else { return }
        var tokens = state.tokens
        let from = tokens[seat][token]
        guard let to = destination(from, die, seat) else { return }

        tokens[seat][token] = to

        // Capture: exactly one opponent token on a non-safe track square goes home. Two or more
        // is a block, which was already excluded from the legal set — so multi-capture is
        // impossible by construction rather than by a check.
        var captured: [Int]?
        if Ludo.onTrack(to) && !Ludo.isSafe(to) {
            for other in tokens.indices where other != seat {
                if let idx = tokens[other].firstIndex(of: to) {
                    tokens[other][idx] = Ludo.yard
                    captured = [other, idx]
                    break
                }
            }
        }

        let last = LudoState.LastMove(seat: seat, token: token, from: from, to: to, captured: captured)

        // A player finishes when all their tokens are home, and the MATCH ends on the first
        // finisher — not "play on for second place".
        if tokens[seat].allSatisfy({ $0 == Ludo.home }) {
            if !recorded {
                BotScoreStore.add(level, outcome: seat == Self.humanSeat ? 1 : -1)
                recorded = true
            }
            state = LudoState(
                players: state.players, tokensPerPlayer: state.tokensPerPlayer, tokens: tokens,
                turn: seat, turnUserId: nil, phase: "done", die: nil, legal: [],
                sixStreak: 0, extraTurn: false,
                finishedOrder: state.finishedOrder + [seat], deadlineAt: nil,
                lastMove: last, finished: true, winnerUserId: state.players[seat])
            return
        }

        // EXTRA TURNS COMPOSE TO ONE, NOT TWO: the flag is boolean, not a counter, so capturing
        // with a six grants one extra turn rather than spiralling.
        let grantsExtra = die == 6 || captured != nil || to == Ludo.home

        let base = LudoState(
            players: state.players, tokensPerPlayer: state.tokensPerPlayer, tokens: tokens,
            turn: seat, turnUserId: state.players[seat], phase: "awaitingRoll",
            die: nil, legal: [], sixStreak: grantsExtra ? state.sixStreak : 0,
            extraTurn: grantsExtra, finishedOrder: state.finishedOrder, deadlineAt: nil,
            lastMove: last, finished: false, winnerUserId: nil)

        state = grantsExtra ? base : passTurn(base)
    }

    /// Hand the turn to the next seat that has not already finished.
    private func passTurn(_ s: LudoState) -> LudoState {
        let n = s.players.count
        var next = s.turn
        for i in 1...n {
            let candidate = (s.turn + i) % n
            if !s.finishedOrder.contains(candidate) { next = candidate; break }
        }
        return LudoState(
            players: s.players, tokensPerPlayer: s.tokensPerPlayer, tokens: s.tokens,
            turn: next, turnUserId: s.players[next], phase: "awaitingRoll",
            die: nil, legal: [], sixStreak: 0, extraTurn: false,
            finishedOrder: s.finishedOrder, deadlineAt: nil, lastMove: s.lastMove,
            finished: false, winnerUserId: nil)
    }

    private func withState(
        _ s: LudoState, die: Int?, legal: [Int], sixStreak: Int
    ) -> LudoState {
        LudoState(
            players: s.players, tokensPerPlayer: s.tokensPerPlayer, tokens: s.tokens,
            turn: s.turn, turnUserId: s.turnUserId, phase: s.phase,
            die: die, legal: legal, sixStreak: sixStreak, extraTurn: s.extraTurn,
            finishedOrder: s.finishedOrder, deadlineAt: nil, lastMove: s.lastMove,
            finished: s.finished, winnerUserId: s.winnerUserId)
    }

    // MARK: - Movement, mirroring backend/games/src/engine/ludo/board.ts

    func legalMoves(seat: Int, die: Int, tokens: [[Int]]) -> [Int] {
        let blocked = blockedSquares(against: seat, tokens: tokens)
        var legal: [Int] = []

        for t in tokens[seat].indices {
            let from = tokens[seat][t]
            guard let to = destination(from, die, seat) else { continue }

            // An opponent's block can neither be landed on NOR passed, so the whole path is
            // checked rather than just the destination.
            if path(from, die, seat).contains(where: { blocked.contains($0) }) { continue }

            // A token may not land on a square holding two or more of its own colour.
            if Ludo.onTrack(to) {
                let own = tokens[seat].enumerated().filter { $0.offset != t && $0.element == to }.count
                if own >= 2 { continue }
            }

            legal.append(t)
        }
        return legal
    }

    /// Squares an opponent has blocked: two or more of one other colour.
    ///
    /// BLOCKS CANNOT FORM ON SAFE SQUARES. Tokens may stack there — they are already safe — but
    /// such a stack does not block passage, which is what stops a permanent block on an entry
    /// square locking a player out of the game entirely.
    private func blockedSquares(against seat: Int, tokens: [[Int]]) -> Set<Int> {
        var blocked = Set<Int>()
        for other in tokens.indices where other != seat {
            var counts: [Int: Int] = [:]
            for p in tokens[other] where Ludo.onTrack(p) && !Ludo.isSafe(p) {
                counts[p, default: 0] += 1
            }
            for (square, n) in counts where n >= 2 { blocked.insert(square) }
        }
        return blocked
    }

    func destination(_ pos: Int, _ die: Int, _ seat: Int) -> Int? {
        if Ludo.isHome(pos) { return nil }
        // A 6 is required to leave the yard, and it PLACES the token on the entry square — it
        // does not then move six more.
        if Ludo.inYard(pos) { return die == 6 ? Ludo.entrySquare(seat) : nil }
        if Ludo.inColumn(pos) {
            let step = pos - Ludo.columnBase + die
            if step == Ludo.column { return Ludo.home }
            // EXACT ROLL REQUIRED TO REACH HOME — overshooting is illegal, not clamped.
            if step > Ludo.column { return nil }
            return Ludo.columnBase + step
        }
        let travelled = (pos - Ludo.entrySquare(seat) + Ludo.track) % Ludo.track
        let next = travelled + die
        if next == Ludo.track + Ludo.column { return Ludo.home }
        if next > Ludo.track + Ludo.column { return nil }
        if next >= Ludo.track { return Ludo.columnBase + (next - Ludo.track) }
        return (Ludo.entrySquare(seat) + next) % Ludo.track
    }

    /// The squares a token passes through, for the block check.
    func path(_ pos: Int, _ die: Int, _ seat: Int) -> [Int] {
        if Ludo.inYard(pos) {
            return destination(pos, die, seat).map { [$0] } ?? []
        }
        var squares: [Int] = []
        for step in 1...max(die, 1) {
            guard let at = destination(pos, step, seat) else { return squares }
            squares.append(at)
        }
        return squares
    }
}
