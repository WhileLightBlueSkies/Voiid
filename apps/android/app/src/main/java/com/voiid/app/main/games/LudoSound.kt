package com.voiid.app.main.games

import com.voiid.app.net.GamesEngine

/**
 * Ludo's audio, in one place, shared by the online match and practice mode
 * (docs/games/future/LUDO.md §10).
 *
 * THE CATCH MOMENT IN LUDO IS: YOUR TOKEN IS CAPTURED AND SENT BACK TO THE YARD.
 *
 * Textbook — a player's attempt ended by an opponent (SOUND_DESIGN.md §3). A token forty squares
 * along its journey is the most concrete "attempt" in any game in this folder.
 *
 * ONLY WHEN IT IS *YOUR* TOKEN. Capturing someone else's plays a different, brighter sound: the
 * vocabulary rule is about the player whose attempt ended, and both players hearing `catch`
 * would flatten the most asymmetric moment in the game.
 *
 * Mirrors iOS `LudoSound.swift`. Keep the gains identical.
 */
object LudoSound {
    /** The die was thrown. Matched to the tumble so sound and motion are one event. */
    fun dieRolled() {
        GameAudio.play("die_roll", gain = 0.6f)
    }

    /** The final clack. Must land on the frame the face resolves, not before it. */
    fun dieSettled(haptics: GameHaptics? = null) {
        GameAudio.play("die_settle", gain = 0.65f)
        haptics?.eat()
    }

    /** A token moved. [move] is the server's own record of what happened. */
    fun moved(move: GamesEngine.LudoState.LastMove, mySeat: Int?, haptics: GameHaptics? = null) {
        if (move.from == Ludo.YARD) {
            // Entering from the yard is a firmer placement than an ordinary step.
            GameAudio.play("enter", gain = 0.6f)
        } else {
            // The most-triggered sound in the game — a full hop chain fires it once per square,
            // ~200 times a match. Four variants plus the engine's own jitter, per the chalk
            // argument (SOUND_DESIGN.md §4.3): without variation it is machine-like by move four.
            GameAudio.playAny(listOf("hop_1", "hop_2", "hop_3", "hop_4"), gain = 0.45f)
        }

        val captured = move.captured
        if (captured != null && captured.size == 2) {
            if (captured[0] == mySeat) {
                // §10.1 — your token is an attempt the opponent just ended. Played UNMODIFIED
                // and layered, never replacing: catch plus the capture knock underneath.
                GameAudio.play(GameAudio.CATCH, gain = 0.85f)
                GameAudio.play("capture", gain = 0.45f)
                haptics?.death()
            } else {
                GameAudio.play("capture", gain = 0.7f)
                haptics?.kill()
            }
        }

        if (move.to == Ludo.HOME) GameAudio.play("home", gain = 0.7f)
    }

    /** Your turn came round. Fires a lot in a 4-player game, so it must be gentle. */
    fun turnArrived() {
        GameAudio.play("your_turn", gain = 0.4f)
    }

    fun matchEnded(s: GamesEngine.LudoState?, me: String?) {
        if (s == null || !s.finished) return
        // An abandoned match has no winner and gets no stinger — nothing was won.
        val winner = s.winnerUserId ?: return
        GameAudio.play(if (winner == me) "rank_up" else "match_end", gain = 0.7f)
    }
}
