//
//  MatchEndResult.swift
//  Voiid
//
//  What a finished match says about itself (docs/games/VISUALS_AUDIO_AND_PARITY.md §9.3).
//
//  ONE DESCRIPTOR, SIX GAMES. Every game builds one of these and hands it to MatchEndOverlay;
//  no game writes its own end screen. Six separate end screens is how six games that share a
//  tab end up feeling like six apps — the same argument `catch_shared` makes for sound.
//
//  WHAT A GAME OWNS: the words and the numbers. WHAT THE OVERLAY OWNS: the scrim, the motion,
//  the particles, the sound, the haptics, the buttons and the share sheet. A game that starts
//  reaching into presentation is the beginning of the drift this file exists to prevent.
//
//  Mirrors Android `MatchEndResult.kt`.
//

import SwiftUI

struct MatchEndResult: Equatable {
    /// The three outcomes differ in DIRECTION, not merely in colour (§9.5) — a win rises, a
    /// defeat settles, a tie converges. That is what makes the result readable across a room.
    enum Outcome: Equatable {
        case win, lose, tie

        /// The word. Carries the outcome on its own, so the screen survives greyscale.
        var verdict: String {
            switch self {
            case .win:  return "You win"
            case .lose: return "You lose"
            case .tie:  return "Draw"
            }
        }

        /// A GLYPH AS WELL AS A WORD. Colour is never the only channel (§9.10) — the same rule
        /// SeaBattleGrid follows for hit-vs-miss and LudoBoard follows for seats.
        var symbol: String {
            switch self {
            case .win:  return "trophy.fill"
            case .lose: return "chevron.down.circle"
            case .tie:  return "equal.circle"
            }
        }

        var sound: String {
            switch self {
            case .win:  return GameAudio.resultWin
            case .lose: return GameAudio.resultLose
            case .tie:  return GameAudio.resultTie
            }
        }

        /// A DEFEAT IS SHORTER THAN A WIN, deliberately. A defeat screen as loud as a win
        /// screen makes winning feel like nothing; the shortest honest path back into a game
        /// is the respect. This scales the whole sequence in MatchEndOverlay.
        var sequenceScale: Double {
            switch self {
            case .win:  return 1.0
            case .lose: return 0.75
            case .tie:  return 0.82
            }
        }
    }

    struct Stat: Equatable, Identifiable {
        let label: String
        let value: String
        /// At most ONE row is highlighted — a personal best, the winning margin. Two highlights
        /// is no highlight.
        var highlight: Bool = false
        var id: String { label }
    }

    let outcome: Outcome
    /// One short line, past tense. Defaults to the outcome's own word.
    var headline: String?
    /// Why, when the why is not obvious: "They resigned", "You ran out of time".
    var detail: String?
    /// 2-4 rows. Everything here is already in the frame or already tracked locally.
    var stats: [Stat] = []
    /// The game's own colour, so the overlay belongs to the board behind it.
    var accent: Color = VoiidColor.primary
    /// Text to drop into a chat. Nil hides the share button.
    ///
    /// ON A LOSS THE BUTTON BECOMES REMATCH, never Share — nobody shares a loss, and offering
    /// it reads as a joke at the player's expense. The overlay enforces that; a game may set
    /// this unconditionally.
    var shareText: String?

    /// WINNING BECAUSE SOMEONE LEFT IS NOT A VICTORY (§9.7).
    ///
    /// Set for a win by resignation or timeout: verdict and reason, no confetti, no fanfare,
    /// half-gain stinger, buttons immediately. The existing sound code already refuses to play
    /// a stinger for an abandoned match — `guard let winner = s.winnerUserId else { return }`
    /// in LudoSound and SeaBattleSound — and this is the same principle applied to the visuals.
    var hollow: Bool = false

    var title: String { headline ?? outcome.verdict }

    // MARK: - Per-game builders
    //
    // Kept together rather than each living in its own screen: six builders side by side is how
    // "Sea Battle says shots, Ludo says nothing" gets noticed.

    /// Rock Paper Scissors. `mine`/`theirs` are round wins.
    static func rps(mine: Int, theirs: Int, mostThrown: String?, record: String?) -> MatchEndResult {
        var stats: [Stat] = [Stat(label: "Rounds", value: "\(mine) – \(theirs)", highlight: mine > theirs)]
        if let mostThrown { stats.append(Stat(label: "You threw most", value: mostThrown)) }
        if let record { stats.append(Stat(label: "Record", value: record)) }
        return MatchEndResult(
            outcome: mine == theirs ? .tie : (mine > theirs ? .win : .lose),
            stats: stats,
            shareText: "Beat me at Rock Paper Scissors \(theirs)–\(mine). Rematch?")
    }

