package com.voiid.app.net

import android.content.Context
import android.content.SharedPreferences
import android.util.Log
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import java.security.KeyStore

/**
 * Opens [EncryptedSharedPreferences] resiliently.
 *
 * On reinstall / device-restore the old encrypted prefs file (and its embedded Tink
 * keyset) can survive — e.g. via Android auto-backup — while the Keystore master key
 * that wrapped it does NOT (Keystore keys never leave the device). Decryption then
 * throws `AEADBadTagException` / `KeyStoreException` and, because these stores are
 * built during startup, the app crashes on launch.
 *
 * Recovery is deliberately surgical: we delete only the unreadable prefs file and
 * rebuild it against the device's CURRENT (valid) master key. We do NOT delete the
 * master key on this path — all of our stores ([TokenStore], [ChatEngine],
 * [E2EManager]) share one androidx master key, so dropping it here would invalidate
 * the keysets sibling stores just rebuilt and trigger a reset cascade on every
 * launch. Only if the rebuild itself fails (the master key entry is genuinely
 * unusable) do we fall back to regenerating the key.
 *
 * The lost data is unrecoverable ciphertext anyway: the user simply re-authenticates
 * and the E2E identity / sessions re-establish.
 */
internal object SecurePrefs {

    private const val TAG = "SecurePrefs"

    fun open(ctx: Context, name: String): SharedPreferences {
        val app = ctx.applicationContext
        return try {
            build(app, name)
        } catch (e: Exception) {
            Log.w(TAG, "Encrypted prefs '$name' unreadable; wiping and rebuilding", e)
            // Also log under VOIID so it surfaces in the app log filter — wiping
            // 'voiid_chat' here destroys the local message history (the cause of
            // "old messages gone / can't be decrypted" after a restart).
            Log.e("VOIID", "🧨 WIPING encrypted prefs '$name' (${e.javaClass.simpleName}) — local data for this store is lost")
            app.deleteSharedPreferences(name)
            try {
                build(app, name)
            } catch (e2: Exception) {
                // Master key itself is unusable — drop it and rebuild from scratch.
                Log.w(TAG, "Rebuild of '$name' failed; resetting master key", e2)
                deleteMasterKey()
                app.deleteSharedPreferences(name)
                build(app, name)
            }
        }
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

    private fun deleteMasterKey() {
        runCatching {
            KeyStore.getInstance("AndroidKeyStore")
                .apply { load(null) }
                .deleteEntry(MasterKey.DEFAULT_MASTER_KEY_ALIAS)
        }
    }
}
