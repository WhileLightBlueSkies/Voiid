package com.voiid.app.model

import android.content.Context
import com.voiid.app.net.ProfileService
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

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
    private const val KEY_LAST_SEEN_VIS = "last_seen_visibility"
    private const val KEY_PHOTO_VIS = "photo_visibility"
    private const val KEY_ABOUT_VIS = "about_visibility"

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(NAME, Context.MODE_PRIVATE)

    /**
     * WhatsApp-style "who can see" scope. [server] is exactly what the backend stores +
     * enforces (users.*_privacy) in GET /users/:id and /users/status/:id.
     */
    enum class Visibility(val server: String, val label: String) {
        EVERYONE("everyone", "Everyone"),
        CONTACTS("contacts", "My Contacts"),
        NOBODY("nobody", "Nobody");

        companion object {
            fun from(raw: String?): Visibility =
                entries.firstOrNull { it.server == raw } ?: EVERYONE
        }
    }

    // "Who can see": default EVERYONE (matches the server default) when unset.
    fun lastSeenVisibility(context: Context): Visibility =
        Visibility.from(prefs(context).getString(KEY_LAST_SEEN_VIS, null))
    fun photoVisibility(context: Context): Visibility =
        Visibility.from(prefs(context).getString(KEY_PHOTO_VIS, null))
    fun aboutVisibility(context: Context): Visibility =
        Visibility.from(prefs(context).getString(KEY_ABOUT_VIS, null))

    fun setLastSeenVisibility(context: Context, v: Visibility) {
        prefs(context).edit().putString(KEY_LAST_SEEN_VIS, v.server).apply(); sync(context)
    }
    fun setPhotoVisibility(context: Context, v: Visibility) {
        prefs(context).edit().putString(KEY_PHOTO_VIS, v.server).apply(); sync(context)
    }
    fun setAboutVisibility(context: Context, v: Visibility) {
        prefs(context).edit().putString(KEY_ABOUT_VIS, v.server).apply(); sync(context)
    }

    /** Push all three scopes to the server so it can ENFORCE them for other viewers. */
    private fun sync(context: Context) {
        val app = context.applicationContext
        scope.launch {
            runCatching {
                ProfileService(app).updateProfile(
                    lastSeenPrivacy = lastSeenVisibility(app).server,
                    photoPrivacy = photoVisibility(app).server,
                    aboutPrivacy = aboutVisibility(app).server,
                )
            }
        }
    }

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
