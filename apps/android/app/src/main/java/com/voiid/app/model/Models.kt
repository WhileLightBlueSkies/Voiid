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
    /** Remote avatar: an R2 object key (resolved through a presigned GET), or an absolute URL. */
    var photoURL: String? = null,
    /** Clips handle (@username), fetched from the server profile. */
    var username: String? = null,
    var bio: String? = null,
    var statusText: String? = null,
    var isOnline: Boolean = false,
)

enum class MessageStatus { SENDING, SENT, DELIVERED, READ, FAILED }
enum class MessageKind { TEXT, IMAGE, VOICE, DOCUMENT, SYSTEM, POLL, LOCATION, CALL }

/**
 * A finished call, rendered as a bubble in the transcript (WhatsApp/Signal style).
 *
 * NOT a message and never sent over the wire. Both endpoints already learn the outcome from
 * the signaling they exchanged, so each side renders this from its OWN local `call_history`
 * row — exactly how Signal and WhatsApp do it. Sending a log message instead would add a
 * failure mode (caller dies mid-call → no log for anyone) and a second source of truth for
 * something both sides already know.
 */
data class VCallLog(
    val callId: String,
    val isVideo: Boolean,
    val incoming: Boolean,
    /** answered | missed | declined | failed — the vocabulary written by CallService. */
    val outcome: String,
    val startedAt: Long,
    val endedAt: Long?,
) {
    val answered: Boolean get() = outcome == "answered"
    /** Seconds of connected time; null unless the call was actually answered. */
    val durationSeconds: Long?
        get() = if (answered && endedAt != null) ((endedAt - startedAt) / 1000).coerceAtLeast(0) else null
}

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
    /** For media messages (IMAGE/VOICE): the E2EE ref used to fetch + decrypt the blob. */
    val mediaRef: com.voiid.app.net.ChatEngine.MediaRef? = null,
    /** For LOCATION messages: the keyless pin / live_start projection (docs/LOCATION.md §4). */
    val location: com.voiid.app.net.ChatEngine.LocationRef? = null,
    /** Set when kind == CALL: the finished call this bubble reports. Local-only. */
    val call: VCallLog? = null,
)

/**
 * SELF is Note to Self — your own private scratchpad. One member (you), and its OWN type so
 * it can never satisfy the "exactly two members" lookup that identifies a real 1:1.
 * Mirrors iOS `ConversationType`.
 */
enum class ConversationType { DIRECT, GROUP, SELF }

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

// VClip / VClipComment removed — the mock shapes for the dummy Clips feed. The real
// models live in model/ClipsStore.kt, built from the server rows in net/ClipService.kt.

data class VAIMessage(
    val id: String,
    var text: String,
    var isUser: Boolean,
)
