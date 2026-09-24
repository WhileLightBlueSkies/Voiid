package com.voiid.app.net

import android.content.Context

/**
 * Which conversations are muted, and until when. Twin of iOS `MuteStore.swift`.
 *
 * EXPIRY IS COMPUTED, NOT SCHEDULED: a mute stores an end time and [isMuted] reads the clock,
 * so nothing has to fire when it passes — it survives process death and reboots for free.
 * Stored in app-private prefs, which the FCM service (same process) reads before posting.
 */
object MuteStore {
    enum class Duration(val title: String, val millis: Long?) {
        EIGHT_HOURS("8 hours", 8 * 3_600_000L),
        ONE_DAY("24 hours", 24 * 3_600_000L),
        ONE_WEEK("1 week", 7 * 24 * 3_600_000L),
        ALWAYS("Until I turn it back on", null),
    }

    private const val PREFS = "voiid.muted.conversations"

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** 0 means "always". */
    fun mute(ctx: Context, conversationId: String, duration: Duration) {
        val until = duration.millis?.let { System.currentTimeMillis() + it } ?: 0L
        prefs(ctx).edit().putLong(conversationId, until).apply()
    }

    fun unmute(ctx: Context, conversationId: String) {
        prefs(ctx).edit().remove(conversationId).apply()
    }

    /** Expired entries are cleaned up as they are read. */
    fun isMuted(ctx: Context, conversationId: String): Boolean {
        val p = prefs(ctx)
        if (!p.contains(conversationId)) return false
        val until = p.getLong(conversationId, -1L)
        if (until == 0L) return true
        if (System.currentTimeMillis() < until) return true
        unmute(ctx, conversationId)
        return false
    }

    /** When the mute ends; null when not muted or muted forever. */
    fun mutedUntil(ctx: Context, conversationId: String): Long? {
        val until = prefs(ctx).getLong(conversationId, -1L)
        return until.takeIf { it > System.currentTimeMillis() }
    }

    fun clear(ctx: Context) = prefs(ctx).edit().clear().apply()
}
