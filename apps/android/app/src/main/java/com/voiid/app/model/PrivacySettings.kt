package com.voiid.app.model

import android.content.Context

/**
 * The persisted state behind Settings -> Privacy. Port of iOS `PrivacySettings.swift`.
 * Three booleans, and every one of them has a consumer in the app that genuinely reads it:
 *
 *     sendReadReceipts      -> Stores.kt's ChatStore guards both `engine.markRead(conv.id)`
 *                              call sites, the only places this device POSTs
 *                              `receipts/mark` with status "read".
 *     sendTypingIndicators  -> ChatDetailView guards the `chat.sendTyping(...)` call, the
 *                              only place this device emits a `typing` WS frame.
 *     showOnlineStatus      -> ChatDetailView.presenceText, the online / last-seen line
 *                              under the chat title. Display-only, on this device.
 *
 * If you add a key here, add its consumer in the same change. A toggle whose value nothing
 * reads is a lie the user cannot see, and it is exactly the failure this type exists to
 * prevent.
 *
 * Deliberately NOT stored here: blocking, last-seen visibility, profile-photo visibility,
 * disappearing messages, screenshot blocking, app lock, "who can add me to groups". None of
 * those has a schema, a route or a line of client code in this project, so none of them has
 * a setting — same reasoning as the iOS type this mirrors.
 *
 * Plain (unencrypted) SharedPreferences, matching iOS's choice of plain UserDefaults for
 * these three booleans — they are display/behaviour preferences, not secrets.
 */
object PrivacySettings {
    private const val NAME = "voiid_privacy_prefs"
    private const val KEY_READ_RECEIPTS = "send_read_receipts"
    private const val KEY_TYPING = "send_typing_indicators"
    private const val KEY_ONLINE_STATUS = "show_online_status"

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    // All three preferences default to ON, so an absent key must read true — plain
    // `getBoolean(key, false)` would silently switch every existing user's receipts off
    // on upgrade.
    fun sendReadReceipts(context: Context): Boolean = prefs(context).getBoolean(KEY_READ_RECEIPTS, true)
    fun setSendReadReceipts(context: Context, on: Boolean) =
        prefs(context).edit().putBoolean(KEY_READ_RECEIPTS, on).apply()

    fun sendTypingIndicators(context: Context): Boolean = prefs(context).getBoolean(KEY_TYPING, true)
    fun setSendTypingIndicators(context: Context, on: Boolean) =
        prefs(context).edit().putBoolean(KEY_TYPING, on).apply()

    fun showOnlineStatus(context: Context): Boolean = prefs(context).getBoolean(KEY_ONLINE_STATUS, true)
    fun setShowOnlineStatus(context: Context, on: Boolean) =
        prefs(context).edit().putBoolean(KEY_ONLINE_STATUS, on).apply()
}
