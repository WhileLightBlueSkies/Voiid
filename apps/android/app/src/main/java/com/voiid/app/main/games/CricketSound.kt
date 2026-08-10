package com.voiid.app.main.games

import android.content.Context
import com.voiid.app.net.GamesEngine

/**
 * Hand Cricket's audio, in one place, shared by the online match and the bot match.
 *
 * It was in four screens (two per platform), each with its own copy of "wicket, or six, or
 * four, or runs" — which is four chances for the same event to sound different depending on
 * which screen you were on.
 *
 * THE CROWD IS THE POINT (docs/games/SOUND_DESIGN.md §4.1). Hand Cricket is a game about
 * atmosphere and a stadium is half the experience; without one it is arithmetic with a
 * countdown. Everything else here is an impact layered over that bed.
 *
 * Mirrors iOS `CricketSound.swift`. Every constant below is identical to it — the gain tiers,
 * the final-over bonus and the 120 ms reaction delay especially.
 */
object CricketSound {

    // ---- the crowd bed --------------------------------------------------------------------

    // Gain tiers, driven by the REQUIRED RUN RATE — the one number that actually says whether a
    // chase is comfortable or desperate, and it is derivable from state the engine already
    // sends (target, ballsBowled, ballsTotal).
    private const val CALM_GAIN = 0.18f
    private const val ENGAGED_GAIN = 0.26f
    private const val TENSE_GAIN = 0.35f
    /** The last over lifts it regardless of the rate: even a dead chase gets loud at the end. */
    private const val FINAL_OVER_BONUS = 0.05f
    private const val MAX_GAIN = 0.42f

    /**
     * Start the continuous stadium ambience.
     *
     * On MediaPlayer, not SoundPool — see [GameAudio.startBed]. The bed is 22 s and SoundPool's
     * practical ceiling is around 1 MB of decoded PCM per sample.
     */
    fun startBed(context: Context) {
        GameAudio.startBed(context, "crowd_base", CALM_GAIN)
    }

    fun stopBed() = GameAudio.stopBed()

    /** Push the bed's gain for the current state. Safe to call on every frame. */
    fun updateIntensity(s: GamesEngine.CricketState) {
        if (s.finished) return
        GameAudio.setBedGain(bedGain(s))
    }

    fun bedGain(s: GamesEngine.CricketState): Float = bedGain(
        target = s.target,
        scored = s.scores.getOrElse(s.battingSeat) { 0 },
        ballsBowled = s.ballsBowled,
        ballsTotal = s.ballsTotal,
    )

    /**
     * The curve itself, over loose values.
     *
     * Split out from the [GamesEngine.CricketState] overload above because the BOT match has no
     * such object — it keeps its score in local composable state. Two callers, ONE curve: a
     * second copy would drift, and then the same chase would feel different against a bot than
     * against a friend for no reason anybody could name.
     */
    fun bedGain(target: Int?, scored: Int, ballsBowled: Int, ballsTotal: Int): Float {
        var gain = CALM_GAIN

        // First innings has no target, so there is no chase to be tense about — the crowd sits
        // at its base level and the game supplies its own drama through wickets.
        if (target != null) {
            val ballsLeft = (ballsTotal - ballsBowled).coerceAtLeast(1)
            val needed = (target - scored).coerceAtLeast(0)
            val requiredRate = needed * 6.0 / ballsLeft
            gain = when {
                requiredRate < 6 -> CALM_GAIN
                requiredRate < 12 -> ENGAGED_GAIN
                else -> TENSE_GAIN
            }
        }

        if (ballsBowled >= ballsTotal - 6) gain += FINAL_OVER_BONUS
        return minOf(gain, MAX_GAIN)
    }

    // ---- ball outcomes --------------------------------------------------------------------

    /** Identical on iOS. See [wicket] for why this number exists at all. */
    const val REACTION_DELAY_MS = 120L

    /**
     * The sound of one resolved ball.
     *
     * [mine] is whether the LOCAL player was batting: the same event is a triumph for one side
     * and a disaster for the other, and the crowd should not celebrate your wicket.
     */
    fun ball(runs: Int, wicket: Boolean, mine: Boolean) {
        if (wicket) {
            wicket(mine)
            return
        }
        when {
            runs == 6 -> {
                GameAudio.play("bat_crack", gain = 0.9f)
                GameAudio.play(if (mine) "crowd_roar" else "crowd_groan",
                    delayMs = REACTION_DELAY_MS, gain = 0.7f)
            }
            runs == 4 -> {
                GameAudio.play("bat_crack", gain = 0.7f)
                GameAudio.play(if (mine) "crowd_cheer" else "crowd_groan",
                    delayMs = REACTION_DELAY_MS, gain = 0.6f)
            }
            runs > 0 -> GameAudio.play("bat_soft", gain = 0.6f)
            // A dot ball SHOULD deflate. No crowd reaction at all is the point — the bed keeps
            // murmuring and nothing happens, which is exactly what a dot ball is.
            else -> GameAudio.play("bat_block", gain = 0.55f)
        }
    }

    /**
     * A wicket is THREE SOUNDS IN A STACK, not one.
     *
     *     0 ms    catch          the shared sound — the pick was matched
     *     0 ms    wicket_timber  ball into stumps: wood crack plus bail rattle
     *     120 ms  crowd reaction delayed, because a real crowd reacts AFTER the event
     *
     * THE DELAY IS WHAT SELLS IT. Fired together the three read as one mushy noise and the
     * impact is lost entirely.
     */
    private fun wicket(mine: Boolean) {
        GameAudio.play(GameAudio.CATCH, gain = 0.7f)
        GameAudio.play("wicket_timber", gain = 0.85f)
        // Your wicket is a groan; taking one is a roar. Same event, opposite meaning.
        GameAudio.play(if (mine) "crowd_groan" else "crowd_roar",
            delayMs = REACTION_DELAY_MS, gain = 0.75f)
    }

    // ---- match beats ----------------------------------------------------------------------

    /** Innings break: scattered applause, tapering. */
    fun inningsBreak() {
        GameAudio.play("innings", gain = 0.5f)
        GameAudio.play("crowd_applause", delayMs = 100L, gain = 0.65f)
    }

    /** The crowd delivers the verdict. */
    fun matchEnd(won: Boolean) {
        GameAudio.play("match_end", gain = 0.7f)
        GameAudio.play(if (won) "crowd_roar" else "crowd_groan", delayMs = 180L, gain = 0.8f)
    }
}
