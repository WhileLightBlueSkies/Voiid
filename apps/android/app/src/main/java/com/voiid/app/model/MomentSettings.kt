package com.voiid.app.model

import android.content.Context
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import com.voiid.app.store.LocalStore
import com.voiid.app.store.UserDirectory

/**
 * Who your moments go to. One setting, chosen in Moments settings and shown on every new
 * moment — not re-picked per post. Port of iOS Models/StorySettings.swift (MomentAudience).
 */
enum class MomentAudience(val title: String, val detail: String) {
    /** Phone contacts on Voiid, and everyone you chat with. */
    CONNECTIONS("All my connections", "Your contacts on Voiid and everyone you chat with"),
    /** Only people saved in your phone's contacts. */
    CONTACTS("My contacts", "People saved in your phone who use Voiid"),
    /** Only people you have messaged with. */
    CHATS("People I chat with", "Only people you've messaged with"),
    /** Only the people you pick. */
    SELECTED("Only selected people", "Only the people you choose"),
    /** Nobody: kept on this phone only. */
    NOBODY("Nobody", "Only you. Kept on this phone, never sent.");

    /** Whether "Hide from" applies on top of this choice. */
    val allowsHiding: Boolean get() = this == CONNECTIONS || this == CONTACTS || this == CHATS
}

/**
 * Per-device Moments preferences: who your moments go to, and whether to keep your own.
 * Views always show — who viewed your moment and when — so there is no setting for them.
 *
 * Backed by [StoryPrefs] (cleared on sign-out by StoryEngine, which also calls [forget]).
 */
object MomentSettings {
    private const val KEY_MODE = "moment_audience_mode"
    private const val KEY_SELECTED = "moment_selected_people"
    private const val KEY_HIDDEN = "moment_hidden_from"
    private const val KEY_KEEP = "moment_keep_by_default"
    // The per-post picker these replace.
    private const val LEGACY_ALL = "audience_all"
    private const val LEGACY_CUSTOM = "audience_custom"

    var audienceMode by mutableStateOf(MomentAudience.CONNECTIONS)
        private set
    var selectedPeople by mutableStateOf<Set<String>>(emptySet())
        private set
    var hiddenFrom by mutableStateOf<Set<String>>(emptySet())
        private set
    /**
     * ON by default. Keeps only YOUR OWN copy of YOUR OWN moment past its expiry, on this
     * device — it does not change who can see it, and a viewer's copy still expires.
     */
    var keepByDefault by mutableStateOf(true)
        private set

    private var loaded = false

    private fun prefs(context: Context) = context.getSharedPreferences(StoryPrefs.NAME, Context.MODE_PRIVATE)

    fun load(context: Context) {
        if (loaded) return
        val p = prefs(context)
        selectedPeople = p.getStringSet(KEY_SELECTED, emptySet())?.toSet() ?: emptySet()
        hiddenFrom = p.getStringSet(KEY_HIDDEN, emptySet())?.toSet() ?: emptySet()
        keepByDefault = p.getBoolean(KEY_KEEP, true)
        val raw = p.getString(KEY_MODE, null)
        audienceMode = raw?.let { runCatching { MomentAudience.valueOf(it) }.getOrNull() } ?: run {
            // Carried over from the per-post picker: a custom list becomes "Only selected people".
            val custom = p.getStringSet(LEGACY_CUSTOM, emptySet()).orEmpty()
            if (!p.getBoolean(LEGACY_ALL, true) && custom.isNotEmpty()) {
                selectedPeople = custom.toSet()
                p.edit().putStringSet(KEY_SELECTED, selectedPeople).apply()
                MomentAudience.SELECTED
            } else MomentAudience.CONNECTIONS
        }
        loaded = true
    }

    fun setAudience(context: Context, mode: MomentAudience) {
        audienceMode = mode
        prefs(context).edit().putString(KEY_MODE, mode.name).apply()
    }

    fun setSelected(context: Context, ids: Set<String>) {
        selectedPeople = ids
        prefs(context).edit().putStringSet(KEY_SELECTED, ids).apply()
    }

    fun setHidden(context: Context, ids: Set<String>) {
        hiddenFrom = ids
        prefs(context).edit().putStringSet(KEY_HIDDEN, ids).apply()
    }

    fun setKeep(context: Context, on: Boolean) {
        keepByDefault = on
        prefs(context).edit().putBoolean(KEY_KEEP, on).apply()
    }

    /** Sign-out: the prefs file is cleared separately; drop what is held in memory. */
    fun forget() {
        audienceMode = MomentAudience.CONNECTIONS
        selectedPeople = emptySet()
        hiddenFrom = emptySet()
        keepByDefault = true
        loaded = false
    }

    // ── Who that is ────────────────────────────────────────────────────────────

    /** The groups the choices are drawn from, read once per screen. */
    data class People(val connections: Set<String>, val contacts: Set<String>, val chats: Set<String>)

    suspend fun people(context: Context): People {
        UserDirectory.ready(context)
        val me = com.voiid.app.net.TokenStore.get(context).userId
        val convs = runCatching { LocalStore.conversations(context) }.getOrDefault(emptyList())
            .filter { it.type == ConversationType.DIRECT }
        val chatPeers = convs.mapNotNull { c -> c.peerUserId?.takeIf { it.isNotEmpty() && c.lastMessageAt != null } }.toSet()
        val allPeers = convs.mapNotNull { it.peerUserId?.takeIf(String::isNotEmpty) }.toSet()
        val contacts = UserDirectory.knownUserIds()
            .filter { !UserDirectory.user(it)?.savedName.isNullOrBlank() }.toSet()
        fun Set<String>.notMe() = if (me == null) this else this - me
        return People(
            connections = (allPeers + UserDirectory.knownUserIds()).notMe(),
            contacts = contacts.notMe(),
            chats = chatPeers.notMe(),
        )
    }

    /** Everyone [mode] covers right now, before "Hide from". */
    fun covered(mode: MomentAudience, people: People): Set<String> = when (mode) {
        MomentAudience.CONNECTIONS -> people.connections
        MomentAudience.CONTACTS -> people.contacts
        MomentAudience.CHATS -> people.chats
        MomentAudience.SELECTED -> selectedPeople intersect people.connections
        MomentAudience.NOBODY -> emptySet()
    }

    /** Who a new moment is sent to under the current setting. */
    fun resolved(people: People): List<String> {
        var ids = covered(audienceMode, people)
        if (audienceMode.allowsHiding) ids = ids - hiddenFrom
        return ids.toList()
    }
}
