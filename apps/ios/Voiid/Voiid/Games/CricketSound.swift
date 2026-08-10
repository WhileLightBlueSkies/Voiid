//
//  CricketSound.swift
//  Voiid
//
//  Hand Cricket's audio, in one place, shared by the online match and the bot match.
//
//  It was in four screens (two per platform), each with its own copy of "wicket, or six, or
//  four, or runs" — which is four chances for the same event to sound different depending on
//  which screen you were on.
//
//  THE CROWD IS THE POINT (docs/games/SOUND_DESIGN.md §4.1). Hand Cricket is a game about
//  atmosphere and a stadium is half the experience; without one it is arithmetic with a
//  countdown. Everything else here is an impact layered over that bed.
//
//  Mirrors Android `CricketSound.kt`. Keep the gain curve and the 120 ms reaction delay
//  identical across the two.
//

import Foundation

enum CricketSound {
    // MARK: - The crowd bed

    /// A continuous stadium ambience under the whole match, whose gain tracks how tense the
    /// game is. One 22 s asset and a gain curve — no second file, no crossfading between
    /// "calm" and "tense" recordings.
    ///
    /// It rides `GameAudio`'s dedicated `loopVoice`, the same path Snake's `boost_loop` uses,
    /// so an unrelated one-shot can never steal the voice the bed is playing on.
    static func startBed() {
        GameAudio.shared.startLoop("crowd_base", gain: calmGain)
    }

    static func stopBed() {
        GameAudio.shared.stopLoop("crowd_base")
    }

    // Gain tiers, driven by the REQUIRED RUN RATE — the one number that actually says whether
    // a chase is comfortable or desperate, and it is derivable from state the engine already
    // sends (`target`, `ballsBowled`, `ballsTotal`).
    private static let calmGain: Float = 0.18
    private static let engagedGain: Float = 0.26
    private static let tenseGain: Float = 0.35
    /// The last over lifts it again regardless of the rate: even a dead chase gets loud at the
    /// end, because the crowd knows it is nearly over.
    private static let finalOverBonus: Float = 0.05

    /// Push the bed's gain for the current state. Safe to call every frame — `startLoop` is
    /// idempotent for the same name and only adjusts gain, so callers need not track edges.
    static func updateIntensity(_ s: CricketState) {
        guard !s.finished else { return }
        GameAudio.shared.startLoop("crowd_base", gain: bedGain(for: s))
    }

    static func bedGain(for s: CricketState) -> Float {
        bedGain(
            target: s.target,
            scored: s.scores.indices.contains(s.battingSeat) ? s.scores[s.battingSeat] : 0,
            ballsBowled: s.ballsBowled,
            ballsTotal: s.ballsTotal)
    }

    /// The curve itself, over loose values.
    ///
    /// Split out from the `CricketState` overload above because the BOT match has no such
    /// object — it keeps its score in local vars. Two callers, ONE curve: a second copy would
    /// drift, and then the same chase would feel different against a bot than against a
    /// friend for no reason anybody could name.
    static func bedGain(target: Int?, scored: Int, ballsBowled: Int, ballsTotal: Int) -> Float {
        var gain = calmGain

        // First innings has no target, so there is no chase to be tense about — the crowd sits
        // at its base level and the game supplies its own drama through wickets.
        if let target {
            let ballsLeft = max(ballsTotal - ballsBowled, 1)
            let needed = max(target - scored, 0)
            let requiredRate = Double(needed) * 6.0 / Double(ballsLeft)

            switch requiredRate {
            case ..<6:   gain = calmGain
            case ..<12:  gain = engagedGain
            default:     gain = tenseGain
            }
        }

        if ballsBowled >= ballsTotal - 6 { gain += finalOverBonus }
        return min(gain, maxGain)
    }

    private static let maxGain: Float = 0.42

    // MARK: - Ball outcomes

    /// The sound of one resolved ball.
    ///
    /// `mine` is whether the LOCAL player was batting: the same event is a triumph for one
    /// side and a disaster for the other, and the crowd should not celebrate your wicket.
    static func ball(runs: Int, wicket: Bool, mine: Bool) {
        if wicket {
            self.wicket(mine: mine)
            return
        }
        switch runs {
        case 6:
            GameAudio.shared.play("bat_crack", gain: 0.9)
            GameAudio.shared.play(mine ? "crowd_roar" : "crowd_groan", after: reactionDelay, gain: 0.7)
        case 4:
            GameAudio.shared.play("bat_crack", gain: 0.7)
            GameAudio.shared.play(mine ? "crowd_cheer" : "crowd_groan", after: reactionDelay, gain: 0.6)
        case 1...3:
            GameAudio.shared.play("bat_soft", gain: 0.6)
        default:
            // A dot ball SHOULD deflate. No crowd reaction at all is the point — the bed keeps
            // murmuring and nothing happens, which is exactly what a dot ball is.
            GameAudio.shared.play("bat_block", gain: 0.55)
        }
    }

    /// A wicket is THREE SOUNDS IN A STACK, not one.
    ///
    ///     0 ms    catch          the shared sound — the pick was matched
    ///     0 ms    wicket_timber  ball into stumps: wood crack plus bail rattle
    ///     120 ms  crowd reaction delayed, because a real crowd reacts AFTER the event
    ///
    /// THE DELAY IS WHAT SELLS IT. Fired together the three read as one mushy noise and the
    /// impact is lost entirely.
    private static func wicket(mine: Bool) {
        GameAudio.shared.play(GameAudio.catchShared, gain: 0.7)
        GameAudio.shared.play("wicket_timber", gain: 0.85)
        // Your wicket is a groan; taking one is a roar. Same event, opposite meaning.
        GameAudio.shared.play(mine ? "crowd_groan" : "crowd_roar",
                              after: reactionDelay, gain: 0.75)
    }

    /// Identical on Android. See `wicket` for why this number exists at all.
    static let reactionDelay: TimeInterval = 0.12

    // MARK: - Match beats

    /// Innings break: scattered applause, tapering.
    static func inningsBreak() {
        GameAudio.shared.play("innings", gain: 0.5)
        GameAudio.shared.play("crowd_applause", after: 0.10, gain: 0.65)
    }

    /// The crowd delivers the verdict.
    static func matchEnd(won: Bool) {
        GameAudio.shared.play("match_end", gain: 0.7)
        GameAudio.shared.play(won ? "crowd_roar" : "crowd_groan", after: 0.18, gain: 0.8)
    }
}
