package com.voiid.app.net

import android.content.Context

/**
 * On-device map of VOIID user_id → the matched local contact's saved name +
 * phone number, captured during [ContactsService.discover].
 *
 * The phone number is NOT available from the backend (it never leaves the device
 * as a raw value — contacts are matched by hash). So the contact profile screen
 * sources the "real number" from here: the number the user themselves saved for
 * this person. Only contacts the user has actually saved will have an entry.
 */
object ContactDirectory {
    data class Entry(val name: String?, val number: String?)

    private const val PREFS = "voiid_contact_directory"
    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /** Store/refresh the saved name + number for a matched VOIID user. */
    fun put(context: Context, userId: String, name: String?, number: String?) {
        prefs(context).edit()
            .putString("$userId.name", name)
            .putString("$userId.num", number)
            .apply()
    }

    /** Look up what the user saved for [userId], if anything. */
    fun get(context: Context, userId: String): Entry {
        val p = prefs(context)
        return Entry(
            name = p.getString("$userId.name", null)?.takeIf { it.isNotBlank() },
            number = p.getString("$userId.num", null)?.takeIf { it.isNotBlank() },
        )
    }
}
