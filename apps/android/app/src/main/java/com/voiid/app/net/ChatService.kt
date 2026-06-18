package com.voiid.app.net

import android.content.Context
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.serialization.Serializable

/**
 * Real conversation data from the backend (replaces DummyData for the chat
 * list). Message content is E2EE — the server only stores ciphertext. Direct
 * chats are enriched (peer user_id + name + photo) from /conversations/:id so
 * the list shows the contact, not "Direct chat". Mirrors iOS ChatService.
 */
@Serializable
private data class ConvDTO(
    val id: String,
    val type: String,
    val name: String? = null,
    val photo_url: String? = null,
    val last_message_at: String? = null,
    val last_ciphertext: String? = null,
    val unread_count: Int = 0,
)
@Serializable
private data class ConversationsEnvelope(val conversations: List<ConvDTO>)

@Serializable private data class ConvDetailDTO(val id: String, val type: String, val name: String? = null)
@Serializable private data class MemberDTO(val user_id: String, val full_name: String? = null, val photo_url: String? = null)
@Serializable private data class ConvDetailEnvelope(val conversation: ConvDetailDTO, val members: List<MemberDTO>)
@Serializable private data class CreatedConvDTO(val id: String, val type: String, val name: String? = null)
@Serializable private data class CreateConvEnvelope(val conversation: CreatedConvDTO)

/** Resolved peer of a direct conversation. */
data class PeerInfo(val peerUserId: String?, val title: String?, val photoURL: String?)

class ChatService(context: Context) {
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)

    /** Fetch the user's real conversations, then enrich direct chats (peer) concurrently. */
    suspend fun fetchConversations(): List<VConversation> = coroutineScope {
        val env: ConversationsEnvelope = api.requestAs("GET", "conversations")
        val convs = env.conversations.map { c ->
            VConversation(
                id = c.id,
                type = if (c.type == "group") ConversationType.GROUP else ConversationType.DIRECT,
                title = c.name ?: "Direct chat",
                lastMessagePreview = if (c.last_ciphertext == null) null else "Encrypted message",
                lastMessageAt = null,
                unreadCount = c.unread_count,
            )
        }
        // Resolve peers for direct chats concurrently.
        val jobs = convs.map { conv ->
            async {
                if (conv.type != ConversationType.DIRECT) return@async conv
                val peer = runCatching { resolvePeer(conv.id) }.getOrNull() ?: return@async conv
                conv.copy(
                    title = peer.title?.takeIf { it.isNotEmpty() } ?: conv.title,
                    peerUserId = peer.peerUserId,
                    photoURL = peer.photoURL,
                )
            }
        }
        jobs.map { it.await() }
    }

    /** Resolve a direct conversation's peer (the other member). */
    suspend fun resolvePeer(conversationId: String): PeerInfo {
        val env: ConvDetailEnvelope = api.requestAs("GET", "conversations/$conversationId")
        val myId = tokens.userId
        val peer = env.members.firstOrNull { it.user_id != myId }
            ?: return PeerInfo(null, env.conversation.name, null)
        return PeerInfo(peer.user_id, peer.full_name ?: env.conversation.name, peer.photo_url)
    }

    /** Create (or fetch existing) a 1:1 conversation with [memberId]. Returns its id. */
    suspend fun createDirect(memberId: String): String {
        val body = """{"type":"direct","member_id":"$memberId"}"""
        val env: CreateConvEnvelope = api.requestAs("POST", "conversations/create", jsonBody = body)
        return env.conversation.id
    }

    /** Peer presence (online + last_seen epoch millis) from Redis-backed status. */
    suspend fun status(userId: String): PeerStatus {
        val env: StatusDTO = api.requestAs("GET", "users/status/$userId")
        return PeerStatus(env.online, env.last_seen?.toLong())
    }
}

@Serializable private data class StatusDTO(val online: Boolean = false, val last_seen: Double? = null)
data class PeerStatus(val online: Boolean, val lastSeen: Long?)
