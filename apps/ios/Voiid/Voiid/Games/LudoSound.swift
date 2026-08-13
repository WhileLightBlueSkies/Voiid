//
//  LudoSound.swift
//  Voiid
//
//  Ludo's audio, in one place, shared by the online match and practice mode
//  (docs/games/future/LUDO.md §10).
//
//  THE CATCH MOMENT IN LUDO IS: YOUR TOKEN IS CAPTURED AND SENT BACK TO THE YARD.
//
//  Textbook — a player's attempt ended by an opponent (SOUND_DESIGN.md §3). A token forty
//  squares along its journey is the most concrete "attempt" in any game in this folder.
//
//  ONLY WHEN IT IS *YOUR* TOKEN. Capturing someone else's plays a different, brighter sound: the
//  vocabulary rule is about the player whose attempt ended, and both players hearing `catch`
//  would flatten the most asymmetric moment in the game.
//
//  Mirrors Android `LudoSound.kt`. Keep the gains identical.
//

import Foundation

enum LudoSound {
    /// The die was thrown. Matched to the tumble so the sound and the motion are one event.
    static func dieRolled() {
        GameAudio.shared.play("die_roll", gain: 0.6)
    }

    /// The final clack. Must land on the frame the face resolves, not before it.
    static func dieSettled() {
        GameAudio.shared.play("die_settle", gain: 0.65)
        GameHaptics.eat()
    }

    /// A token moved. `move` is the server's own record of what happened.
    static func moved(_ move: LudoState.LastMove, mySeat: Int?) {
        // Entering from the yard is a firmer placement than an ordinary step.
        if move.from == Ludo.yard {
            GameAudio.shared.play("enter", gain: 0.6)
        } else {
            // The most-triggered sound in the game — a 6-square move would fire it six times in
            // a full hop chain, ~200 times a match. Four variants plus the engine's own ±3%
            // jitter, per the chalk argument (SOUND_DESIGN.md §4.3): without variation it
            // becomes machine-like by move four.
            GameAudio.shared.play("hop_\(Int.random(in: 1...4))", gain: 0.45)
        }

        if let captured = move.captured, captured.count == 2 {
            let victim = captured[0]
            if victim == mySeat {
                // §10.1 — your token is an attempt the opponent just ended. Played UNMODIFIED
                // and layered, never replacing: catch + the capture knock underneath.
                GameAudio.shared.play(GameAudio.catchShared, gain: 0.85)
                GameAudio.shared.play("capture", gain: 0.45)
                GameHaptics.death()
            } else {
                GameAudio.shared.play("capture", gain: 0.7)
                GameHaptics.kill()
            }
        }

        if move.to == Ludo.home {
            GameAudio.shared.play("home", gain: 0.7)
        }
    }

    /// Your turn came round. Fires a lot in a 4-player game, so it must be gentle.
    static func turnArrived() {
        GameAudio.shared.play("your_turn", gain: 0.4)
    }

    static func matchEnded(_ s: LudoState?, me: String?) {
        guard let s, s.finished else { return }
        // An abandoned match has no winner and gets no stinger — nothing was won.
        guard let winner = s.winnerUserId else { return }
        GameAudio.shared.play(winner == me ? "rank_up" : "match_end", gain: 0.7)
    }
}
