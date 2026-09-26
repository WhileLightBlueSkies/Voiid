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
        set(v) {
            prefs.edit().apply { if (v == null) remove("jwt") else putString("jwt", v) }.apply()
            // Diagnostics: which KIND of credential is held (a 1h bootstrap vs a 30-day device
            // session) and when it expires. Claims only — the token itself is never logged.
            v?.let { android.util.Log.i("VoiidAuth", "token stored: ${describe(it)}") }
        }

    private fun describe(jwt: String): String = runCatching {
        val payload = String(android.util.Base64.decode(jwt.split(".")[1],
            android.util.Base64.URL_SAFE or android.util.Base64.NO_PADDING or android.util.Base64.NO_WRAP))
        val o = org.json.JSONObject(payload)
        "scope=${o.optString("scope", "legacy")} exp=${java.util.Date(o.optLong("exp") * 1000)}"
    }.getOrDefault("unparseable")

    var userId: String?
        get() = prefs.getString("user_id", null)
        set(v) { prefs.edit().apply { if (v == null) remove("user_id") else putString("user_id", v) }.apply() }

    val isAuthenticated: Boolean get() = jwt != null

    fun clear() {
        android.util.Log.w("VoiidAuth", "token cleared", Throwable("who cleared it"))
        prefs.edit().remove("jwt").remove("user_id").apply()
    }
}
