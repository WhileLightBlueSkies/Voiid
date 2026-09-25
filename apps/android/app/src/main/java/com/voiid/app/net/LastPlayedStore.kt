package com.voiid.app.net

import android.content.Context
import android.text.format.DateUtils

/**
 * The game this device last opened, for the Games tab's "Continue" row. That row used to be
 * hardcoded to "Continue Ludo · Yesterday" for everyone, including people who had never played.
 * Local only: it describes this phone's shelf, not the account.
 */
object LastPlayedStore {
    private const val PREFS = "voiid.games.lastplayed"

    data class Entry(val slug: String, val title: String, val at: Long) {
        fun whenText(now: Long = System.currentTimeMillis()): String =
            DateUtils.getRelativeTimeSpanString(at, now, DateUtils.MINUTE_IN_MILLIS).toString()
    }

    private fun prefs(ctx: Context) = ctx.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    fun record(ctx: Context, slug: String, title: String) {
        prefs(ctx).edit().putString("slug", slug).putString("title", title)
            .putLong("at", System.currentTimeMillis()).apply()
    }

    fun get(ctx: Context): Entry? {
        val p = prefs(ctx)
        val slug = p.getString("slug", null) ?: return null
        return Entry(slug, p.getString("title", null) ?: slug, p.getLong("at", 0L))
    }

    fun clear(ctx: Context) = prefs(ctx).edit().clear().apply()
}
