//
//  GameRules.swift
//  Voiid
//
//  How each game is played, in the one place a player is guaranteed to look: the sheet that
//  opens when they tap a game and before they have committed to a match.
//
//  NOTHING EXPLAINED ITSELF (docs/games/CROSS_CUTTING.md §11). Hand Cricket in particular is
//  unplayable without being told — "matching numbers is out" is a house rule nobody guesses, and
//  a player who does not know it spends their first match wondering why picking the same number
//  as the bot keeps ending their innings. Tic Tac Toe needs no explanation and gets a short one
//  anyway, because a game that says nothing while its neighbours do reads as unfinished.
//
//  WRITTEN AS RULES, NOT MARKETING. "Both players pick a number from 0 to 6" is useful; "Test
//  your reflexes in this thrilling arcade challenge" is not, and it costs the reader the two
//  seconds they were willing to give. Every line here answers one of: what do I do, what wins,
//  what ends it.
//
//  KEYED BY SLUG, the same key the server's rules modules and the renderers use — so a game
//  whose rules have not been written falls back to nothing rather than to another game's.
//
//  Mirrors Android `GameRules.kt`.
//

import Foundation

enum GameRules {
    /// One rule line: a short label and the rule itself.
    ///
    /// Split rather than one paragraph because a player scanning for "how do I win" should find
    /// it without reading the rest — a wall of prose in a sheet is a wall nobody reads.
    struct Line: Identifiable {
        let id = UUID()
        let icon: String
        let text: String
    }

    /// The rules for a game, or nil if it has none written.
    static func lines(for slug: String) -> [Line] {
        switch slug {
        case "cricket":   return cricket
        case "tictactoe": return tictactoe
        case "rps":       return rps
        case "snake":     return snake
        default:          return []
        }
    }

    /// A one-line hook shown under the game's name. Sets expectations before the rules do.
    static func tagline(for slug: String) -> String? {
        switch slug {
        case "cricket":   return "Two innings. Guess your opponent, and don't get matched."
        case "tictactoe": return "Three in a row. Simple, solved, and still worth a rematch."
        case "rps":       return "First to 3. The trick is reading them, not the throw."
        case "snake":     return "Eat, grow, survive. Six snakes, one arena, no brakes."
        default:          return nil
        }
    }

    // MARK: - Per game

    // THE HOUSE RULES ARE THE POINT. Hand Cricket's scoring is obvious; what is not obvious is
    // that a matched number is a wicket, that this INCLUDES 0 vs 0, and that two wickets ends
    // your innings. All three are stated before anyone plays a ball.
    private static let cricket: [Line] = [
        Line(icon: "hand.raised.fingers.spread",
             text: "Both players secretly pick a number from 0 to 6, then reveal together."),
        Line(icon: "figure.cricket",
             text: "Batting: your number is added to your score."),
        Line(icon: "xmark.circle",
             text: "Match your opponent's number and you're OUT — including 0 against 0."),
        Line(icon: "arrow.triangle.2.circlepath",
             text: "Two wickets or all your overs ends the innings, then you swap."),
        Line(icon: "trophy",
             text: "Batting second, you win by passing their score. Level totals are a tie."),
    ]

    private static let tictactoe: [Line] = [
        Line(icon: "square.grid.3x3",
             text: "Take turns claiming a square on the 3×3 board."),
        Line(icon: "line.diagonal",
             text: "Three of yours in a row — across, down or diagonally — wins."),
        Line(icon: "equal.circle",
             text: "Fill the board with no line and it's a draw, which is the usual result "
                 + "between two people paying attention."),
    ]

    private static let rps: [Line] = [
        Line(icon: "hand.raised",
             text: "Rock beats scissors, scissors beats paper, paper beats rock."),
        Line(icon: "eye",
             text: "Both throws are locked in before either is shown, so there is nothing to "
                 + "react to."),
        Line(icon: "trophy",
             text: "First to 3 rounds takes the match. Ties replay the round."),
    ]

    // CHECKED LINE BY LINE AGAINST backend/games/src/engine/snake. Two of these were wrong on
    // the first pass — boost's cost and what happens when you hit a body — which is exactly the
    // kind of error that teaches a player the opposite of the game they are playing.
    private static let snake: [Line] = [
        Line(icon: "circle.hexagongrid",
             text: "Steer with the stick and eat pellets to grow."),
        Line(icon: "bolt",
             text: "Hold BOOST to sprint. It burns your own mass and drops it behind you as "
                 + "food, and it cuts out if you get too small to afford it."),
        Line(icon: "exclamationmark.triangle",
             text: "Run into another snake's body and YOU die — the one you hit is unharmed. "
                 + "So cutting in front of a big snake beats trying to outgrow it."),
        Line(icon: "arrow.up.left.and.arrow.down.right",
             text: "Head to head, the longer snake survives. If you are near enough the same "
                 + "size, you both go. The arena wall kills outright."),
        Line(icon: "flag.checkered",
             text: "Anything that dies bursts into food worth taking. Longest snake when the "
                 + "clock runs out wins."),
    ]
}
