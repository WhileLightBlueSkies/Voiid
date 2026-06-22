package com.voiid.app.net

import android.content.Context
import android.content.SharedPreferences

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
                instance ?: TokenStore(SecurePrefs.open(context, "voiid_auth")).also { instance = it }
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
