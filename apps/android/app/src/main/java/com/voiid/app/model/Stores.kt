package com.voiid.app.model

import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateListOf
import androidx.compose.runtime.mutableStateMapOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import android.app.Application
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.voiid.app.net.AuthService
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

class AppSession(app: Application) : AndroidViewModel(app) {
    val auth = AuthService(app)

    // Resume straight to the app if we already hold a session token.
    var route by mutableStateOf(if (auth.isAuthenticated) AppRoute.MAIN else AppRoute.ONBOARDING)
        private set
    var profile by mutableStateOf(DummyData.me)

    /** Hides the bottom tab bar when a full-screen child (e.g. a chat) is open. */
    var hideTabBar by mutableStateOf(false)

    /** The authenticated user's id (our backend id), once logged in. */
    val userId: String? get() = auth.userId

    /** Called at the end of onboarding once a real session token exists. */
    fun completeOnboarding() { route = AppRoute.MAIN }

    fun signOut() {
        auth.logout()
        route = AppRoute.ONBOARDING
    }
}

// MARK: - Chat store (the heart of the "feels real" experience)

class ChatStore(app: Application) : AndroidViewModel(app) {
    // REAL backend data — starts empty, loaded via loadConversations(). A new
    // account shows an empty list, confirming we read the live server (not mock).
    val directConversations = mutableStateListOf<VConversation>()
    val groupConversations = mutableStateListOf<VConversation>()
    private val messagesByConversation = mutableStateMapOf<String, androidx.compose.runtime.snapshots.SnapshotStateList<VMessage>>()
    val typingConversations = mutableStateListOf<String>()
    var loadError by mutableStateOf<String?>(null)

    private val chatService = com.voiid.app.net.ChatService(app)
    private val engine = com.voiid.app.net.ChatEngine.get(app)
    private val ws = com.voiid.app.net.WebSocketClient.get(app)
    private var realtimeInstalled = false

    /** Fetch real conversations from the backend + install realtime handlers. */
    fun loadConversations() {
        startRealtime()
        viewModelScope.launch {
            try {
                val convs = chatService.fetchConversations()
                directConversations.clear(); groupConversations.clear()
                directConversations.addAll(convs.filter { it.type == ConversationType.DIRECT })
                groupConversations.addAll(convs.filter { it.type == ConversationType.GROUP })
                convs.forEach { refresh(it.id) }   // show cached (already-decrypted) messages
                loadError = null
            } catch (e: Exception) {
                loadError = (e as? com.voiid.app.net.ApiError)?.message ?: "Couldn’t load chats."
            }
        }
    }

    fun messages(id: String): List<VMessage> = messagesByConversation[id] ?: emptyList()

    private fun list(id: String) = messagesByConversation.getOrPut(id) { mutableStateListOf() }

    /** Open a conversation: show cached, then sync (fetch + decrypt-new) from server. */
    fun openConversation(conv: VConversation) {
        refresh(conv.id)
        viewModelScope.launch { syncMessages(conv) }
    }

    private suspend fun syncMessages(conv: VConversation) {
        if (conv.type != ConversationType.DIRECT) return   // group E2E (MLS) is a later increment
        try {
            val peer = peerUserId(conv)
            engine.sync(conv.id, peer)
            refresh(conv.id)
            engine.markRead(conv.id)            // blue ticks for the sender
            fetchPresence(conv.id, peer)
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.message ?: "Couldn’t load messages."
        }
    }

    /** Fetch + apply the peer's online/last-seen presence to the conversation. */
    suspend fun fetchPresence(convId: String, peerUserId: String) {
        val st = runCatching { chatService.status(peerUserId) }.getOrNull() ?: return
        val i = directConversations.indexOfFirst { it.id == convId }
        if (i >= 0) directConversations[i] = directConversations[i].copy(isOnline = st.online, lastSeenAt = st.lastSeen)
    }

    /** Apply a delivery/read receipt (WS) to one of our sent messages → tick color. */
    private fun applyReceipt(messageId: String, status: String) {
        val newStatus = if (status == "read") MessageStatus.READ else MessageStatus.DELIVERED
        for ((_, arr) in messagesByConversation) {
            val idx = arr.indexOfFirst { it.id == messageId && it.isMine }
            if (idx >= 0) {
                if (!(arr[idx].status == MessageStatus.READ && newStatus == MessageStatus.DELIVERED)) {
                    arr[idx] = arr[idx].copy(status = newStatus)
                }
                return
            }
        }
    }

    /** Rebuild a conversation's UI messages from the local (decrypted) store. */
    private fun refresh(convId: String) {
        val mapped = engine.messages(convId).map { d ->
            VMessage(
                id = d.id, conversationId = convId,
                senderId = if (d.isMine) "me" else d.senderId,
                kind = MessageKind.TEXT, text = d.text, createdAt = d.createdAt,
                status = if (d.isMine) MessageStatus.SENT else MessageStatus.READ,
                isMine = d.isMine,
            )
        }
        if (mapped.isNotEmpty() || messagesByConversation.containsKey(convId)) {
            val arr = list(convId)
            arr.clear(); arr.addAll(mapped)
        }
        mapped.lastOrNull()?.let { bumpPreview(convId, it.text) }
    }

