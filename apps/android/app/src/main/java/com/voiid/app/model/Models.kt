package com.voiid.app.model

/**
 * App models — the Kotlin port of the iOS `Models.swift`. For the dummy-frontend phase these
 * are populated with sample data (DummyData). Later hydrated from the backend + decrypted
 * locally via the crypto seam. UI always reads these models (local-first, Master Spec 11).
 *
 * Dates are epoch-millis (`Long`) for easy formatting via java.util.Calendar.
 */

data class VUser(
    val id: String,
    var fullName: String,
    var phoneNumber: String,
    var email: String? = null,
    var photoName: String? = null,
    var bio: String? = null,
    var statusText: String? = null,
    var isOnline: Boolean = false,
)

enum class MessageStatus { SENDING, SENT, DELIVERED, READ, FAILED }
enum class MessageKind { TEXT, IMAGE, VOICE, DOCUMENT, SYSTEM, POLL }

data class VMessage(
    val id: String,
    val conversationId: String,
    val senderId: String,
    val senderName: String = "",      // shown above incoming group bubbles
    val kind: MessageKind = MessageKind.TEXT,
    /** Decrypted text for display. On the wire this is opaque ciphertext (crypto seam). */
    val text: String,
    val createdAt: Long,
    val status: MessageStatus = MessageStatus.SENT,
    val isMine: Boolean = false,
    val poll: VPoll? = null,                  // set when kind == POLL
    val reaction: String? = null,             // single emoji reaction on this message
    val deliveredAt: Long? = null,            // for Message Info
    val readAt: Long? = null,                 // for Message Info
    val forwarded: Boolean = false,           // "Forwarded" tag
    val deletedForEveryone: Boolean = false,  // tombstone: "This message was deleted"
    // Quoted reply: snapshot of the replied-to message
    val replyToSender: String? = null,
    val replyToText: String? = null,
)

enum class ConversationType { DIRECT, GROUP }

data class VConversation(
    val id: String,
    val type: ConversationType,
    var title: String,
    var photoName: String? = null,
    var lastMessagePreview: String? = null,
    var lastMessageAt: Long? = null,
    var unreadCount: Int = 0,
    var memberCount: Int = 2,
    var isOnline: Boolean = false,
    /** Direct chats: the peer's user_id (needed to establish the E2E session). */
    var peerUserId: String? = null,
    /** Direct chats: peer avatar URL from members. */
    var photoURL: String? = null,
    /** Direct chats: peer's last-seen epoch millis (from presence), null if unknown/online. */
    var lastSeenAt: Long? = null,
)

data class VClip(
    val id: String,
    var authorName: String,
    var authorPhoto: String? = null,
    var heading: String,
    var caption: String,
    var likes: Int,
    var comments: Int,
    var thumbnailName: String? = null,
)

data class VClipComment(
    val id: String,
    var authorName: String,
    var authorPhoto: String? = null,
    var text: String,
)

data class VAIMessage(
    val id: String,
    var text: String,
    var isUser: Boolean,
)
