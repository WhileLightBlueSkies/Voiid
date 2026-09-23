package com.voiid.app.net

import android.content.Context
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.serialization.Serializable

/**
 * Auth flow (mirrors iOS AuthService):
 *  1. App verifies the phone via Firebase Phone Auth (client SDK) → Firebase ID token.
 *  2. POST that token to /auth/firebase → server returns OUR JWT (stored encrypted).
 *  3. All API calls then use our JWT.
 *
 * Until the Firebase SDK is wired in, [devLogin] uses the backend dev bypass
 * ("dev:<phone>") so the flow is testable now.
 */
@Serializable
data class AuthResponse(val token: String, val user_id: String, val profile_complete: Boolean = false)

class AuthService(context: Context) {
    private val completion = context.applicationContext.getSharedPreferences("voiid_onboarding_completion", Context.MODE_PRIVATE)
    fun needsRecovery(): Boolean = isAuthenticated && !completion.getBoolean("ready.${userId}", false)
    fun finishRecovery() { check(completion.edit().putBoolean("ready.${userId}", true).commit()) }

    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)

    val isAuthenticated: Boolean get() = tokens.isAuthenticated
    val userId: String? get() = tokens.userId

    /** Exchange a Firebase ID token for our JWT and persist it. */
    /** Returns profile_complete (true = returning user; skip Signup/Profile). */
    suspend fun loginWithFirebase(idToken: String): Boolean {
        val body = ApiClient.json.encodeToString(
            FirebaseLoginBody.serializer(), FirebaseLoginBody(idToken)
        )
        val res: AuthResponse = api.requestAs("POST", "auth/firebase", jsonBody = body, auth = false)
        check(completion.edit().putBoolean("ready.${res.user_id}", !res.profile_complete).commit())
        tokens.jwt = res.token
        tokens.userId = res.user_id
        return res.profile_complete
    }

    /** DEV ONLY: log in via the backend dev bypass (needs AUTH_DEV_BYPASS=1).
     *  Returns profile_complete (true = returning user; skip Signup/Profile). */
    suspend fun devLogin(phoneE164: String): Boolean = loginWithFirebase("dev:$phoneE164")

    /**
     * End the session on the SERVER, then locally.
     *
     * Clearing local storage alone left the JWT valid for the rest of its 30 days: anyone
     * who recovered it could still send, fetch and upload keys as this device. The server
     * now revokes the device session, drops its prekeys and closes its socket.
     *
     * Local state is cleared FIRST and synchronously, so the UI can route to onboarding
     * immediately and a user with no network still ends up logged out. The revoke is
     * therefore fired with the credential captured by value — reading it back from the
     * store would find nothing, and the session would live out its full 30 days.
     *
     * Best-effort by design: if it never lands, the device remains revocable from the
     * linked-devices screen on another device.
     */
    fun logout() {
        val credential = tokens.jwt
        tokens.clear()
        if (credential == null) return
        CoroutineScope(Dispatchers.IO).launch {
            runCatching { api.request("POST", "auth/logout", bearer = credential) }
        }
    }
}

@Serializable
private data class FirebaseLoginBody(val id_token: String)
