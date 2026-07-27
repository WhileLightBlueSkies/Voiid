package com.voiid.app.net

import android.content.Context
import com.voiid.app.store.UserDirectory
import com.voiid.app.store.VoiidDatabase

/**
 * Removes this account's local footprint from the device. Port of iOS
 * `SessionTeardown.swift`.
 *
 * WHY THIS EXISTS
 * ---------------
 * `AppSession.signOut()` cleared only the JWT (`TokenStore.clear()` via
 * `AuthService.logout()`). Everything that actually holds the user's data survived it:
 *
 *  - the Room database (`voiid.db`) — and because every read here is local-first (see
 *    `VoiidDatabase`'s class doc), the NEXT account signed in on this device rendered the
 *    previous user's conversations, messages and call history;
 *  - `voiid_messages.json`, ChatEngine's plaintext decrypted-message store, and its
 *    in-memory Olm sessions;
 *  - the encrypted E2E prefs (identity pickle, pickle key, device id, prekey counters) and
 *    the `bootstrapped` latch, so the next account's `bootstrap()` silently reused the old
 *    identity;
 *  - the in-memory contact-name mirror in `UserDirectory`.
 *
 * ORDERING IS LOAD-BEARING — mirrors iOS exactly: wipe in-memory state BEFORE deleting
 * files/tables, or a holder still running (a send, a poll) could flush its stale contents
 * right back to disk after the delete. Every step is best-effort and independent: a
 * failure in one must not prevent the rest.
 */
object SessionTeardown {

    /**
     * Wipe every local trace of the signed-in account. Call this BEFORE clearing the auth
     * token — `AppSession.signOut()` calling `auth.logout()` immediately after is the
     * intended sequence.
     */
    fun wipeLocalAccountState(context: Context) {
        val appContext = context.applicationContext

        // 1 — in-memory state, BEFORE the files/tables, or a flush rewrites them.
        runCatching { ChatEngine.get(appContext).wipeInMemoryState() }
        runCatching { UserDirectory.wipe() }
        runCatching { E2EManager.get(appContext).resetForSignOut() }
        runCatching { GroupEngine.get(appContext).resetForSignOut() }

        // 2 — the local-first store every screen reads from.
        runCatching { VoiidDatabase.wipeAllForSignOut(appContext) }

        // 3 — ChatEngine's own plaintext file store (separate from Room; see its class doc).
        runCatching { java.io.File(appContext.filesDir, "voiid_messages.json").delete() }
        runCatching { java.io.File(appContext.filesDir, "voiid_messages.json.tmp").delete() }
        // Phase 2: the per-conversation message shards.
        runCatching { java.io.File(appContext.filesDir, "messages").deleteRecursively() }

        // 4 — decrypted media cache (memory + disk), or the previous account's photos/voice
        // notes stay readable on this device behind the login screen.
        runCatching { com.voiid.app.main.MediaCache.clear(appContext) }
    }
}
