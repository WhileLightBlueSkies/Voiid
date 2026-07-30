package com.voiid.app.main.games

import android.content.Context
import androidx.core.content.edit

/**
 * Local, persisted record of practice results — docs/GAMES.md §1 (bot play is deliberately
 * client-only).
 *
 * WHY SHAREDPREFERENCES AND NOT THE SERVER. A bot match never reaches the backend: there is
 * no match row to attach a result to, and posting one would let a client inflate its own
 * record for free, which is exactly the kind of unverifiable claim the online game is
 * server-authoritative to prevent. So practice results stay on the device and are never
 * mixed into the friends leaderboard, which counts only refereed matches.
 *
 * Kept per difficulty because "12 wins" means nothing without knowing whether they were
 * against the easy bot or the near-perfect one.
 */
class BotScoreStore(context: Context) {

    private val prefs = context.getSharedPreferences("voiid_bot_scores", Context.MODE_PRIVATE)

    data class Record(val wins: Int, val draws: Int, val losses: Int) {
        val played: Int get() = wins + draws + losses
    }

    fun record(level: BotDifficulty): Record = Record(
        prefs.getInt("${level.name}_w", 0),
        prefs.getInt("${level.name}_d", 0),
        prefs.getInt("${level.name}_l", 0),
    )

    /** [outcome] is +1 human win, 0 draw, -1 bot win. */
    fun add(level: BotDifficulty, outcome: Int) {
        val key = when {
            outcome > 0 -> "${level.name}_w"
            outcome < 0 -> "${level.name}_l"
            else -> "${level.name}_d"
        }
        prefs.edit { putInt(key, prefs.getInt(key, 0) + 1) }
    }

    fun clear() = prefs.edit { clear() }
}
