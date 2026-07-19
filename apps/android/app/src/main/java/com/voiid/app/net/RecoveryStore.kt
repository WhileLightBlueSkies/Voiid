package com.voiid.app.net

import android.content.Context
import android.util.Base64

/**
 * Persists the 32-byte account master secret at rest in a dedicated
 * [EncryptedSharedPreferences] store (`voiid_recovery`), Base64-encoded — mirroring
 * how [E2EManager.pickleKey] stores its 32-byte key.
 *
 * The master secret is the root of the E2E backup: it seals/opens the backup blob
 * (encryptBackup/decryptBackup) and is itself wrapped-under-PIN on the server. We keep
 * a local copy so "Back up now", "View recovery phrase" and "Change PIN" work without
 * re-entering the PIN every time. It NEVER leaves the device except PIN-wrapped.
 */
class RecoveryStore private constructor(context: Context) {

    companion object {
        @Volatile private var instance: RecoveryStore? = null
        fun get(context: Context): RecoveryStore =
            instance ?: synchronized(this) {
                instance ?: RecoveryStore(context.applicationContext).also { instance = it }
            }

        private const val KEY_MASTER_SECRET = "master_secret"
    }

    private val prefs = SecurePrefs.open(context, "voiid_recovery")

    /** True once backup has been set up (or restored) on this device. */
    fun hasMasterSecret(): Boolean = prefs.contains(KEY_MASTER_SECRET)

    fun saveMasterSecret(secret: ByteArray) {
        prefs.edit().putString(KEY_MASTER_SECRET, Base64.encodeToString(secret, Base64.NO_WRAP)).apply()
    }

    /** The stored master secret, or null if backup was never set up on this device. */
    fun loadMasterSecret(): ByteArray? =
        prefs.getString(KEY_MASTER_SECRET, null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    fun clear() {
        prefs.edit().remove(KEY_MASTER_SECRET).apply()
    }
}
