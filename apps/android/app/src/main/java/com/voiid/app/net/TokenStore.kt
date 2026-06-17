package com.voiid.app.net

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey

/**
 * Secure storage for OUR JWT + user id, mirroring iOS TokenStore (Keychain).
 * Backed by EncryptedSharedPreferences (hardware-backed master key via Keystore).
 * The e2e-core pickle keys get their own encrypted entries elsewhere.
 */
class TokenStore private constructor(private val prefs: SharedPreferences) {

    companion object {
        @Volatile private var instance: TokenStore? = null

        fun get(context: Context): TokenStore =
            instance ?: synchronized(this) {
                instance ?: create(context.applicationContext).also { instance = it }
            }

        private fun create(ctx: Context): TokenStore {
            val masterKey = MasterKey.Builder(ctx)
                .setKeyScheme(MasterKey.KeyScheme.AES256_GCM)
                .build()
            val prefs = EncryptedSharedPreferences.create(
                ctx,
                "voiid_auth",
                masterKey,
                EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
                EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
            )
            return TokenStore(prefs)
        }
    }

    var jwt: String?
        get() = prefs.getString("jwt", null)
        set(v) { prefs.edit().apply { if (v == null) remove("jwt") else putString("jwt", v) }.apply() }

    var userId: String?
        get() = prefs.getString("user_id", null)
        set(v) { prefs.edit().apply { if (v == null) remove("user_id") else putString("user_id", v) }.apply() }

    val isAuthenticated: Boolean get() = jwt != null

    fun clear() {
        prefs.edit().remove("jwt").remove("user_id").apply()
    }
}
