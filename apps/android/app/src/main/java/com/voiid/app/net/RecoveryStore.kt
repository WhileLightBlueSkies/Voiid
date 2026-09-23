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
        private const val KEY_DRIVE_ENABLED = "drive_backup_enabled"
    }

    private val prefs = SecurePrefs.open(context, "voiid_recovery")

    init {
        // Freeze migration before a restore saves its key: restoring must not opt into uploads.
        if (!prefs.contains("server_backup_enabled")) {
            check(prefs.edit().putBoolean("server_backup_enabled", prefs.contains(KEY_MASTER_SECRET)).commit())
        }
    }

    /** True once backup has been set up (or restored) on this device. */
    fun hasMasterSecret(): Boolean = prefs.contains(KEY_MASTER_SECRET)

    fun saveMasterSecret(secret: ByteArray) {
        require(secret.size == 32) { "Invalid backup key." }
        check(prefs.edit().putString(KEY_MASTER_SECRET, Base64.encodeToString(secret, Base64.NO_WRAP)).commit()) {
            "Couldn’t save the backup key on this device. Keep your recovery phrase and retry."
        }
    }

    /** The stored master secret, or null if backup was never set up on this device. */
    fun loadMasterSecret(): ByteArray? =
        prefs.getString(KEY_MASTER_SECRET, null)?.let { Base64.decode(it, Base64.NO_WRAP) }

    /** Whether the Google Drive backup destination is opted-in on THIS device (UX flag). */
    fun isDriveEnabled(): Boolean = prefs.getBoolean(KEY_DRIVE_ENABLED, false)

    fun setDriveEnabled(enabled: Boolean) {
        prefs.edit().putBoolean(KEY_DRIVE_ENABLED, enabled).apply()
    }

    fun isServerEnabled(): Boolean = prefs.getBoolean("server_backup_enabled", hasMasterSecret())
    fun setServerEnabled(enabled: Boolean) {
        check(prefs.edit().putBoolean("server_backup_enabled", enabled).commit())
    }

    fun pendingRestoreSource(): String? = prefs.getString("pending_restore_source", null)
    fun setPendingRestoreSource(source: String?) {
        check(prefs.edit().putString("pending_restore_source", source).commit())
    }

    fun clear() {
        prefs.edit().remove(KEY_MASTER_SECRET).remove(KEY_DRIVE_ENABLED).remove("server_backup_enabled").remove("pending_restore_source").apply()
    }
}
