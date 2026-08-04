package com.voiid.app.net

import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.Serializable
import kotlinx.serialization.encodeToString
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import java.net.URLEncoder
import java.util.concurrent.TimeUnit

/**
 * Creator profiles + the follow graph (mirrors iOS `CreatorService.swift`).
 * Transport for backend/api/src/routes/creators.ts.
 *
 * ======================== NOT END-TO-END ENCRYPTED ========================
 * A creator profile is BROADCAST IDENTITY: the handle, display name, bio, avatar and
 * follower counts are shown to strangers and counted by the server. None of that is
 * expressible under E2EE. Nothing here shares a code path with messages, calls,
 * locations or moments — all of which remain E2EE.
 * =========================================================================
 *
 * ── A FOLLOW IS NOT A MESSAGING RIGHT ────────────────────────────────────
 * Nothing here may ever be used to authorise a conversation. Following someone lets you
 * watch their public clips and nothing else; the three paths in 020_reachability.sql
 * (mutual contact / one-way contact / @username + PIN) remain the only ways to open a
 * chat. If you find yourself reading a follow state to unlock messaging, that is a bug.
 */
class CreatorService(private val tokens: TokenStore) {
    private val api = ApiClient(tokens)
    private val json = ApiClient.json

    private val blobClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .writeTimeout(60, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .build()

    /**
     * Used ONLY for GET /creators/:handle, and the one thing that matters here is
     * `followRedirects(false)`.
     *
     * That endpoint signals a rename with a 301 whose body is `{ moved_to }` and which has
     * NO Location header. OkHttp follows redirects by default, so with the shared client the
     * 301 is never visible to us — it re-requests a header-less redirect and the rename hop
     * turns into an unexplained failure. The policy is scoped to this call rather than
     * changed on the shared client, which every other endpoint depends on.
     */
    private val noRedirectClient = OkHttpClient.Builder()
        .connectTimeout(15, TimeUnit.SECONDS)
        .readTimeout(30, TimeUnit.SECONDS)
        .followRedirects(false)
        .build()

    // ── DTOs ──────────────────────────────────────────────────────────────────────

    /**
     * The server's public profile shape. Note there is deliberately NO user_id: a profile
     * is public and a user_id is the key other endpoints authorise against, so the API
     * never hands it out. Follow/unfollow are keyed on the HANDLE for that reason.
     */
    @Serializable
    data class Profile(
        val handle: String,
        val display_name: String? = null,
        val bio: String? = null,
        val link_url: String? = null,
        /** Short-lived presigned GET, or null when R2 is unconfigured / the fetch failed. */
        val avatar_url: String? = null,
        val follower_count: Int = 0,
        val following_count: Int = 0,
        val clip_count: Int = 0,
        val is_verified: Boolean = false,
        val is_self: Boolean = false,
        val following: Boolean = false,
    )

    /**
     * `profile: null` is a 200, not a 404 — having no creator profile is the normal state
     * for the vast majority of users (they are here to message). Modelled as a nullable
     * rather than an error so no Clips screen has to open by handling a failure.
     */
    @Serializable private data class MeResp(val profile: Profile? = null)
    @Serializable private data class ProfileResp(val profile: Profile)

    @Serializable
    data class Availability(
        val available: Boolean = false,
        /** "format" | "taken" | null */
        val reason: String? = null,
    )

    @Serializable data class FollowResp(val following: Boolean, val follower_count: Int = 0)

    /**
     * A creator's grid row. Lighter than [ClipService.ClipRow] — the grid endpoints return
     * only what a tile draws, with no r2_key or playback URL.
     */
    @Serializable
    data class CreatorClipRow(
        val id: String,
        val thumb_r2_key: String? = null,
        val thumb_url: String? = null,
        val caption: String? = null,
        val duration_ms: Int? = null,
        val width: Int? = null,
        val height: Int? = null,
        val view_count: Int = 0,
        val like_count: Int = 0,
        val comment_count: Int = 0,
        val created_at: String,
        // Present only on the following feed, which joins the author's profile.
        val author_id: String? = null,
        val author_handle: String? = null,
        val author_display_name: String? = null,
        val author_verified: Boolean = false,
    )

    @Serializable
    data class ClipsResp(
        val clips: List<CreatorClipRow> = emptyList(),
        val next_cursor: String? = null,
    )

    @Serializable private data class CreateBody(
        val handle: String,
        val display_name: String? = null,
        val bio: String? = null,
        val link_url: String? = null,
    )
    @Serializable private data class UpdateBody(
        val handle: String? = null,
        val display_name: String? = null,
        val bio: String? = null,
        val link_url: String? = null,
    )
    @Serializable private data class AvatarPresignBody(val content_type: String)
    @Serializable data class AvatarPresignResp(val avatar_r2_key: String, val upload_url: String)
    @Serializable private data class AttachAvatarBody(val avatar_r2_key: String)
    @Serializable private data class MovedBody(val moved_to: String? = null)

    // ── Profile ───────────────────────────────────────────────────────────────────

    /** Your own profile, or null if you have none yet (the pre-gate state). */
    suspend fun me(): Profile? =
        json.decodeFromString<MeResp>(api.request("GET", "creators/me")).profile

    /**
     * Advisory availability check for the composer, so "taken" shows as you type rather
     * than at submit. ADVISORY ONLY — [create] re-checks under the real unique constraint,
     * because between this call and the insert someone else can take the name and only the
     * database can settle that race.
     */
    suspend fun handleAvailable(handle: String): Availability =
        json.decodeFromString(api.request("GET", "creators/handle-available?handle=${enc(handle)}"))

    /**
     * THE GATE. Creates the profile required before a first clip can be posted.
     * Throws [ApiError.Http] 409 when the handle is taken, 400 when malformed.
     */
    suspend fun create(
        handle: String,
        displayName: String?,
        bio: String?,
        linkUrl: String?,
    ): Profile = json.decodeFromString<ProfileResp>(
        api.request("POST", "creators",
            ApiClient.json.encodeToString(CreateBody(handle, displayName, bio, linkUrl)))
    ).profile

    /**
     * Edit. Every field is independently optional so changing a bio never re-sends a handle
     * the user did not touch — which matters because a handle change burns the 30-day
     * rename window (the server answers 429 if one was used recently).
     */
    suspend fun update(
        handle: String? = null,
        displayName: String? = null,
        bio: String? = null,
        linkUrl: String? = null,
    ): Profile = json.decodeFromString<ProfileResp>(
        api.request("PATCH", "creators/me",
            ApiClient.json.encodeToString(UpdateBody(handle, displayName, bio, linkUrl)))
    ).profile

    // ── Avatar ────────────────────────────────────────────────────────────────────

    suspend fun avatarPresign(contentType: String = "image/jpeg"): AvatarPresignResp =
        json.decodeFromString(
            api.request("POST", "creators/me/avatar-presign",
                ApiClient.json.encodeToString(AvatarPresignBody(contentType)))
        )

    /**
     * Attach an avatar already PUT to R2. Split from the presign so a failed upload never
     * points the profile at a key holding nothing.
     */
    suspend fun attachAvatar(key: String): Profile = json.decodeFromString<ProfileResp>(
        api.request("POST", "creators/me/avatar",
            ApiClient.json.encodeToString(AttachAvatarBody(key)))
    ).profile

    /**
     * The avatar is PLAINTEXT in R2 — it is a public profile picture, not message media, so
     * it deliberately skips the encryption [MediaService] applies.
     */
    suspend fun uploadAvatar(jpeg: ByteArray): Profile {
        val presign = avatarPresign()
        val req = Request.Builder()
            .url(presign.upload_url)
            .put(jpeg.toRequestBody("image/jpeg".toMediaType()))
            .build()
        val ok = try {
            blobClient.newCall(req).execute().use { it.isSuccessful }
        } catch (e: Exception) {
            throw ApiError.Transport(e)
        }
        if (!ok) throw ApiError.Http(0, "Avatar upload failed.")
        return attachAvatar(presign.avatar_r2_key)
    }

    // ── Public profiles ───────────────────────────────────────────────────────────

    /**
     * Public profile by handle, following ONE rename hop so links shared before a handle
     * change still resolve.
     *
     * The 301 carries `{ moved_to }` as a JSON body rather than a Location header, so OkHttp's
     * own redirect handling never sees it; it is read here with [ApiClient.requestRaw], since
     * the throwing client collapses a non-2xx body into a message string and loses the new
     * handle. Exactly one hop is followed: history can chain a→b→c, and looping until it
     * resolves would let a rename cycle hang the screen.
     */
    suspend fun profile(handle: String): Profile = withContext(Dispatchers.IO) {
        val token = tokens.jwt ?: throw ApiError.NotAuthenticated
        val req = Request.Builder()
            .url(ApiConfig.baseUrl.trimEnd('/') + "/" + ApiConfig.apiVersion +
                 "/creators/" + enc(handle))
            .header("Authorization", "Bearer $token")
            .header("X-Voiid-Platform", "android")
            .header("X-Voiid-App-Version", ApiConfig.appVersion)
            .header("X-Voiid-Api-Version", ApiConfig.apiVersion)
            .get()
            .build()
        val (code, text) = try {
            noRedirectClient.newCall(req).execute().use { it.code to (it.body?.string() ?: "") }
        } catch (e: Exception) {
            throw ApiError.Transport(e)
        }

        if (code in 200..299) return@withContext json.decodeFromString<ProfileResp>(text).profile
        if (code == 301) {
            val moved = runCatching { json.decodeFromString<MovedBody>(text).moved_to }.getOrNull()
            if (moved != null) {
                // The second hop goes through the shared client: it resolves or it genuinely
                // does not exist, and either way there is no further redirect to follow.
                return@withContext json.decodeFromString<ProfileResp>(
                    api.request("GET", "creators/${enc(moved)}")).profile
            }
        }
        val msg = runCatching { json.decodeFromString<ProfileErr>(text).error }.getOrNull()
        throw ApiError.Http(code, msg ?: "Profile unavailable ($code).")
    }

    @Serializable private data class ProfileErr(val error: String = "error")

    suspend fun clips(handle: String, cursor: String? = null, limit: Int = 30): ClipsResp {
        var path = "creators/${enc(handle)}/clips?limit=$limit"
        if (cursor != null) path += "&cursor=${enc(cursor)}"
        return json.decodeFromString(api.request("GET", path))
    }

    // ── Follow graph ──────────────────────────────────────────────────────────────

    /**
     * Idempotent server-side (`on conflict do nothing`), so a double-tap or a retry after a
     * dropped response neither errors nor double-counts. Returns the AUTHORITATIVE count —
     * the caller overwrites its optimistic number with it.
     */
    suspend fun follow(handle: String): FollowResp =
        json.decodeFromString(api.request("POST", "creators/${enc(handle)}/follow"))

    suspend fun unfollow(handle: String): FollowResp =
        json.decodeFromString(api.request("DELETE", "creators/${enc(handle)}/follow"))

    /**
     * Clips from creators you follow. Exposes only your OWN following set, which you already
     * know, so it leaks nothing about anyone else's graph.
     */
    suspend fun followingFeed(cursor: String? = null, limit: Int = 30): ClipsResp {
        var path = "creators/feed/following?limit=$limit"
        if (cursor != null) path += "&cursor=${enc(cursor)}"
        return json.decodeFromString(api.request("GET", path))
    }

    /**
     * Handles are `[a-z][a-z0-9_]{2,19}` so they need no escaping in practice, but a
     * hand-typed or pasted value reaches here before the server validates it.
     */
    private fun enc(s: String): String = URLEncoder.encode(s, "UTF-8")

    companion object {
        /**
         * Mirrors the server's HANDLE_RE. Checked client-side first so the obvious mistakes
         * ("Ab", "1abc", "a-b") never cost a round-trip and the field can explain itself as
         * the user types.
         */
        val HANDLE_RE = Regex("^[a-z][a-z0-9_]{2,19}$")
        fun isWellFormed(handle: String) = HANDLE_RE.matches(handle)
    }
}
