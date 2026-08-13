package com.voiid.app.main.games

import com.voiid.app.net.GamesEngine

/**
 * Sea Battle's audio, in one place, shared by the online match and practice mode
 * (docs/games/future/SEA_BATTLE.md §10).
 *
 * In one file for the reason CricketSound gives: the rule lived in four screens, two per
 * platform, and that is four chances for the same event to sound different depending on which
 * screen you were on. A player must not be able to tell a bot match from a real one by sound.
 *
 * THE CATCH MOMENT IN SEA BATTLE IS: ONE OF *YOUR* SHIPS IS SUNK.
 *
 * Not a hit on your ship — a hit is damage. The shared vocabulary rule (SOUND_DESIGN.md §3) is
 * that `catch` means "your attempt was intercepted or ended by the opponent", and a ship is an
 * attempt that is now over. Played UNMODIFIED, no pitch offset, layered and never replacing.
 *
 * Mirrors iOS `SeaBattleSound.swift`. Keep the gains and the +180 ms groan delay identical.
 */
object SeaBattleSound {
    /**
     * The groan lands AFTER the impact, never with it.
     *
     * Same trick as the crowd reacting 120 ms behind the wicket (SOUND_DESIGN.md §4.1): "a real
     * crowd reacts *after* the event — simultaneous playback reads as one mushy noise." A sink
     * is a hit plus a consequence, and the consequence must land second.
     */
    private const val GROAN_DELAY_MS = 180L

    /**
     * A shot resolved. Called on every arriving frame that carries a new `lastShot`.
     *
     * The frame says what happened; this never re-derives it. `lastResult` is the server's
     * answer (0 miss, 1 hit, 2 hit-and-sunk) and the sound follows it directly — a renderer
     * that computed the result itself could disagree with the board.
     */
    fun shotResolved(s: GamesEngine.SeaBattleState?, me: String?, haptics: GameHaptics? = null) {
        val result = s?.lastResult ?: return
        // Whose shot was it? The seat on the clock is about to fire, so the shooter is the other
        // one — and a finished match has no turn, in which case the winner fired last.
        val shooter = s.turn?.let { 1 - it }
            ?: s.winnerUserId?.let { w -> s.players.indexOf(w).takeIf { it >= 0 } }
        val mySeat = s.seat ?: me?.let { s.players.indexOf(it).takeIf { i -> i >= 0 } }
        val iFired = shooter != null && shooter == mySeat

        when (result) {
            // Anticlimactic on purpose — a miss should deflate, like cricket's dot ball.
            0 -> GameAudio.playAny(listOf("splash_1", "splash_2", "splash_3"), gain = 0.55f)
            1 -> {
                GameAudio.playAny(listOf("hit_metal_1", "hit_metal_2", "hit_metal_3"), gain = 0.7f)
                haptics?.eat()
            }
            else -> {
                GameAudio.playAny(listOf("hit_metal_1", "hit_metal_2", "hit_metal_3"), gain = 0.75f)
                if (iFired) {
                    // The one triumphant sound in the game. `kill()` is the existing pattern for
                    // "you ended someone else's run", and a sink is exactly that.
                    GameAudio.play("sink_groan", delayMs = GROAN_DELAY_MS, gain = 0.75f)
                    haptics?.kill()
                } else {
                    // §10.1 — your ship is an attempt the opponent just ended.
                    GameAudio.play(GameAudio.CATCH, gain = 0.85f)
                    GameAudio.play("sink_groan", delayMs = GROAN_DELAY_MS, gain = 0.7f)
                    haptics?.death()
                }
            }
        }
    }

    /** Your turn came round. Soft, single, non-urgent — it will be heard hundreds of times. */
    fun turnArrived() {
        GameAudio.play("your_turn", gain = 0.45f)
    }

    fun matchEnded(s: GamesEngine.SeaBattleState?, me: String?) {
        if (s == null || !s.finished) return
        // An abandoned match has no winner and gets no stinger: nothing was won, and a result
        // sound over a match nobody finished would be a lie about what happened.
        val winner = s.winnerUserId ?: return
        GameAudio.play(if (winner == me) "rank_up" else "match_end", gain = 0.7f)
    }
}
