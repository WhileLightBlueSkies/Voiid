package com.voiid.app.net

import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.Serializable

/**
 * HTTP client for the Map's server-side share rows (kind='map') — docs/LOCATION.md §9.
 *
 * The server stores ONLY that a share exists, who it is with, and when it ends. No coordinate,
 * no key, no ciphertext, no last-seen, no update count ever reaches it — the backend's
 * `assertNoCoordinates` guard rejects a body carrying any of those. The share key appears in
 * neither request nor response; it travels E2E over the ratchet as a `map_key` control message.
 *
 * Why store even this much: (a) the WS process has no DB, so `POST /shares` is the only place
 * conversation membership is validated and abuse rate-limited; (b) it lets a reinstalled device
 * discover "you still have an outbound share running — stop it" rather than broadcasting dark
 * forever. The honest metadata cost is disclosed in the Map explainer (§6).
 */
class MapPresenceService(private val tokens: TokenStore) {
    private val api = ApiClient(tokens)

    @Serializable
    private data class CreateBody(
        // @EncodeDefault is LOAD-BEARING: ApiClient's Json has `encodeDefaults = false` (the
        // kotlinx default), so a property left at its default value is OMITTED from the request
        // body. Without this annotation `kind` never reached the server and every Map
        // "go visible" failed with 400 `kind must be 'conversation' or 'map'`, surfacing as
        // "Couldn't start sharing your location. Check your connection and try again." — which
        // pointed at the network and hid a serialization bug.
        @EncodeDefault val kind: String = "map",
        val target_user_ids: List<String>,
        val duration_seconds: Long,
    )

    @Serializable data class CreateResp(val share_id: String, val expires_at: String? = null)
    @Serializable private data class ExtendBody(val duration_seconds: Long)
    @Serializable data class ExtendResp(val expires_at: String? = null)

    /**
     * Open (or replace) the Map presence share. The server auto-ends any prior active share
     * with the same (owner, kind='map'), so re-opening after an audience change is one call.
     * [durationSeconds] is capped at 24 h server-side (the hard auto-ghost, §3).
     */
    suspend fun create(targetUserIds: List<String>, durationSeconds: Long): CreateResp {
        val body = ApiClient.json.encodeToString(
            CreateBody.serializer(),
            CreateBody(target_user_ids = targetUserIds, duration_seconds = durationSeconds),
        )
        return api.requestAs("POST", "location/shares", jsonBody = body)
    }

    /** Extend an active Map share (owner only). Used by the auto-ghost refresh on foreground. */
    suspend fun extend(shareId: String, durationSeconds: Long): ExtendResp {
        val body = ApiClient.json.encodeToString(ExtendBody.serializer(), ExtendBody(durationSeconds))
        return api.requestAs("POST", "location/shares/$shareId/extend", jsonBody = body)
    }

    /**
     * End the share (owner only). The server publishes a `loc_stop` routing signal to every
     * target and hdel's the last-fix buffer, so a stopped share can never be resurrected from
     * the relay buffer on reconnect. Idempotent — a repeated stop re-publishes harmlessly.
     */
    suspend fun delete(shareId: String) {
        runCatching { api.request("DELETE", "location/shares/$shareId") }
    }

    /** Revoke ONE recipient (owner only). Follow with a fresh map_key to the remaining audience. */
    suspend fun revokeTarget(shareId: String, userId: String) {
        runCatching { api.request("DELETE", "location/shares/$shareId/targets/$userId") }
    }
}
