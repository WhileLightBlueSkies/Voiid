package com.voiid.app.net

import android.content.Context
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import kotlinx.serialization.Serializable

/**
 * Real conversation data from the backend (replaces DummyData for the chat
 * list). Message content is E2EE — the server only stores ciphertext, so the
 * last-message preview is a placeholder until the message layer (decrypt via
 * e2e-core) is wired. Direct-chat titles need contact resolution (contacts
 * feature); until then we fall back gracefully. Mirrors iOS ChatService.
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

class ChatService(context: Context) {
    private val api = ApiClient(TokenStore.get(context))

    /** Fetch the user's real conversations. Empty for a new account — that empty
     *  state confirms the list is reading the live backend (not mock). */
    suspend fun fetchConversations(): List<VConversation> {
        val env: ConversationsEnvelope = api.requestAs("GET", "conversations")
        return env.conversations.map { c ->
            VConversation(
                id = c.id,
                type = if (c.type == "group") ConversationType.GROUP else ConversationType.DIRECT,
                title = c.name ?: "Direct chat",   // TODO: resolve from contact (contacts feature)
                lastMessagePreview = if (c.last_ciphertext == null) null else "Encrypted message",
                lastMessageAt = null,              // TODO: parse ISO8601 when previews are wired
                unreadCount = c.unread_count,
            )
        }
    }
}
