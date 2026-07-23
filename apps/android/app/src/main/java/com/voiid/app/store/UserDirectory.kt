package com.voiid.app.store

import android.content.Context
import androidx.compose.runtime.snapshots.SnapshotStateMap
import androidx.compose.runtime.mutableStateMapOf
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * The ONE place a human-readable name for a user id is produced — port of iOS
 * `UserDirectory.swift`.
 *
 * WHY: names were resolved ad hoc at every call site, each with its own fallback, and the
 * CALL paths had no fallback at all — so an incoming call showed a raw user UUID, and the
 * chat list showed whatever the peer typed at signup even when you had them saved as
 * something else. The address book WAS read correctly ([com.voiid.app.net.ContactsService]),
 * but only into a 120s in-memory cache that died on relaunch and was never consulted by the
 * call or chat UI.
 *
 * PRECEDENCE (applies everywhere — calls, chat list, chat header, profile):
 *   1. saved_name  — this device's address book. If you saved them as "Mum", every screen
 *                    says "Mum", whatever they call themselves.
 *   2. full_name   — the peer's own profile name.
 *   3. phone_e164  — a number is still useful.
 *   4. username    — Clips handle, last resort.
 *   5. "Unknown"   — NEVER a raw user id. A UUID on screen is always a bug.
 *
 * PRIVACY: this is also why the ring push carries no caller name. Sending one would tell
 * Google who is calling whom; instead the callee resolves the name locally from `caller_id`
 * through this directory, which needs no network and works when the app was just launched
 * cold by that push.
 */
object UserDirectory {

    /** Own IO scope: writes are fire-and-forget from UI/signaling threads. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    @Volatile private var dao: UserDao? = null
    @Volatile private var loadJob: Job? = null

    /**
     * In-memory mirror so Compose can resolve a name synchronously in a composition — Room
     * would otherwise be a disk hit on every row, and blocking queries are illegal on the
     * main thread anyway. Rebuilt from the database on launch and kept in step by every
     * upsert below; the database stays authoritative.
     *
     * A [SnapshotStateMap] so a contacts sync recomposes the screens showing those names.
     */
    private val byId: SnapshotStateMap<String, UserRow> = mutableStateMapOf()

    /** Idempotent. Safe (and cheap) to call from any entry point — Activity, FCM, service. */
    fun init(context: Context) {
        if (dao == null) {
            synchronized(this) {
                if (dao == null) {
                    dao = VoiidDatabase.get(context).users()
                    loadJob = scope.launch { reload() }
                }
            }
        }
    }

    /**
     * Init AND wait for the first load. For the push path only: a cold process woken by a
     * ring push has microseconds-old state and must not render the caller id while the
     * mirror is still empty.
     */
    suspend fun ready(context: Context) {
        init(context)
        loadJob?.join()
    }

    /**
     * Sign-out teardown only (see [com.voiid.app.net.SessionTeardown]): drops the in-memory
     * mirror of every saved contact name, phone number and photo. The `users` TABLE itself is
     * truncated separately by [com.voiid.app.store.VoiidDatabase.wipeAllForSignOut] (one
     * transaction for every table) — this only has to clear the mirror so nothing here
     * re-populates it via [reload] in the gap before that runs.
     */
    fun wipe() {
        byId.clear()
    }

    // MARK: - Reads

    /** Null only for a user we have never seen. Callers must NOT fall back to the raw id. */
    fun user(userId: String): UserRow? = byId[userId]

    /**
     * The name for a user id, with the full precedence chain applied.
     *
     * [fallback] covers the genuinely-unknown case (a call from someone not in the directory
     * yet). Pass a conversation title if you have one; pass nothing and the user sees
     * "Unknown", which is still better than a UUID. A fallback that IS the user id is
     * ignored — that is exactly the bug being fixed.
     */
    fun displayName(userId: String, fallback: String? = null): String {
        byId[userId]?.let { return it.displayName() }
        val f = fallback?.trim()
        if (!f.isNullOrEmpty() && f != userId) return f
        return "Unknown"
    }

    fun photoUrl(userId: String): String? = byId[userId]?.photoUrl

    /**
     * The peer's number in strict E.164, or null.
     *
     * Null is the NORMAL case for a peer met by username, or one we have not seen in a
     * `contacts/discover` pass yet: `phone_e164` is only ever written by the address-book
     * path ([upsertFromAddressBook] / [upsertManyFromAddressBook]) because the backend
     * matches contacts by SHA-256 hash and never returns raw numbers. Callers must treat
     * null as "no tel: handle for this person" and fall back, exactly as iOS falls back
     * to a `.generic` CXHandle.
     *
     * Normalized on the way out as well as on the way in — see [com.voiid.app.net.E164].
     */
    fun phoneE164(userId: String): String? =
        com.voiid.app.net.E164.normalize(byId[userId]?.phoneE164)

    /**
     * Reverse lookup: a phone number the SYSTEM handed us -> our user id. Direct port of
     * `CallIntentRouter.userId(forPhone:)`.
     *
     * This is what turns a tap on a contact-card row, or a redial from the system call log,
     * back into a Voiid call: the OS has no idea what a Voiid user id is, so the only thing
     * it can give us back is the number we put on the handle in the first place.
     *
     * Compares NORMALIZED numbers on BOTH sides. The system returns whatever string it
     * stored — which may be spaced, dashed, or re-formatted by the dialer — so a raw string
     * comparison would silently fail to find a user we plainly know.
     *
     * Reads the in-memory mirror only, so it is safe on the main thread. A cold process
     * (push- or intent-woken) should [ready] first; see [userIdForPhoneBlocking] for the
     * path that cannot.
     */
    fun userIdForPhone(raw: String?): String? {
        val target = com.voiid.app.net.E164.normalize(raw) ?: return null
        return byId.entries.firstOrNull {
            com.voiid.app.net.E164.normalize(it.value.phoneE164) == target
        }?.key
    }

