package com.voiid.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import java.util.UUID

/**
 * Local, in-memory app state — port of iOS `Stores.swift` (NO network, NO crypto).
 * Everything is interactive: sending a message appends it, marks it sent→delivered→read on
 * timers, and simulates a reply, so the app *feels* real end-to-end on a device.
 */

// MARK: - Session / onboarding

enum class AppRoute { ONBOARDING, MAIN }

class AppSession : ViewModel() {
    var route by mutableStateOf(AppRoute.ONBOARDING)
        private set
    var profile by mutableStateOf(DummyData.me)

    /** Hides the bottom tab bar when a full-screen child (e.g. a chat) is open. */
    var hideTabBar by mutableStateOf(false)

    fun completeOnboarding() { route = AppRoute.MAIN }
    fun signOut() { route = AppRoute.ONBOARDING }
}

// MARK: - Chat store (the heart of the "feels real" experience)

class ChatStore : ViewModel() {
    val directConversations = mutableStateListOf<VConversation>().apply { addAll(DummyData.directConversations) }
    val groupConversations = mutableStateListOf<VConversation>().apply { addAll(DummyData.groupConversations) }
    private val messagesByConversation = mutableStateMapOf<String, androidx.compose.runtime.snapshots.SnapshotStateList<VMessage>>()
    val typingConversations = mutableStateListOf<String>()

    init {
        (directConversations + groupConversations).forEach { conv ->
            messagesByConversation[conv.id] = mutableStateListOf<VMessage>().apply { addAll(seed(conv.id)) }
        }
    }

    private fun seed(id: String): List<VMessage> =
        if (groupConversations.any { it.id == id }) DummyData.groupMessages(id) else DummyData.messages(id)

    fun messages(id: String): List<VMessage> = messagesByConversation[id] ?: emptyList()

    private fun list(id: String) = messagesByConversation.getOrPut(id) {
        mutableStateListOf<VMessage>().apply { addAll(seed(id)) }
    }

    /** Send a message — simulates the full lifecycle locally: sent → delivered → read, then a
     *  typing indicator and an auto-reply, so ticks, timestamps and typing all animate. */
    fun send(
        text: String,
        kind: MessageKind = MessageKind.TEXT,
        conversationId: String,
        replyTo: VMessage? = null,
        forwarded: Boolean = false,
    ) {
        val id = UUID.randomUUID().toString()
        val msg = VMessage(
            id = id, conversationId = conversationId, senderId = "me",
            kind = kind, text = text, createdAt = System.currentTimeMillis(),
            status = MessageStatus.SENDING, isMine = true,
            forwarded = forwarded,
            replyToSender = replyTo?.let { if (it.isMine) "You" else it.senderName.ifEmpty { "" } },
            replyToText = replyTo?.let { if (it.kind == MessageKind.TEXT) it.text else "Attachment" },
        )
        list(conversationId).add(msg)
        bumpPreview(conversationId, if (kind == MessageKind.TEXT) text else previewFor(kind))

        advance(id, conversationId, MessageStatus.SENT, 300)
        advance(id, conversationId, MessageStatus.DELIVERED, 1000)
        advance(id, conversationId, MessageStatus.READ, 2200)

        viewModelScope.launch { simulateReply(conversationId) }
    }

    private fun previewFor(kind: MessageKind): String = when (kind) {
        MessageKind.IMAGE -> "📷 Photo"
        MessageKind.VOICE -> "🎤 Voice message"
        MessageKind.DOCUMENT -> "📄 Document"
        else -> "Message"
    }

    private fun advance(messageId: String, convId: String, status: MessageStatus, delayMs: Long) {
        viewModelScope.launch {
            delay(delayMs)
            val arr = messagesByConversation[convId] ?: return@launch
            val idx = arr.indexOfFirst { it.id == messageId }
            if (idx < 0) return@launch
            val now = System.currentTimeMillis()
            arr[idx] = when (status) {
                MessageStatus.DELIVERED -> arr[idx].copy(status = status, deliveredAt = now)
                MessageStatus.READ -> arr[idx].copy(
                    status = status, readAt = now,
                    deliveredAt = arr[idx].deliveredAt ?: now,
                )
                else -> arr[idx].copy(status = status)
            }
        }
    }

    /** Forward a message to one or more conversations (with a Forwarded tag). */
    fun forward(message: VMessage, conversationIds: List<String>) {
        for (cid in conversationIds) {
            send(
                text = message.text,
                kind = if (message.kind == MessageKind.POLL) MessageKind.TEXT else message.kind,
                conversationId = cid,
                forwarded = true,
            )
        }
    }

    /** Delete a message. forEveryone=true leaves a "deleted" tombstone; otherwise removes it. */
    fun deleteMessage(messageId: String, convId: String, forEveryone: Boolean) {
        val arr = messagesByConversation[convId] ?: return
        val idx = arr.indexOfFirst { it.id == messageId }
        if (idx < 0) return
        if (forEveryone) {
            arr[idx] = arr[idx].copy(deletedForEveryone = true, reaction = null)
        } else {
            arr.removeAt(idx)
        }
    }

