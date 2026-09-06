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

/** Opens encrypted preferences without moving originals or creating an empty recovery store. */
internal object SecurePrefs {

    private const val TAG = "SecurePrefs"

    /** Where quarantined files go. Under files/, so it is covered by the backup allowlist. */
    private const val QUARANTINE_DIR = "secureprefs-quarantine"

    @Throws(SecurePrefsUnavailableException::class)
    fun open(ctx: Context, name: String): SharedPreferences {
        val app = ctx.applicationContext
        // Older builds moved files away and reopened empty stores. Never bootstrap a new
        // identity while unresolved evidence for this store remains, including on restart.
        if (quarantined(app).any { it.name.startsWith("$name.quarantined-") }) {
            throw SecurePrefsUnavailableException(name, SecurePrefsPolicy.Failure.CORRUPTED,
                IllegalStateException("Encrypted store requires explicit recovery"))
        }
        var attempt = 1
        var last: Throwable

        while (true) {
            try {
                return build(app, name)
            } catch (e: Exception) {
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

                    SecurePrefsPolicy.Action.REPORT_UNAVAILABLE -> {
                        Log.w(TAG, "store '$name' unavailable ($failure) — reporting, nothing destroyed", e)
                        throw SecurePrefsUnavailableException(name, failure, last)
                    }
                }
            }
        }
    }

    /** Files set aside by earlier builds, newest first. Surfaced so an explicit reset can
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
