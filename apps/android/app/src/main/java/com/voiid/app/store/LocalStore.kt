package com.voiid.app.store

import android.content.Context
import com.voiid.app.model.ConversationType
import com.voiid.app.model.VConversation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Disk persistence for the conversation list and for call history — port of iOS
 * `LocalStore.swift`, on top of [VoiidDatabase].
 *
 * READ PATH (the point of all this): the UI asks LocalStore first and renders immediately,
 * then a network sync updates the database and the UI follows. A failed fetch is therefore
 * invisible — you keep seeing your chats. Before this the conversation list existed ONLY as
 * the response body of a GET, so airplane mode (or one 500) produced an empty grid on top of
 * a full local message history.
 *
 * Messages are NOT duplicated here: [com.voiid.app.net.ChatEngine] already owns a durable
 * decrypted-message store on disk (with its own pending outbox), and a second copy would be
 * a second thing to keep in step. The `messages` table exists for the eventual migration of
 * that store; nothing writes it yet.
 *
 * TIME UNITS: columns hold epoch SECONDS (matching the iOS schema); the Android models use
 * epoch millis. Converted here, at the boundary, and nowhere else.
 */
object LocalStore {

    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private fun db(context: Context) = VoiidDatabase.get(context)

    // MARK: - Conversations

    /**
     * Every conversation we know about locally, newest activity first.
     *
     * Direct-chat titles are resolved through [UserDirectory] at READ time rather than being
     * stored: the address book is the authority for what a person is called, and resolving
     * late means renaming a contact updates every screen without a re-sync or a stale
     * denormalized copy.
     */
    suspend fun conversations(context: Context): List<VConversation> = withContext(Dispatchers.IO) {
        val rows = runCatching { db(context).conversations().recent() }.getOrDefault(emptyList())
        rows.map { r ->
            val isGroup = r.kind == "group"
            val peer = r.peerUserId
            val title = when {
                isGroup -> r.title?.takeIf { it.isNotBlank() } ?: "Group"
                // Never fall through to the raw id — that's the UUID-on-screen bug.
                peer != null -> UserDirectory.displayName(peer, fallback = r.title)
                else -> r.title ?: "Unknown"
            }
            VConversation(
                id = r.id,
                type = if (isGroup) ConversationType.GROUP else ConversationType.DIRECT,
                title = title,
                lastMessageAt = r.lastMessageAt?.let { it * 1000 },
                unreadCount = r.unreadCount,
                peerUserId = r.peerUserId,
                photoURL = r.photoUrl ?: r.peerUserId?.let { UserDirectory.photoUrl(it) },
            )
        }
    }

    /**
     * Persist a server sync result.
     *
     * Deliberately an UPSERT and not a replace-all: rows the server omits (a conversation
     * created on this device and not yet pushed) must survive a sync.
     */
    fun saveConversations(context: Context, convs: List<VConversation>) {
        if (convs.isEmpty()) return
        val now = System.currentTimeMillis() / 1000
        val rows = convs.map { c ->
            ConversationRow(
                id = c.id,
                kind = if (c.type == ConversationType.GROUP) "group" else "direct",
                title = c.title.takeIf { it.isNotBlank() },
                peerUserId = c.peerUserId,
                photoUrl = c.photoURL,
                lastMessageAt = c.lastMessageAt?.let { it / 1000 },
                unreadCount = c.unreadCount,
                updatedAt = now,
            )
        }
        scope.launch { runCatching { db(context).conversations().upsertAll(rows) } }
    }

    // MARK: - Call history
    //
    // New capability, not a port of anything: calls were live signaling only, so a missed
    // call left no trace anywhere in the app once the notification went away.

    /**
     * Record (or update) one call. Idempotent by [id] — the same call is written twice by
     * design: once when it starts ringing, so an ignored call is still on record if the
     * process dies, and again on teardown with the real outcome and end time.
     */
    fun recordCall(
        context: Context,
        id: String,
        conversationId: String?,
        peerUserId: String?,
        kind: String,
        direction: String,
        outcome: String,
        startedAtMs: Long,
        endedAtMs: Long? = null,
    ) {
        val row = CallHistoryRow(
            id = id,
            conversationId = conversationId,
            peerUserId = peerUserId,
            kind = kind,
            direction = direction,
            outcome = outcome,
            startedAt = startedAtMs / 1000,
            endedAt = endedAtMs?.let { it / 1000 },
        )
        scope.launch { runCatching { db(context).calls().record(row) } }
    }

    /** Recent calls, newest first. Names are resolved through [UserDirectory] by the caller. */
    suspend fun recentCalls(context: Context, limit: Int = 100): List<CallHistoryRow> =
        withContext(Dispatchers.IO) {
            runCatching { db(context).calls().recent(limit) }.getOrDefault(emptyList())
        }
}