    /** Delete an entire conversation from the list. */
    fun deleteConversation(convId: String) {
        directConversations.removeAll { it.id == convId }
        groupConversations.removeAll { it.id == convId }
        messagesByConversation.remove(convId)
    }

    /** Clear all messages in a conversation but keep it in the list. */
    fun clearChat(convId: String) {
        messagesByConversation[convId]?.clear()
        val di = directConversations.indexOfFirst { it.id == convId }
        if (di >= 0) { directConversations[di] = directConversations[di].copy(lastMessagePreview = null); return }
        val gi = groupConversations.indexOfFirst { it.id == convId }
        if (gi >= 0) groupConversations[gi] = groupConversations[gi].copy(lastMessagePreview = null)
    }

    /** Toggle an emoji reaction on a message. */
    fun react(messageId: String, emoji: String, convId: String) {
        val arr = messagesByConversation[convId] ?: return
        val idx = arr.indexOfFirst { it.id == messageId }
        if (idx < 0) return
        arr[idx] = arr[idx].copy(reaction = if (arr[idx].reaction == emoji) null else emoji)
    }

    /** Send a poll into a conversation. */
    fun sendPoll(question: String, options: List<String>, conversationId: String) {
        val poll = VPoll(
            id = UUID.randomUUID().toString(), question = question,
            options = options.map { VPoll.Option(UUID.randomUUID().toString(), it, 0) },
        )
        val msg = VMessage(
            id = UUID.randomUUID().toString(), conversationId = conversationId, senderId = "me",
            kind = MessageKind.POLL, text = "Poll", createdAt = System.currentTimeMillis(),
            status = MessageStatus.SENT, isMine = true, poll = poll,
        )
        list(conversationId).add(msg)
        bumpPreview(conversationId, "📊 Poll: $question")
    }

    /** Register a vote on a poll option (single choice). */
    fun vote(messageId: String, optionId: String, conversationId: String) {
        val arr = messagesByConversation[conversationId] ?: return
        val mi = arr.indexOfFirst { it.id == messageId }
        if (mi < 0) return
        val poll = arr[mi].poll ?: return
        val updated = poll.copy(options = poll.options.map {
            if (it.id == optionId) it.copy(votes = it.votes + 1) else it
        })
        arr[mi] = arr[mi].copy(poll = updated)
    }

    private suspend fun simulateReply(convId: String) {
        delay(1400)
        if (!typingConversations.contains(convId)) typingConversations.add(convId)
        delay(1600)
        typingConversations.remove(convId)
        val replies = listOf("Yoooo", "Haha nice", "Whats good?", "On my way", "👍", "Let's do it")
        val reply = VMessage(
            id = UUID.randomUUID().toString(), conversationId = convId, senderId = "u4",
            text = replies.random(), createdAt = System.currentTimeMillis(), isMine = false,
        )
        list(convId).add(reply)
        bumpPreview(convId, reply.text)
    }

    private fun bumpPreview(convId: String, preview: String) {
        val now = System.currentTimeMillis()
        val di = directConversations.indexOfFirst { it.id == convId }
        if (di >= 0) {
            directConversations[di] = directConversations[di].copy(lastMessagePreview = preview, lastMessageAt = now)
            return
        }
        val gi = groupConversations.indexOfFirst { it.id == convId }
        if (gi >= 0) {
            groupConversations[gi] = groupConversations[gi].copy(lastMessagePreview = preview, lastMessageAt = now)
        }
    }
}

// MARK: - AI store

class AIStore : ViewModel() {
    val messages = mutableStateListOf<VAIMessage>().apply { addAll(DummyData.aiMessages) }
    var thinking by mutableStateOf(false)
        private set

    fun send(text: String) {
        messages.add(VAIMessage(id = UUID.randomUUID().toString(), text = text, isUser = true))
        viewModelScope.launch {
            thinking = true
            delay(1200)
            thinking = false
            messages.add(VAIMessage(id = UUID.randomUUID().toString(), text = "Whats good? How can i Help you today?", isUser = false))
        }
    }
}

// MARK: - Clips store

class ClipsStore : ViewModel() {
    val clips = mutableStateListOf<VClip>().apply { addAll(DummyData.clips) }
    val comments = mutableStateListOf<VClipComment>().apply { addAll(DummyData.clipComments) }

    fun toggleLike(clip: VClip) {
        val i = clips.indexOfFirst { it.id == clip.id }
        if (i >= 0) clips[i] = clips[i].copy(likes = clips[i].likes + 1)
    }

    fun addComment(text: String) {
        comments.add(0, VClipComment(id = UUID.randomUUID().toString(), authorName = "You", text = text))
    }
}
