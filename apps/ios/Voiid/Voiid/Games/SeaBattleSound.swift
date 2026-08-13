//
//  SeaBattleSound.swift
//  Voiid
//
//  Sea Battle's audio, in one place, shared by the online match and practice mode
//  (docs/games/future/SEA_BATTLE.md §10).
//
//  In one file for the reason CricketSound.swift gives: the rule lived in four screens, two
//  per platform, and that is four chances for the same event to sound different depending on
//  which screen you were on. A player must not be able to tell a bot match from a real one by
//  the sound alone.
//
//  THE CATCH MOMENT IN SEA BATTLE IS: ONE OF *YOUR* SHIPS IS SUNK.
//
//  Not a hit on your ship — a hit is damage. The shared vocabulary rule (SOUND_DESIGN.md §3)
//  is that `catch` means "your attempt was intercepted or ended by the opponent", and a ship
//  is an attempt that is now over. Played UNMODIFIED, no pitch offset, layered and never
//  replacing: your ship sinking is catch.wav PLUS a hull groan, exactly as cricket's wicket is
//  catch + wicket_timber + a delayed roar.
//
//  Mirrors Android `SeaBattleSound.kt`. Keep the gains and the +180 ms groan delay identical.
//

import Foundation

enum SeaBattleSound {
    /// The groan lands AFTER the impact, never with it.
    ///
    /// Same trick as the crowd reacting 120 ms behind the wicket (SOUND_DESIGN.md §4.1): "a
    /// real crowd reacts *after* the event — simultaneous playback reads as one mushy noise."
    /// A sink is a hit plus a consequence, and the consequence has to land second or the two
    /// read as one event.
    private static let groanDelay: TimeInterval = 0.180

    /// A shot resolved. Called on every arriving frame that carries a new `lastShot`.
    ///
    /// The frame says what happened; this never re-derives it. `lastResult` is the server's
    /// answer (0 miss, 1 hit, 2 hit-and-sunk) and the sound follows it directly — a renderer
    /// that computed the result itself would be a renderer that could disagree with the board.
    static func shotResolved(_ s: SeaBattleState?, me: String?) {
        guard let s, let result = s.lastResult else { return }
        // Whose shot was it? The seat on the clock is the one who is ABOUT to fire, so the
        // shooter is the other one — and on a finished match there is no turn at all, in which
        // case the winner fired last.
        let shooter: Int? = {
            if let turn = s.turn { return 1 - turn }
            guard let winner = s.winnerUserId else { return nil }
            return s.players.firstIndex(of: winner)
        }()
        let mySeat = s.seat ?? me.flatMap { s.players.firstIndex(of: $0) }
        let iFired = shooter != nil && shooter == mySeat

        switch result {
        case 0:
            // Anticlimactic on purpose — a miss should deflate, like cricket's dot ball.
            GameAudio.shared.play("splash_\(Int.random(in: 1...3))", gain: 0.55)
        case 1:
            GameAudio.shared.play("hit_metal_\(Int.random(in: 1...3))", gain: 0.7)
            GameHaptics.eat()
        default:
            GameAudio.shared.play("hit_metal_\(Int.random(in: 1...3))", gain: 0.75)
            if iFired {
                // The one triumphant sound in the game. `kill()` is the existing pattern for
                // "you ended someone else's run" and a sink is exactly that (§6.1).
                after(groanDelay) { GameAudio.shared.play("sink_groan", gain: 0.75) }
                GameHaptics.kill()
            } else {
                // §10.1 — your ship is an attempt the opponent just ended.
                GameAudio.shared.play(GameAudio.catchShared, gain: 0.85)
                after(groanDelay) { GameAudio.shared.play("sink_groan", gain: 0.7) }
                GameHaptics.death()
            }
        }
    }

    /// Your turn came round. Soft, single, non-urgent — it will be heard hundreds of times.
    static func turnArrived() {
        GameAudio.shared.play("your_turn", gain: 0.45)
    }

    static func matchEnded(_ s: SeaBattleState?, me: String?) {
        guard let s, s.finished else { return }
        // An abandoned match has no winner and gets no stinger: nothing was won, and playing a
        // result sound over a match nobody finished would be a lie about what happened.
        guard let winner = s.winnerUserId else { return }
        GameAudio.shared.play(winner == me ? "rank_up" : "match_end", gain: 0.7)
    }

    private static func after(_ delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
