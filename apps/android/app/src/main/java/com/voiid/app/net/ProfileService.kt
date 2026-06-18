package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Profile + username (the username is the Clips handle ONLY — not messaging
 * identity). Mirrors iOS ProfileService. Talks to /users/username-available and
 * /users/profile/update.
 */
@Serializable
data class UsernameAvailability(val available: Boolean, val reason: String? = null)

@Serializable
data class ProfileUser(
    val id: String,
    val full_name: String? = null,
    val email: String? = null,
    val photo_url: String? = null,
    val username: String? = null,
)
@Serializable
private data class ProfileEnvelope(val user: ProfileUser)

class ProfileService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    /** Live availability check for a candidate username (Clips handle). */
    suspend fun checkUsername(username: String): UsernameAvailability {
        val q = java.net.URLEncoder.encode(username, "UTF-8")
        return api.requestAs("GET", "users/username-available?username=$q")
    }

    /**
     * Save profile fields (any subset). Throws ApiError.Http(409) if the username
     * was taken between check and save.
     */
    suspend fun updateProfile(
        fullName: String? = null,
        email: String? = null,
        photoUrl: String? = null,
        bio: String? = null,
        username: String? = null,
    ): ProfileUser {
        val body = buildJsonObject {
            fullName?.let { put("full_name", it) }
            email?.let { put("email", it) }
            photoUrl?.let { put("photo_url", it) }
            bio?.let { put("bio", it) }
            username?.let { put("username", it) }
        }
        val env: ProfileEnvelope =
            api.requestAs("POST", "users/profile/update", jsonBody = body.toString())
        return env.user
    }
}
