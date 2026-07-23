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
// Backend returns a FLAT shape: direct → { conversation_id, existed }, group → { conversation_id }.
@Serializable private data class CreateConvEnvelope(val conversation_id: String, val existed: Boolean = false)
@Serializable private data class CreateGroupBody(val type: String = "group", val name: String, val member_ids: List<String>)

/** Resolved peer of a direct conversation. */
data class PeerInfo(val peerUserId: String?, val title: String?, val photoURL: String?)

/** One member of a group conversation (for GroupInfoView). */
data class GroupMemberInfo(val userId: String, val name: String, val photoURL: String?, val isYou: Boolean)

class ChatService(context: Context) {
    private val appContext = context.applicationContext
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)

    init { com.voiid.app.store.UserDirectory.init(appContext) }

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
        // Every peer resolution feeds the local directory, so a name is available offline and
        // on the call paths (a ring push carries no caller name — see UserDirectory). Server
        // fields only: the address-book name this may already hold is left untouched.
        com.voiid.app.store.UserDirectory.upsertFromServer(
            userId = peer.user_id, fullName = peer.full_name, photoUrl = peer.photo_url,
        )
        return PeerInfo(peer.user_id, peer.full_name ?: env.conversation.name, peer.photo_url)
    }

    /** Create (or fetch existing) a 1:1 conversation with [memberId]. Returns its id. */
    suspend fun createDirect(memberId: String): String {
        val body = """{"type":"direct","member_id":"$memberId"}"""
        val env: CreateConvEnvelope = api.requestAs("POST", "conversations/create", jsonBody = body)
        return env.conversation_id
    }

    /** Create a GROUP conversation container (mirrors [createDirect]). The MLS crypto
     *  group is built separately by GroupEngine.createGroup once this id exists. */
    suspend fun createGroup(name: String, memberIds: List<String>): String {
        val body = ApiClient.json.encodeToString(
            CreateGroupBody.serializer(),
            CreateGroupBody(name = name, member_ids = memberIds),
        )
        val env: CreateConvEnvelope = api.requestAs("POST", "conversations/create", jsonBody = body)
        return env.conversation_id
    }

    /** All members of a (group) conversation: user_id + display name + photo. */
    suspend fun fetchMembers(conversationId: String): List<GroupMemberInfo> {
        val env: ConvDetailEnvelope = api.requestAs("GET", "conversations/$conversationId")
        val myId = tokens.userId
        return env.members.map {
            com.voiid.app.store.UserDirectory.upsertFromServer(
                userId = it.user_id, fullName = it.full_name, photoUrl = it.photo_url,
            )
            GroupMemberInfo(it.user_id, it.full_name ?: "Member", it.photo_url, isYou = it.user_id == myId)
        }
    }

    /** Peer presence (online + last_seen epoch millis) from Redis-backed status. */
    suspend fun status(userId: String): PeerStatus {
        val env: StatusDTO = api.requestAs("GET", "users/status/$userId")
        return PeerStatus(env.online, env.last_seen?.toLong())
    }
}

@Serializable private data class StatusDTO(val online: Boolean = false, val last_seen: Double? = null)
data class PeerStatus(val online: Boolean, val lastSeen: Long?)
