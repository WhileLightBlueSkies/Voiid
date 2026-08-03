package com.voiid.app.ui.theme

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * How the chat list is drawn: the icon GRID, or a classic LIST.
 * Port of iOS `ChatLayoutPreference.swift`.
 *
 * WHY BOTH EXIST
 * --------------
 * The grid is Voiid's own idea — chats as home-screen tiles you can drag to reorder, or onto
 * Call / Delete zones. It is distinctive, and genuinely better for the handful of people you
 * actually message.
 *
 * It is worse for everyone else. A grid shows a photo and a name; a list row shows the photo,
 * the name, the last message, the time and the unread count in one glance. Past twenty
 * conversations the grid becomes a wall of faces you have to read one at a time, and there is
 * nowhere to put the message preview that tells you whether a chat needs attention. Every
 * mainstream messenger is a list for exactly that reason.
 *
 * So this is a real preference, not a novelty toggle: the grid stays the default because it is
 * what makes the app feel like itself, and the list is one tap away for people whose chat list
 * has outgrown it.
 *
 * Deliberately NOT synced to the server — it describes this device's screen, and a phone and a
 * tablet can reasonably want different answers.
 *
 * Compose state, mirroring [VoiidTheme]'s mode: reading it inside a composable subscribes, so
 * flipping the setting recomposes the chat list immediately with no manual invalidation.
 */
enum class ChatLayout(val label: String) {
    GRID("Grid"),
    LIST("List"),
}

object ChatLayoutPreference {
    private const val PREFS = "voiid_prefs"
    private const val KEY = "chatlist_layout"

    /** GRID is the default: it is the app's signature, and a first-time user should meet it
     *  rather than a list they have seen a dozen times elsewhere. */
    var layout by mutableStateOf(ChatLayout.GRID)
        private set

    fun load(context: Context) {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY, ChatLayout.GRID.name) ?: ChatLayout.GRID.name
        layout = runCatching { ChatLayout.valueOf(raw) }.getOrDefault(ChatLayout.GRID)
    }

    fun set(context: Context, next: ChatLayout) {
        layout = next
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().putString(KEY, next.name).apply()
    }
}
