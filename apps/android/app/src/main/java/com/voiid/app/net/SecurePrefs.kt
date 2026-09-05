package com.voiid.app.net

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.io.File

/**
 * Raised when an encrypted store cannot be opened and NOTHING WAS DESTROYED trying.
 *
 * This is the state A02 asks for: a typed "unavailable", rather than a silent wipe dressed up
 * as recovery. The caller can retry later (a locked device unlocks) or offer an explicit
 * reset, which is the only path that may discard anything.
 */
class SecurePrefsUnavailableException(
    val store: String,
    val failure: SecurePrefsPolicy.Failure,
    cause: Throwable,
) : RuntimeException("encrypted store '$store' unavailable ($failure)", cause)

/**
 * Opens [EncryptedSharedPreferences] without destroying data to do it.
 *
 * ── WHAT THIS USED TO DO, AND WHY IT WAS DANGEROUS ───────────────────────────────
 *
 * Any exception deleted the preference file. If the rebuild then failed it deleted
 * `MasterKey.DEFAULT_MASTER_KEY_ALIAS` — the Keystore key SHARED BY EVERY STORE IN THIS APP —
 * and rebuilt from scratch. So the recovery path for one unreadable file could destroy the
 * E2E identity, the session token, the local message history and the account-backup master
 * secret together, on launch, with a log line. A device that happened to be locked, or a
 * transient IO error, was enough to trigger it, and the second failure was made MORE likely by
 * the first deletion, not less.
 *
 * The comment above that code correctly explained why deleting the master key causes a reset
 * cascade across sibling stores — and then did it anyway as a fallback.
 *
 * ── WHAT IT DOES NOW ─────────────────────────────────────────────────────────────
 *
 * The failure is classified and the response follows [SecurePrefsPolicy], which is pure and
 * tested. No path deletes the master key. No path deletes a preference file. The worst case is
 * that one store's file is moved ASIDE — the sibling stores and the shared key are untouched —
 * and the worst outcome is a typed exception saying the store is unavailable.
 *
 * A caller that cannot proceed without the store will now fail loudly instead of continuing
 * against a silently emptied one. That is the intended trade: an app that says "not right now"
 * is recoverable, and an app that has already deleted the master secret is not.
 */
internal object SecurePrefs {

    private const val TAG = "SecurePrefs"

    /** Where quarantined files go. Under files/, so it is covered by the backup allowlist. */
    private const val QUARANTINE_DIR = "secureprefs-quarantine"

    @Throws(SecurePrefsUnavailableException::class)
    fun open(ctx: Context, name: String): SharedPreferences {
        val app = ctx.applicationContext
        var attempt = 1
        var last: Throwable

        while (true) {
            try {
                return build(app, name)
            } catch (e: Throwable) {
                last = e
                val failure = SecurePrefsPolicy.classify(e)
                when (SecurePrefsPolicy.decide(failure, attempt)) {
                    SecurePrefsPolicy.Action.RETRY -> {
                        Log.i(TAG, "store '$name' unavailable ($failure), attempt $attempt — retrying")
                        // A short, bounded wait. The condition this covers (Keystore briefly
                        // busy, direct boot before first unlock) either clears immediately or
                        // will not clear on this call.
                        runCatching { Thread.sleep(SecurePrefsPolicy.backoffMillis(attempt)) }
                        attempt++
                    }

                    SecurePrefsPolicy.Action.QUARANTINE_AND_REBUILD -> {
                        // ONE store's file, moved aside. Not deleted, and not the shared
                        // keyset files — those belong to every store, and this one has no
                        // business touching them.
                        Log.e(
                            "VOIID",
                            "🧨 quarantining encrypted store '$name' (${e.javaClass.simpleName}) — " +
                                "its local data is unreadable and has been set aside, not deleted"
                        )
                        quarantine(app, name)
                        return try {
                            build(app, name)
                        } catch (e2: Throwable) {
                            // The rebuild failed too. THIS is where the old code deleted the
                            // master key and took every other store with it. Report instead.
                            Log.w(TAG, "rebuild of '$name' failed after quarantine", e2)
                            throw SecurePrefsUnavailableException(name, SecurePrefsPolicy.classify(e2), e2)
                        }
                    }

                    SecurePrefsPolicy.Action.REPORT_UNAVAILABLE -> {
                        Log.w(TAG, "store '$name' unavailable ($failure) — reporting, nothing destroyed", e)
                        throw SecurePrefsUnavailableException(name, failure, last)
                    }
                }
            }
        }
    }

    /**
     * Move the store's file out of shared_prefs so a fresh one can be created.
     *
     * A rename, deliberately. The bytes are ciphertext we cannot read today, but "cannot read"
     * is not "worthless": it is the evidence that something went wrong, and on some failures
     * (a key that comes back, a restore completed later) it is the user's data. Deleting it
     * forecloses both for no benefit — the rebuild needs the path free, and a rename frees it.
     */
    private fun quarantine(ctx: Context, name: String) {
        runCatching {
            val prefsFile = File(File(ctx.applicationInfo.dataDir, "shared_prefs"), "$name.xml")
            if (!prefsFile.exists()) return@runCatching
            val dir = File(ctx.filesDir, QUARANTINE_DIR).apply { mkdirs() }
            val target = File(dir, SecurePrefsPolicy.quarantineName(name, System.currentTimeMillis()))
            if (!prefsFile.renameTo(target)) {
                // Same filesystem, so this should not happen; if it does, copy-then-truncate
                // rather than give up, because the caller still needs a usable store.
                prefsFile.copyTo(target, overwrite = true)
                prefsFile.writeText("")
            }
            Log.i(TAG, "quarantined '$name' to ${target.name}")
        }.onFailure { Log.w(TAG, "could not quarantine '$name'", it) }
    }

    /** Files set aside by [quarantine], newest first. Surfaced so an explicit reset can
     *  report what it is about to discard rather than discarding it silently. */
    fun quarantined(ctx: Context): List<File> =
        File(ctx.applicationContext.filesDir, QUARANTINE_DIR)
            .listFiles()?.sortedByDescending { it.lastModified() } ?: emptyList()

    /**
     * The ONLY destructive path, and it is not reachable automatically.
     *
     * Discards quarantined ciphertext. Call this from a user-initiated reset that has already
     * told the person what they are losing.
     */
    fun discardQuarantined(ctx: Context) {
        quarantined(ctx).forEach { runCatching { it.delete() } }
    }

    private fun build(ctx: Context, name: String): SharedPreferences {
        val masterKey = MasterKey.Builder(ctx)
            .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
            .build()
        return EncryptedSharedPreferences.create(
            ctx,
            name,
            masterKey,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }
}
