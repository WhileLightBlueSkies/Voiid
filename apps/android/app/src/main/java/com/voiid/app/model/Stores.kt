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
            messagesByConversation[conv.id] = mutableStateListOf<VMessage>().apply { addAll(DummyData.messages(conv.id)) }
        }
    }

    fun messages(id: String): List<VMessage> = messagesByConversation[id] ?: emptyList()

    private fun list(id: String) = messagesByConversation.getOrPut(id) {
        mutableStateListOf<VMessage>().apply { addAll(DummyData.messages(id)) }
    }

    /** Send a message — simulates the full lifecycle locally: sent → delivered → read, then a
     *  typing indicator and an auto-reply, so ticks, timestamps and typing all animate. */
    fun send(text: String, kind: MessageKind = MessageKind.TEXT, conversationId: String) {
        val id = UUID.randomUUID().toString()
        val msg = VMessage(
            id = id, conversationId = conversationId, senderId = "me",
            kind = kind, text = text, createdAt = System.currentTimeMillis(),
            status = MessageStatus.SENDING, isMine = true,
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
            if (idx >= 0) arr[idx] = arr[idx].copy(status = status)
        }
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
