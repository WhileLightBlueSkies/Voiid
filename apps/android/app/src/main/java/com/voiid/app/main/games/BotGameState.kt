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

/**
 * Snake's personal bests, persisted locally.
 *
 * Same reasoning as the bot scores above: a practice match never reaches the backend, so
 * there is nothing to attach a record to and posting one would be an unverifiable claim.
 *
 * This exists because a bare final score gives a player no reason to tap again. "You got 84,
 * your best is 87" does — near-misses drive another attempt far more reliably than the raw
 * number, and a new best is worth calling out.
 *
 * Mirrors iOS `SnakeRecordStore`.
 */
class SnakeRecordStore(context: Context) {
    private val prefs =
        context.getSharedPreferences("voiid_snake_records", Context.MODE_PRIVATE)

    /** Longest snake ever reached. */
    val best: Int get() = prefs.getInt(KEY_BEST, 0)

    /**
     * Cumulative length across every match — the basis for unlocks, because it rewards
     * PLAYING rather than winning. Gating cosmetics on wins punishes exactly the players
     * most likely to give up.
     */
    val totalLength: Int get() = prefs.getInt(KEY_TOTAL, 0)

    /** Record a finished match. Returns true when this beat the previous best. */
    fun record(length: Int): Boolean {
        prefs.edit().putInt(KEY_TOTAL, totalLength + length).apply()
        if (length <= best) return false
        prefs.edit().putInt(KEY_BEST, length).apply()
        return true
    }

    private companion object {
        const val KEY_BEST = "snake.bestLength"
        const val KEY_TOTAL = "snake.totalLength"
    }
}
