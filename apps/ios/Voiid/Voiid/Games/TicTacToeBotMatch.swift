//
//  TicTacToeBotMatch.swift
//  Voiid
//
//  The local match state machine for a bot game — the offline counterpart to GamesEngine's
//  server-fed state.
//
//  Deliberately produces the SAME shape the renderer consumes (board, finished, winner,
//  line) so one board component draws both a bot game and an online game. If this exposed
//  a different model, every view would grow a branch and the two would drift.
//
//  The human is always seat 0 (X) and moves first. Fixed rather than randomised because a
//  bot game is restartable at zero cost.
//
//  Mirrors Android `TicTacToeBotScreen.kt`'s state block.
//

import Foundation
import Combine

@MainActor
final class TicTacToeBotMatch: ObservableObject {
    static let humanSeat = 0
    static let botSeat = 1

    @Published private(set) var board: [Int?] = Array(repeating: nil, count: 9)
    @Published private(set) var finished = false
    @Published private(set) var winnerSeat: Int?
    @Published private(set) var line: [Int]?
    /// True while the bot is "thinking" — the board is locked so a fast tapper cannot get
    /// two moves in before the bot replies.
    @Published private(set) var botThinking = false
    @Published var paused = false

    /// Locked for the duration of a match: a result only means something if the difficulty
    /// could not be lowered mid-game.
    private(set) var skill: Double
    private(set) var level: BotDifficulty

    /// Guards against double-counting a result if the view re-renders after the game ends.
    private var recorded = false

    init(level: BotDifficulty = .moderate, skill: Double? = nil) {
        self.level = level
        self.skill = skill ?? level.skill
    }

    func configure(level: BotDifficulty, skill: Double) {
        self.level = level
        self.skill = skill
    }

    var canPlay: Bool { !finished && !botThinking && !paused }

    func restart() {
        board = Array(repeating: nil, count: 9)
        finished = false
        winnerSeat = nil
        line = nil
        botThinking = false
        paused = false
        recorded = false
    }

    /// Forfeit. A give-up that costs nothing is just a reset button with extra steps.
    func giveUp() {
        guard !finished else { return }
        if !recorded { BotScoreStore.add(level, outcome: -1); recorded = true }
        finished = true
        winnerSeat = Self.botSeat
    }

    func play(cell: Int) {
        guard canPlay, board.indices.contains(cell), board[cell] == nil else { return }
        board[cell] = Self.humanSeat
        if settleIfOver() { return }

        botThinking = true
        Task {
            // A visible pause before the bot answers — without it the opponent's mark
            // appears in the same frame as yours, which reads as a glitch. Randomised so
            // it doesn't feel metronomic.
            try? await Task.sleep(nanoseconds: UInt64.random(in: 320_000_000...620_000_000))
            guard !finished, !paused else { botThinking = false; return }
            if let move = TicTacToeBot.chooseMove(board: board, botSeat: Self.botSeat, skill: skill) {
                board[move] = Self.botSeat
                _ = settleIfOver()
            }
            botThinking = false
        }
    }

    @discardableResult
    private func settleIfOver() -> Bool {
        if let w = TicTacToeBot.winner(board) {
            finished = true
            winnerSeat = w
            line = TicTacToeBot.lines.first { l in
                board[l[0]] == w && board[l[1]] == w && board[l[2]] == w
            }
            if !recorded {
                BotScoreStore.add(level, outcome: w == Self.humanSeat ? 1 : -1)
                recorded = true
            }
            return true
        }
        if !board.contains(where: { $0 == nil }) {
            finished = true          // draw: finished, no winner
            winnerSeat = nil
            if !recorded { BotScoreStore.add(level, outcome: 0); recorded = true }
            return true
        }
        return false
    }
}
