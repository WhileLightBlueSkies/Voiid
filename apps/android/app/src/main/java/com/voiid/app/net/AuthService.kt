package com.voiid.app.net

import android.content.Context
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
data class AuthResponse(val token: String, val user_id: String)

class AuthService(context: Context) {
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)

    val isAuthenticated: Boolean get() = tokens.isAuthenticated
    val userId: String? get() = tokens.userId

    /** Exchange a Firebase ID token for our JWT and persist it. */
    suspend fun loginWithFirebase(idToken: String): String {
        val body = ApiClient.json.encodeToString(
            FirebaseLoginBody.serializer(), FirebaseLoginBody(idToken)
        )
        val res: AuthResponse = api.requestAs("POST", "auth/firebase", jsonBody = body, auth = false)
        tokens.jwt = res.token
        tokens.userId = res.user_id
        return res.user_id
    }

    /** DEV ONLY: log in via the backend dev bypass (needs AUTH_DEV_BYPASS=1). */
    suspend fun devLogin(phoneE164: String): String = loginWithFirebase("dev:$phoneE164")

    fun logout() = tokens.clear()
}

@Serializable
private data class FirebaseLoginBody(val id_token: String)