    static func ticTacToe(won: Bool?, moves: Int, record: String?) -> MatchEndResult {
        var stats: [Stat] = [Stat(label: "Moves played", value: "\(moves)")]
        if let record { stats.append(Stat(label: "Record", value: record)) }
        return MatchEndResult(
            outcome: won == nil ? .tie : (won! ? .win : .lose),
            headline: won == nil ? "Dead heat" : nil,
            detail: won == nil ? "Nobody could force it" : nil,
            stats: stats,
            shareText: won == nil
                ? "Forced a draw again. Nobody wins this one."
                : "Tic Tac Toe, settled. Rematch?")
    }

    /// Hand Cricket. `margin` is already phrased — "by 12 runs", "by 4 wickets".
    static func cricket(myScore: Int, theirScore: Int, margin: String?, wickets: Int) -> MatchEndResult {
        var stats: [Stat] = [
            Stat(label: "You", value: "\(myScore)", highlight: myScore > theirScore),
            Stat(label: "Them", value: "\(theirScore)"),
        ]
        if let margin { stats.append(Stat(label: "Won", value: margin)) }
        stats.append(Stat(label: "Wickets taken", value: "\(wickets)"))
        return MatchEndResult(
            outcome: myScore == theirScore ? .tie : (myScore > theirScore ? .win : .lose),
            detail: margin,
            stats: stats,
            shareText: myScore > theirScore
                ? "Chased \(theirScore) in Hand Cricket. Your turn."
                : "Hand Cricket, \(myScore) plays \(theirScore). Rematch?")
    }

    static func ludo(placement: Int, seats: Int, home: Int, tokens: Int,
                     captures: Int, lost: Int, won: Bool) -> MatchEndResult {
        MatchEndResult(
            outcome: won ? .win : .lose,
            headline: won ? "You win" : "\(ordinal(placement)) of \(seats)",
            stats: [
                Stat(label: "Tokens home", value: "\(home)/\(tokens)", highlight: home == tokens),
                Stat(label: "Captures made", value: "\(captures)"),
                Stat(label: "Tokens lost", value: "\(lost)"),
            ],
            accent: Ludo.seatColors[0],
            shareText: won ? "Won Ludo from last place. Ask me how." : nil)
    }

    /// Sea Battle. `hiddenShips` is how many of the winner's ships were never found — the line
    /// that turns a number into a story.
    static func seaBattle(won: Bool, shots: Int, hits: Int, sunk: Int,
                          hiddenShips: Int, endedBy: String?) -> MatchEndResult {
        let accuracy = shots > 0 ? Int(Double(hits) / Double(shots) * 100) : 0
        let hollow = won && (endedBy == "resign" || endedBy == "timeout")
        var stats: [Stat] = [
            Stat(label: "Shots fired", value: "\(shots)"),
            Stat(label: "Accuracy", value: "\(accuracy)%", highlight: accuracy >= 40),
            Stat(label: "Ships sunk", value: "\(sunk)/5"),
        ]
        if won && hiddenShips > 0 {
            stats.append(Stat(label: "Still hidden", value: "\(hiddenShips) of yours"))
        }
        return MatchEndResult(
            outcome: won ? .win : .lose,
            detail: {
                switch endedBy {
                case "resign":  return won ? "They resigned" : "You resigned"
                case "timeout": return won ? "They ran out of time" : "You ran out of time"
                default:        return nil
                }
            }(),
            stats: stats,
            shareText: won && hiddenShips > 0
                ? "Sank your fleet with \(hiddenShips) ships still hidden."
                : (won ? "Sank your whole fleet. Rematch?" : nil),
            hollow: hollow)
    }

    static func snake(length: Int, kills: Int, rank: Int, of players: Int,
                      best: Int, isBest: Bool) -> MatchEndResult {
        var stats: [Stat] = [
            Stat(label: "Length", value: "\(length)", highlight: isBest),
            Stat(label: "Kills", value: "\(kills)"),
        ]
        if players > 1 {
            stats.append(Stat(label: "Rank", value: "\(ordinal(rank)) of \(players)"))
        }
        if !isBest && best > length {
            stats.append(Stat(label: "Your best", value: "\(best)"))
        }
        return MatchEndResult(
            // Snake is a free-for-all, so "win" means finishing first and everything else is a
            // loss — there is no tie to draw.
            outcome: rank == 1 ? .win : .lose,
            headline: rank == 1 ? "You win" : nil,
            detail: isBest ? "New personal best" : nil,
            stats: stats,
            shareText: isBest
                ? "New best in Snake: \(length). Beat that."
                : "I got \(length) in Snake. Beat that.")
    }

    /// A match nobody finished. NOT an outcome — see §9.7 and the overlay's `abandoned` path.
    static func abandoned() -> MatchEndResult {
        MatchEndResult(
            outcome: .tie,
            headline: "Match abandoned",
            detail: "Nobody finished this one",
            hollow: true)
    }

    private static func ordinal(_ n: Int) -> String {
        switch n {
        case 1: return "1st"
        case 2: return "2nd"
        case 3: return "3rd"
        default: return "\(n)th"
        }
    }
}