    /**
     * [userIdForPhone] for a cold, intent-woken process: hits the database directly rather
     * than trusting a mirror that may not have loaded yet. IO — never call from the main
     * thread. Still normalizes on both sides, because the stored column was written by the
     * discovery normalizer and is not guaranteed to be strict E.164.
     */
    fun userIdForPhoneBlocking(raw: String?): String? {
        userIdForPhone(raw)?.let { return it }
        val target = com.voiid.app.net.E164.normalize(raw) ?: return null
        val d = dao ?: return null
        val rows = runCatching { d.withPhone() }.getOrDefault(emptyList())
        return rows.firstOrNull { com.voiid.app.net.E164.normalize(it.phoneE164) == target }?.userId
    }

    /**
     * Every peer we hold a usable number for. The contacts sync adapter's input set: a peer
     * with no number cannot be merged into an address-book entry and must not be written at
     * all, or it lands as an orphan "Voiid" contact.
     */
    fun withPhoneNumbers(): List<UserRow> =
        byId.values.filter { com.voiid.app.net.E164.normalize(it.phoneE164) != null }

    /** [withPhoneNumbers] straight from the database — for the sync adapter's own thread. */
    fun withPhoneNumbersBlocking(): List<UserRow> =
        withPhoneNumbersBlockingOrNull() ?: emptyList()

    /**
     * Like [withPhoneNumbersBlocking] but returns `null` when the DATABASE READ FAILED, as
     * distinct from an empty list meaning "this user genuinely has no Voiid contacts".
     *
     * The distinction is load-bearing for the contacts sync: it deletes every raw contact
     * NOT in this list, so treating a transient Room failure as "no peers" would wipe every
     * Voiid call row from the user's address book (to be recreated on the next good sync — a
     * visible flap). The sync adapter must abort its destructive pass on null.
     */
    fun withPhoneNumbersBlockingOrNull(): List<UserRow>? {
        val d = dao ?: return withPhoneNumbers()
        val rows = runCatching { d.withPhone() }.getOrNull() ?: return null
        return rows.filter { com.voiid.app.net.E164.normalize(it.phoneE164) != null }
    }

    /** Re-read the whole table into the mirror. Cheap: this table is contact-sized. */
    private suspend fun reload() {
        val d = dao ?: return
        val rows = withContext(Dispatchers.IO) { runCatching { d.all() }.getOrDefault(emptyList()) }
        val fresh = rows.associateBy { it.userId }
        // Diff-update instead of clear-then-refill. This method runs on a background
        // dispatcher after EVERY upsert while Compose readers and the call UI resolve names
        // off `byId` concurrently; a `clear()` opened a window where every lookup returned
        // "Unknown". Removing only the genuinely-departed keys and putting the rest never
        // empties the map, so a name in the table is resolvable throughout the refresh.
        val stale = byId.keys - fresh.keys
        for (k in stale) byId.remove(k)
        byId.putAll(fresh)
    }

    // MARK: - Writes
    //
    // Each source updates ONLY the columns it is authoritative for (see UserDao). That is the
    // whole point of storing the name components separately: a profile refresh from the server
    // must never clobber the address-book name, and a contacts re-sync must never clobber the
    // peer's own profile fields.

    /** From the device address book. Authoritative for `saved_name` + the number, nothing else. */
    fun upsertFromAddressBook(userId: String, savedName: String?, phoneE164: String?) {
        val d = dao ?: return
        scope.launch {
            d.upsertFromAddressBook(userId, savedName.orNull(), phoneE164.orNull(), nowSeconds())
            reload()
        }
    }

    /** From a server profile payload. Authoritative for the peer's self-set fields. */
    fun upsertFromServer(
        userId: String,
        fullName: String? = null,
        username: String? = null,
        photoUrl: String? = null,
        bio: String? = null,
        phoneE164: String? = null,
    ) {
        val d = dao ?: return
        scope.launch {
            d.upsertFromServer(
                userId, fullName.orNull(), username.orNull(), photoUrl.orNull(),
                bio.orNull(), phoneE164.orNull(), nowSeconds(),
            )
            reload()
        }
    }

    /**
     * Bulk variant for a contacts sync — one transaction and one mirror rebuild, so a
     * 500-contact refresh doesn't recompose every observing screen 500 times.
     */
    fun upsertManyFromAddressBook(entries: List<Triple<String, String?, String?>>) {
        if (entries.isEmpty()) return
        val d = dao ?: return
        scope.launch {
            d.upsertManyFromAddressBook(
                entries.map { Triple(it.first, it.second.orNull(), it.third.orNull()) },
                nowSeconds(),
            )
            reload()
        }
    }

    private fun nowSeconds() = System.currentTimeMillis() / 1000

    /** Blank is "I know nothing about this column", not "clear it" — see the COALESCE merges. */
    private fun String?.orNull(): String? = this?.trim()?.takeIf { it.isNotEmpty() }
}

/** The name to show for this row. See the precedence list on [UserDirectory]. */
fun UserRow.displayName(): String {
    for (candidate in listOf(savedName, fullName, phoneE164, username)) {
        val c = candidate?.trim()
        if (!c.isNullOrEmpty()) return c
    }
    return "Unknown"
}
