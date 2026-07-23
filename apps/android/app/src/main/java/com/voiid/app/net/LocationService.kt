package com.voiid.app.net

import android.content.Context
import kotlinx.serialization.Serializable

/**
 * The six location-share HTTP endpoints (docs/LOCATION.md §9). This is the ONLY place a share
 * is created/ended server-side; the WebSocket relay has no database, so membership validation
 * and abuse rate-limiting live here. NO coordinate is ever a field on any of these — the server
 * additionally runs `assertNoCoordinates` on every body and rejects one structurally.
 *
 * The share KEY appears in neither request nor response: authorization happens by distributing
 * the key over the E2EE message path, which the server never sees.
 */
class LocationService(context: Context) {

    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)

    companion object {
        const val KIND_CONVERSATION = "conversation"
        const val KIND_MAP = "map"
    }

    /** Create a share → (share_id, expires_at ISO). Auto-ends any prior active share with the
     *  same (owner, kind, conversation). */
    suspend fun createShare(
        kind: String,
        conversationId: String?,
        targetUserIds: List<String>,
        durationSeconds: Int,
    ): CreateShareResponse {
        val body = ApiClient.json.encodeToString(
            CreateShareBody.serializer(),
            CreateShareBody(kind, conversationId, targetUserIds, durationSeconds),
        )
        return api.requestAs("POST", "location/shares", jsonBody = body)
    }

    /** Active, unexpired, unrevoked shares — how a relinked device discovers a live outbound
     *  share instead of broadcasting silently forever. */
    suspend fun listShares(): SharesResponse =
        api.requestAs("GET", "location/shares")

    suspend fun extendShare(shareId: String, durationSeconds: Int): ExtendResponse {
        val body = ApiClient.json.encodeToString(
            ExtendBody.serializer(), ExtendBody(durationSeconds),
        )
        return api.requestAs("POST", "location/shares/$shareId/extend", jsonBody = body)
    }

    /** Owner ends a share (idempotent). Also publishes loc_stop to every target and hdels the
     *  last-fix buffer server-side. */
    suspend fun endShare(shareId: String) {
        api.request("DELETE", "location/shares/$shareId")
    }

    /** Owner revokes one recipient. Caller then sends live_stop to that recipient and a
     *  live_rekey (fresh key) to the remaining audience. */
    suspend fun revokeTarget(shareId: String, userId: String) {
        api.request("DELETE", "location/shares/$shareId/targets/$userId")
    }

    /** A recipient stops seeing a share without asking the owner. */
    suspend fun leaveShare(shareId: String) {
        api.request("POST", "location/shares/$shareId/leave")
    }

    /** Member user ids of a group conversation — the audience for a group live share (the
     *  createShare endpoint requires every target to be an active member). */
    suspend fun conversationMemberIds(conversationId: String): List<String> =
        runCatching {
            val env: ConvMembersResponse = api.requestAs("GET", "conversations/$conversationId")
            env.members.map { it.user_id }
        }.getOrDefault(emptyList())

    @Serializable private data class ConvMemberDTO(val user_id: String)
    @Serializable private data class ConvMembersResponse(val members: List<ConvMemberDTO> = emptyList())

    // MARK: - DTOs

    @Serializable
    private data class CreateShareBody(
        val kind: String,
        val conversation_id: String? = null,
        val target_user_ids: List<String>,
        val duration_seconds: Int,
    )

    @Serializable
    data class CreateShareResponse(
        val share_id: String,
        val kind: String? = null,
        val conversation_id: String? = null,
        val expires_at: String,
        val target_count: Int = 0,
    )

    @Serializable private data class ExtendBody(val duration_seconds: Int)
    @Serializable data class ExtendResponse(val share_id: String? = null, val expires_at: String)

    @Serializable
    data class OutboundShareDTO(
        val share_id: String,
        val kind: String,
        val conversation_id: String? = null,
        val started_at: String,
        val expires_at: String,
        val target_user_ids: List<String> = emptyList(),
    )

    @Serializable
    data class InboundShareDTO(
        val share_id: String,
        val kind: String,
        val conversation_id: String? = null,
        val owner_user_id: String,
        val started_at: String,
        val expires_at: String,
    )

    @Serializable
    data class SharesResponse(
        val outbound: List<OutboundShareDTO> = emptyList(),
        val inbound: List<InboundShareDTO> = emptyList(),
    )
}