    /** Resolve + cache the peer user_id for a direct conversation. */
    private suspend fun peerUserId(conv: VConversation): String {
        conv.peerUserId?.let { return it }
        val di = directConversations.indexOfFirst { it.id == conv.id }
        if (di >= 0) directConversations[di].peerUserId?.let { return it }
        val resolved = chatService.resolvePeer(conv.id)
        val peer = resolved.peerUserId ?: throw com.voiid.app.net.ApiError.Http(404, "no peer")
        if (di >= 0) directConversations[di] = directConversations[di].copy(peerUserId = peer)
        return peer
    }

    /** Start (or reopen) a 1:1 chat with a discovered contact; returns it for navigation. */
    suspend fun startDirectChat(contact: com.voiid.app.net.VContact): VConversation? {
        return try {
            val convId = chatService.createDirect(contact.userId)
            directConversations.firstOrNull { it.id == convId }?.let { return it }
            val conv = VConversation(
                id = convId, type = ConversationType.DIRECT, title = contact.displayName,
                peerUserId = contact.userId, photoURL = contact.photoURL,
            )
            directConversations.add(0, conv)
            conv
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.message ?: "Couldn’t start chat."
            null
        }
    }

    /** Send a real E2EE message in a direct chat. Groups keep a local echo for now. */
    fun send(
        text: String,
        kind: MessageKind = MessageKind.TEXT,
        conversationId: String,
        replyTo: VMessage? = null,
        forwarded: Boolean = false,
    ) {
        val tempId = UUID.randomUUID().toString()
        val msg = VMessage(
            id = tempId, conversationId = conversationId, senderId = "me",
            kind = kind, text = text, createdAt = System.currentTimeMillis(),
            status = MessageStatus.SENDING, isMine = true,
            forwarded = forwarded,
            replyToSender = replyTo?.let { if (it.isMine) "You" else it.senderName.ifEmpty { "" } },
            replyToText = replyTo?.let { if (it.kind == MessageKind.TEXT) it.text else "Attachment" },
        )
        list(conversationId).add(msg)
        bumpPreview(conversationId, if (kind == MessageKind.TEXT) text else previewFor(kind))

        val conv = directConversations.firstOrNull { it.id == conversationId }
        if (conv == null) {
            markStatus(tempId, conversationId, MessageStatus.SENT)   // group/unknown: local echo only
            return
        }
        viewModelScope.launch {
            try {
                val peer = peerUserId(conv)
                engine.sendText(text, conversationId, peer)
                removeMessage(tempId, conversationId)
                refresh(conversationId)
            } catch (e: Exception) {
                markStatus(tempId, conversationId, MessageStatus.FAILED)
                loadError = (e as? com.voiid.app.net.ApiError)?.message ?: "Couldn’t send message."
            }
        }
    }

    // MARK: - Realtime (WebSocket) glue

    private fun startRealtime() {
        if (realtimeInstalled) return
        realtimeInstalled = true
        ws.onMessageRef = { cid -> viewModelScope.launch { handleIncoming(cid) } }
        ws.onTyping = { cid, _, isTyping ->
            if (isTyping) { if (!typingConversations.contains(cid)) typingConversations.add(cid) }
            else typingConversations.remove(cid)
        }
        ws.onReceipt = { mid, status -> applyReceipt(mid, status) }
        ws.connect()
    }

    /** Send a typing frame for a direct chat (best-effort). */
    fun sendTyping(conversationId: String, isStart: Boolean) {
        val peer = directConversations.firstOrNull { it.id == conversationId }?.peerUserId ?: return
        ws.sendTyping(conversationId, listOf(peer), isStart)
    }

    private suspend fun handleIncoming(conversationId: String) {
        val conv = directConversations.firstOrNull { it.id == conversationId }
        if (conv == null) { loadConversations(); return }
        syncMessages(conv)
    }

    private fun markStatus(id: String, convId: String, status: MessageStatus) {
        val arr = messagesByConversation[convId] ?: return
        val idx = arr.indexOfFirst { it.id == id }
        if (idx >= 0) arr[idx] = arr[idx].copy(status = status)
    }

    private fun removeMessage(id: String, convId: String) {
        messagesByConversation[convId]?.removeAll { it.id == id }
    }

    private fun previewFor(kind: MessageKind): String = when (kind) {
        MessageKind.IMAGE -> "📷 Photo"
        MessageKind.VOICE -> "🎤 Voice message"
        MessageKind.DOCUMENT -> "📄 Document"
        else -> "Message"
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
