//
//  TicTacToeBot.swift
//  Voiid
//
//  Local, offline bot for Tic Tac Toe (docs/GAMES.md §1 calls this out as a deliberate,
//  separate addition to the online-only design).
//
//  WHY THIS IS ENTIRELY CLIENT-SIDE. The online game is server-authoritative because two
//  humans can cheat each other. A bot match has exactly one human and no opponent to
//  protect — cheating yourself is not a threat model. So a bot game creates no match row,
//  no Redis state, no WS traffic and no server load, and it works with no connection at
//  all. It reuses only the rules and the renderer.
//
//  DIFFICULTY IS ONE NUMBER, NOT FOUR MODES. `skill` (0...1) is the single source of truth:
//  it is the probability that the bot plays the BEST move rather than a random legal one.
//  The three named presets are just positions on that scale, so the slider and the mode
//  chips can never disagree — a design where "Hard" and a 20% slider could both be active
//  would have to pick a winner, and whichever it picked would look like a bug.
//
//  At skill = 1 the bot is a full minimax player and is UNBEATABLE — perfect Tic Tac Toe
//  play draws at best. That is deliberate for the top of the slider, and it is also why
//  the "Hard" preset sits below 1.0: a game you cannot ever win stops being fun, so the
//  named mode leaves a real (if small) chance to win, and the slider is there for anyone
//  who explicitly wants the wall.
//

import Foundation

enum BotDifficulty: String, CaseIterable, Identifiable {
    case easy, moderate, hard
    var id: String { rawValue }

    var label: String {
        switch self {
        case .easy:     return "Easy"
        case .moderate: return "Moderate"
        case .hard:     return "Hard"
        }
    }

    /// Where each preset sits on the 0...1 skill scale.
    ///
    /// Easy is 0.15 rather than 0: a bot that plays entirely at random misses wins that are
    /// already on the board and reads as broken rather than easy.
    /// Hard is 0.92, not 1.0 — see the note above on why the top of the scale is reserved
    /// for the slider.
    var skill: Double {
        switch self {
        case .easy:     return 0.15
        case .moderate: return 0.55
        case .hard:     return 0.92
        }
    }

    /// The preset a raw skill value corresponds to, or nil if the slider sits between them.
    static func matching(_ skill: Double) -> BotDifficulty? {
        allCases.first { abs($0.skill - skill) < 0.001 }
    }
}

enum TicTacToeBot {

    /// Choose a cell for `botSeat` on `board`.
    ///
    /// `skill` is the probability of playing optimally; otherwise a random legal move. That
    /// mix is what makes the difficulty feel continuous — a bot that is "70% good" blunders
    /// roughly three moves in ten, which is a far more natural opponent than one that
    /// searches to a fixed shallower depth (that produces a bot which is either perfect or
    /// obviously stupid, with little in between).
    static func chooseMove(board: [Int?], botSeat: Int, skill: Double) -> Int? {
        let empty = board.indices.filter { board[$0] == nil }
        guard !empty.isEmpty else { return nil }

        if Double.random(in: 0...1) > skill {
            return empty.randomElement()
        }
        return bestMove(board: board, seat: botSeat) ?? empty.randomElement()
    }

    /// Full minimax over the 9-cell board. The search space is trivially small (at most 9!
    /// leaf orderings, and far fewer in practice), so there is no need for alpha-beta or a
    /// depth cap — exhaustive search runs instantly and keeps this readable.
    ///
    /// Depth is folded into the score so the bot prefers a FASTER win and a SLOWER loss.
    /// Without it, the bot sees all wins as equal and will idly postpone a mate it could
    /// take immediately, which looks like it isn't trying.
    private static func bestMove(board: [Int?], seat: Int) -> Int? {
        var best: (score: Int, cell: Int)?
        for cell in board.indices where board[cell] == nil {
            var next = board
            next[cell] = seat
            let score = minimax(board: next, seat: seat, turn: 1 - seat, depth: 1)
            if best == nil || score > best!.score {
                best = (score, cell)
            }
        }
        return best?.cell
    }

    private static func minimax(board: [Int?], seat: Int, turn: Int, depth: Int) -> Int {
        if let w = winner(board) {
            return w == seat ? (10 - depth) : (depth - 10)
        }
        if !board.contains(where: { $0 == nil }) { return 0 }   // draw

        var best = turn == seat ? Int.min : Int.max
        for cell in board.indices where board[cell] == nil {
            var next = board
            next[cell] = turn
            let score = minimax(board: next, seat: seat, turn: 1 - turn, depth: depth + 1)
            best = turn == seat ? max(best, score) : min(best, score)
        }
        return best
    }

    /// The seat owning a completed line, or nil.
    ///
    /// This duplicates the server's line table by necessity — a bot match never reaches the
    /// server, so there is nothing to ask. The ONLINE game still asks the server for
    /// everything; this is not a second referee for real matches.
    static func winner(_ board: [Int?]) -> Int? {
        for line in lines {
            if let a = board[line[0]], a == board[line[1]], a == board[line[2]] { return a }
        }
        return nil
    }

    static let lines = [
        [0, 1, 2], [3, 4, 5], [6, 7, 8],
        [0, 3, 6], [1, 4, 7], [2, 5, 8],
        [0, 4, 8], [2, 4, 6],
    ]
}
