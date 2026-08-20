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
import com.voiid.app.store.LocalStore
import com.voiid.app.store.UserDirectory
import kotlinx.coroutines.delay
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.util.UUID

/**
 * Local, in-memory app state — port of iOS `Stores.swift` (NO network, NO crypto).
 * Everything is interactive: sending a message appends it, marks it sent→delivered→read on
 * timers, and simulates a reply, so the app *feels* real end-to-end on a device.
 */

// MARK: - Session / onboarding

enum class AppRoute { ONBOARDING, MAIN }

class AppSession(app: Application) : AndroidViewModel(app) {
    private val appContext: android.content.Context = app.applicationContext
    val auth = AuthService(app)

    // Resume straight to the app if we already hold a session token.
    var route by mutableStateOf(if (auth.isAuthenticated) AppRoute.MAIN else AppRoute.ONBOARDING)
        private set
    // Empty until the REAL profile loads (loadProfile → ProfileService). Never a dummy
    // "You / +91 …" placeholder that could flash before the real data arrives.
    var profile by mutableStateOf(VUser(id = "me", fullName = "", phoneNumber = ""))

    /**
     * UNUSED on Android, and deliberately so — do not start writing to it.
     *
     * iOS gates its bar on an equivalent flag, which is opt-out: every pushed screen must
     * remember to set it, and every root tab to clear it. Android instead draws chat detail,
     * clips, stories, and both call screens as full-screen `AnimatedVisibility` overlays ON
     * TOP of the column that holds the bar, so those screens COVER it structurally. A new
     * overlay therefore cannot leak the bar by forgetting a flag — which is the failure mode
     * this field would reintroduce.
     *
     * Kept only so the two platforms' AppSession shapes still line up.
     */
    var hideTabBar by mutableStateOf(false)

    /** The authenticated user's id (our backend id), once logged in. */
    val userId: String? get() = auth.userId

    init {
        UserDirectory.init(appContext)
        loadProfile()
    }

    /**
     * Our own profile lives in the same `users` table as everyone else's — one row, one set
     * of merge rules. Read it locally first (so Settings shows your real name and number on a
     * cold, offline launch instead of the "You" placeholder), then refresh from the server.
     */
    fun loadProfile() {
        val id = userId ?: return
        viewModelScope.launch {
            UserDirectory.ready(appContext)
            UserDirectory.user(id)?.let { row ->
                profile = profile.copy(
                    id = id,
                    fullName = row.fullName ?: profile.fullName,
                    phoneNumber = row.phoneE164 ?: profile.phoneNumber,
                    photoURL = row.photoUrl ?: profile.photoURL,
                    bio = row.bio ?: profile.bio,
                )
            }
            val u = runCatching { com.voiid.app.net.ProfileService(appContext).fetchUser(id) }.getOrNull()
                ?: return@launch
            UserDirectory.upsertFromServer(
                userId = id, fullName = u.full_name, username = u.username,
                photoUrl = u.photo_url, bio = u.bio,
            )
            profile = profile.copy(
                id = id,
                fullName = u.full_name ?: profile.fullName,
                photoURL = u.photo_url ?: profile.photoURL,
                bio = u.bio ?: profile.bio,
                username = u.username ?: profile.username,
            )
        }
    }

    /**
     * Apply a profile edit LOCALLY — on screen immediately and durable before any request is
     * attempted, so editing your name offline works and survives a restart. The caller owns
     * the server sync (and reporting its failure); this never blocks on it.
     */
    fun updateProfile(fullName: String? = null, photoUrl: String? = null, phoneE164: String? = null,
                      bio: String? = null, username: String? = null) {
        profile = profile.copy(
            fullName = fullName ?: profile.fullName,
            photoURL = photoUrl ?: profile.photoURL,
            phoneNumber = phoneE164 ?: profile.phoneNumber,
            bio = bio ?: profile.bio,
            username = username ?: profile.username,
        )
        val id = userId ?: return
        UserDirectory.upsertFromServer(
            userId = id, fullName = fullName, photoUrl = photoUrl, phoneE164 = phoneE164,
            bio = bio, username = username,
        )
    }

    /** Called at the end of onboarding once a real session token exists. */
    fun completeOnboarding() {
        route = AppRoute.MAIN
        loadProfile()
    }

    /**
     * Order matters: wipe every local trace of THIS account before clearing the auth
     * token, mirroring iOS `SettingsSheet.performLogOut()` -> `SessionTeardown` ->
     * `AppSession.signOut()`. See `SessionTeardown.wipeLocalAccountState` for why —
     * without it the next account signed in on this device inherited the previous
     * user's chats, contacts and E2E identity.
     */
    fun signOut() {
        com.voiid.app.net.SessionTeardown.wipeLocalAccountState(appContext)
        auth.logout()
        profile = VUser(id = "me", fullName = "", phoneNumber = "")   // don't leak into the next login
        route = AppRoute.ONBOARDING
    }
}

// MARK: - Chat store (the heart of the "feels real" experience)

class ChatStore(app: Application) : AndroidViewModel(app) {
    private val appContext: android.content.Context = app.applicationContext

    // REAL backend data — starts empty, loaded via loadConversations(). A new
    // account shows an empty list, confirming we read the live server (not mock).
    /**
     * False until the first server load finishes.
     *
     * WITHOUT THIS "still loading" and "you have no chats" render identically — a blank
     * screen. On a fresh install that blank is the first thing a new user ever sees, and it
     * is indistinguishable from the app being broken. Cached chats paint instantly from Room,
     * so this only ever gates the genuinely-empty case. Mirrors iOS.
     */
    var didLoadConversations by mutableStateOf(false)
        private set

    val directConversations = mutableStateListOf<VConversation>()
    val groupConversations = mutableStateListOf<VConversation>()
    private val messagesByConversation = mutableStateMapOf<String, androidx.compose.runtime.snapshots.SnapshotStateList<VMessage>>()
    /**
     * Finished calls per conversation, as transcript bubbles. Kept SEPARATE from the message
     * map and merged on read: a call log is not a message, is never sent over the wire, and
     * must not be persisted into the message store, previewed, or counted as unread.
     */
    private val callLogsByConversation = mutableStateMapOf<String, List<VMessage>>()
    val typingConversations = mutableStateListOf<String>()
    /** Pending auto-clears, one per conversation — see the onTyping handler. */
    private val typingExpiry = mutableMapOf<String, kotlinx.coroutines.Job>()
    var loadError by mutableStateOf<String?>(null)

    private val chatService = com.voiid.app.net.ChatService(app)
    private val engine = com.voiid.app.net.ChatEngine.get(app)
    private val groupEngine = com.voiid.app.net.GroupEngine.get(app)
    private val ws = com.voiid.app.net.WebSocketClient.get(app)
    private var realtimeInstalled = false
    // Conversations we've already asked the peer to reset this session (avoid loops).
    private val resetRequested = HashSet<String>()

    /**
     * Show the local list FIRST, then fetch. The network only ever updates the store — a
     * failed (or slow, or offline) fetch leaves the grid exactly as it was instead of
     * emptying it, which is what used to happen when the list was nothing but the body of a
     * GET. Also installs the realtime handlers.
     */
    fun loadConversations() {
        startRealtime()
        viewModelScope.launch {
            loadLocal()
            ws.reconnect()   // fresh socket on each chats-screen entry (avoid a dead one missing pushes)
            reload()
        }
    }

    /** Render from Room. Never touches the network, never clears on failure. */
    private suspend fun loadLocal() {
        val cached = runCatching { LocalStore.conversations(appContext) }.getOrDefault(emptyList())
        if (cached.isEmpty()) return
        directConversations.clear(); groupConversations.clear()
        // Note to Self lives in CHATS, pinned to the top — you reach for it by muscle
        // memory, not by recency, so its position should never move. Filtering to DIRECT
        // alone would drop it from BOTH lists. Mirrors iOS `applyLocalConversations`.
        directConversations.addAll(cached.filter { it.type == ConversationType.SELF })
        directConversations.addAll(cached.filter { it.type == ConversationType.DIRECT })
        groupConversations.addAll(cached.filter { it.type == ConversationType.GROUP })
        // Previews come from Room (denormalized), so we touch NO message store here — the list
        // paints instantly and offline regardless of history size. Full history maps lazily on
        // open; previews stay fresh via bumpPreview at write time.
        backfillPreviewsIfNeeded()
    }

    /** One-time backfill of previews for chats that existed BEFORE the preview column, run OFF
     *  the launch path (IO, after the list is on screen). No-op for fresh installs. */
    private fun backfillPreviewsIfNeeded() {
        val prefs = appContext.getSharedPreferences("voiid_flags", android.content.Context.MODE_PRIVATE)
        if (prefs.getBoolean("previews_backfilled_v1", false)) return
        val ids = (directConversations + groupConversations).map { it.id }
        viewModelScope.launch(Dispatchers.IO) {
            for (id in ids) {
                val last = engine.messages(id).lastOrNull() ?: continue
                val kind = when {
                    last.location != null -> MessageKind.LOCATION
                    last.media == null -> MessageKind.TEXT
                    last.media.mime.startsWith("audio/") -> MessageKind.VOICE
                    else -> MessageKind.IMAGE
                }
                val preview = if (kind == MessageKind.TEXT) last.text else previewFor(kind)
                if (preview.isNotBlank()) LocalStore.updatePreview(appContext, id, preview, last.createdAt)
            }
            prefs.edit().putBoolean("previews_backfilled_v1", true).apply()
            withContext(Dispatchers.Main) { loadLocal() }   // re-render with backfilled previews
        }
    }

    /** Suspend reload (so callers like handleIncoming can await it, then sync). */
    private suspend fun reload() {
        try {
            // Ensure Note to Self exists before the list is fetched, so it appears on first
            // launch rather than only after a second one. Idempotent server-side; a failure
            // is not worth surfacing — the list still loads and the next launch retries.
            runCatching { chatService.createSelfChat() }

            // Titles come from the directory, not the server: if you saved this person as
            // "Mum" in your address book, every screen says "Mum" whatever they signed up as.
            val convs = chatService.fetchConversations().map { c ->
                val peer = c.peerUserId
                if (c.type == ConversationType.DIRECT && peer != null) {
                    c.copy(title = UserDirectory.displayName(peer, fallback = c.title))
                } else c
            }
            // The server payload carries no preview snippet — preserve the denormalized one we
            // already hold (from Room) so a sync doesn't blank the list previews.
            val prevMap = (directConversations + groupConversations).associate { it.id to it.lastMessagePreview }
            val withPreview = convs.map { it.copy(lastMessagePreview = it.lastMessagePreview ?: prevMap[it.id]) }
            directConversations.clear(); groupConversations.clear()
            directConversations.addAll(withPreview.filter { it.type == ConversationType.SELF })
            directConversations.addAll(withPreview.filter { it.type == ConversationType.DIRECT })
            groupConversations.addAll(withPreview.filter { it.type == ConversationType.GROUP })
            LocalStore.saveConversations(appContext, convs)   // so the next cold launch renders instantly (preview col preserved by the upsert)
            loadError = null
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t load chats."
        } finally {
            // Set on BOTH paths — success and failure. A load that failed is still a load
            // that finished; leaving this false would strand the user on a skeleton forever
            // with the error hidden behind it.
            didLoadConversations = true
        }
    }

    /**
     * The transcript: real messages with this conversation's call bubbles merged in by time.
     *
     * Merging HERE rather than inserting into the message list keeps call logs out of the
     * message store, the chat-list preview and the unread count, while every existing caller
     * (the chat screen, search, jump-to-message) picks them up for free.
     */
    fun messages(id: String): List<VMessage> {
        val msgs = messagesByConversation[id] ?: emptyList()
        val calls = callLogsByConversation[id] ?: emptyList()
        if (calls.isEmpty()) return msgs
        return (msgs + calls).sortedBy { it.createdAt }
    }

    /** Load this conversation's call history into the transcript. Call on chat open. */
    fun loadCallLogs(conversationId: String) {
        viewModelScope.launch {
            val rows = LocalStore.callsForConversation(appContext, conversationId)
            callLogsByConversation[conversationId] = rows.map { r ->
                VMessage(
                    id = "call:${r.id}",
                    conversationId = conversationId,
                    senderId = if (r.direction == "incoming") (r.peerUserId ?: "") else "me",
                    kind = MessageKind.CALL,
                    text = "",
                    // call_history stores SECONDS; VMessage.createdAt is MILLIS. Without this
                    // conversion every call bubble would sort to 1970 and pile up at the top.
                    createdAt = r.startedAt * 1000L,
                    isMine = r.direction != "incoming",
                    call = VCallLog(
                        callId = r.id,
                        isVideo = r.kind == "video",
                        incoming = r.direction == "incoming",
                        outcome = r.outcome,
                        startedAt = r.startedAt * 1000L,
                        endedAt = r.endedAt?.let { it * 1000L },
                    ),
                )
            }
        }
    }

    private fun list(id: String) = messagesByConversation.getOrPut(id) { mutableStateListOf() }

    /** Resolve a conversation by id for deep-linking (e.g. a notification tap). Returns
     *  a cached one immediately, otherwise reloads the list from the server once. */
    suspend fun conversationById(id: String): VConversation? {
        (directConversations + groupConversations).firstOrNull { it.id == id }?.let { return it }
        runCatching { reload() }
        return (directConversations + groupConversations).firstOrNull { it.id == id }
    }

    /**
     * The conversation currently ON SCREEN, or null.
     *
     * Read receipts are gated on this. Without it [syncMessages] marked messages read from
     * EVERY sync — including the one a background FCM push triggers — so a message was
     * reported "Seen" the moment it arrived in a chat the user had never opened. That is a
     * privacy failure as much as a correctness one: it tells the sender you read something
     * you have not looked at.
     */
    var openConversationId: String? = null
        private set

    /** Open a conversation: show cached, then sync (fetch + decrypt-new) from server. */
    fun openConversation(conv: VConversation) {
        openConversationId = conv.id
        // Clear the badge NOW rather than waiting for the next /conversations poll to report
        // it. The receipt round-trip takes a moment, and a chat you are staring at showing
        // "3 unread" is the single most obvious way for the count to look broken.
        clearUnreadLocally(conv.id)
        refresh(conv.id)
        viewModelScope.launch { syncMessages(conv) }
    }

    /** Zero the local unread badge. The server is the source of truth; this just stops the
     *  UI lying during the round-trip. */
    private fun clearUnreadLocally(conversationId: String) {
        listOf(directConversations, groupConversations).forEach { list ->
            val i = list.indexOfFirst { it.id == conversationId }
            if (i >= 0 && list[i].unreadCount != 0) list[i] = list[i].copy(unreadCount = 0)
        }
    }

    /** The chat closed. Stops read receipts for it until it is opened again. */
    fun closeConversation(conversationId: String) {
        if (openConversationId == conversationId) openConversationId = null
    }

    /**
     * Mark the open chat read. Called on open, and whenever a message lands WHILE it is open —
     * the arrival path must not rely on the next manual sync.
     */
    suspend fun markOpenConversationRead(conversationId: String) {
        // Both guards are silent no-ops, and either one explains "read never happens" — so say
        // which fired rather than leaving the caller to guess.
        if (openConversationId != conversationId) {
            android.util.Log.i(
                "VOIIDReceipt",
                "markOpen SKIPPED: open=$openConversationId asked=$conversationId",
            )
            return
        }
        if (!PrivacySettings.sendReadReceipts(appContext)) {
            android.util.Log.i("VOIIDReceipt", "markOpen SKIPPED: read receipts disabled in settings")
            return
        }
        engine.markRead(conversationId)
    }

    suspend fun syncMessages(conv: VConversation) {
        if (conv.type == ConversationType.GROUP) {
            // MLS: process Welcome/Commit events FIRST (join / advance epoch), then decrypt
            // this device's pending group app messages into the shared store, then refresh.
            try {
                groupEngine.syncGroupEvents()
                groupEngine.receiveGroupMessages(conv.id)
                refresh(conv.id)
                // Only for the chat ON SCREEN — see `openConversationId`.
                markOpenConversationRead(conv.id)
            } catch (e: Exception) {
                loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t load messages."
            }
            return
        }
        try {
            val peer = peerUserId(conv)
            engine.sync(conv.id, peer)
            refresh(conv.id)
            // Couldn't decrypt inbound → our session is stale; ask the peer (once) to re-establish.
            if (engine.lastSyncHadDecryptFailure && resetRequested.add(conv.id)) {
                engine.resetSession(peer)
                ws.sendSessionReset(conv.id, listOf(peer))
            }
            // Only for the chat ON SCREEN — see `openConversationId`.
            markOpenConversationRead(conv.id)
            fetchPresence(conv.id, peer)
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t load messages."
            // MARK THE READ ANYWAY. Everything above can throw — resolving the peer, the
            // fetch itself — and every one of those throws used to skip the receipt because
            // it sat inside the try. The messages already on screen were still read by a
            // human; a network failure while re-syncing does not un-read them.
            //
            // The visible symptom was a chat you are looking at still showing unread, and a
            // sender on the other platform stuck on Delivered forever. Safe here: markRead
            // only reports ids already in the local store, and markOpenConversationRead
            // still gates on the chat being open.
            runCatching { markOpenConversationRead(conv.id) }
        }
    }

    /** Resolve the peer + refresh presence (for the periodic poll while a chat is open). */
    suspend fun refreshPresence(conv: VConversation) {
        if (conv.type != ConversationType.DIRECT) return
        val peer = runCatching { peerUserId(conv) }.getOrNull() ?: return
        fetchPresence(conv.id, peer)
    }

    /** Fetch + apply the peer's online/last-seen presence to the conversation. */
    suspend fun fetchPresence(convId: String, peerUserId: String) {
        val st = runCatching { chatService.status(peerUserId) }.getOrNull() ?: return
        val i = directConversations.indexOfFirst { it.id == convId }
        if (i >= 0) directConversations[i] = directConversations[i].copy(isOnline = st.online, lastSeenAt = st.lastSeen)
    }

    /** Apply a delivery/read receipt (WS) — persist in the engine (no regression) then refresh. */
    private fun applyReceipt(messageId: String, status: String) {
        val cid = engine.applyReceipt(messageId, status)
        android.util.Log.i("VOIID", "📥 receipt $status for $messageId → ${if (cid == null) "no match" else "applied"}")
        cid?.let { refresh(it) }
    }


    private fun refresh(convId: String) {
        val mapped = engine.messages(convId).map { d ->
            val kind = when {
                d.location != null -> MessageKind.LOCATION
                d.media == null -> MessageKind.TEXT
                d.media.mime.startsWith("audio/") -> MessageKind.VOICE
                else -> MessageKind.IMAGE
            }
            val status = when {
                !d.isMine -> MessageStatus.READ
                d.failed -> MessageStatus.FAILED
                d.pending -> MessageStatus.SENDING
                d.deliveryStatus == "read" -> MessageStatus.READ
                d.deliveryStatus == "delivered" -> MessageStatus.DELIVERED
                else -> MessageStatus.SENT
            }
            // Surface delivered chat actions. Reaction display is single-emoji (peer's else
            // mine); the per-user map is persisted in the engine.
            val myId = com.voiid.app.net.TokenStore.get(getApplication()).userId
            val reaction = d.reactions?.let { m -> m.entries.firstOrNull { it.key != myId }?.value ?: m.values.firstOrNull() }
            VMessage(
                // Use the server id once known so receipts can match it.
                id = d.serverId ?: d.id, conversationId = convId,
                senderId = if (d.isMine) "me" else d.senderId,
                // Sender's real display name for the group bubble (empty stayed hidden before).
                senderName = if (d.isMine) "" else com.voiid.app.store.UserDirectory.displayName(d.senderId),
                kind = kind, text = d.text, createdAt = d.createdAt,
                status = status, isMine = d.isMine, mediaRef = d.media, location = d.location,
                reaction = reaction, deletedForEveryone = d.deletedForEveryone, forwarded = d.forwarded,
                replyToText = d.quotedPreview, replyToSender = d.quotedSender,
                // Real Delivered / Read times for the Message Info sheet.
                deliveredAt = d.deliveredAt, readAt = d.readAt,
            )
        }
        if (mapped.isNotEmpty() || messagesByConversation.containsKey(convId)) {
            val arr = list(convId)
            arr.clear(); arr.addAll(mapped)
        }
        mapped.lastOrNull()?.let { bumpPreview(convId, if (it.kind == MessageKind.TEXT) it.text else previewFor(it.kind)) }
    }

    /** Send a media (image/voice) message: encrypt the blob on-device, upload the
     *  ciphertext to R2, pack the key into the E2EE message (direct chats only). */
    fun sendMedia(data: ByteArray, mime: String, caption: String = "", conversationId: String) {
        val kind = if (mime.startsWith("audio/")) MessageKind.VOICE else MessageKind.IMAGE
        val tempId = UUID.randomUUID().toString()
        list(conversationId).add(
            VMessage(
                id = tempId, conversationId = conversationId, senderId = "me",
                kind = kind, text = caption, createdAt = System.currentTimeMillis(),
                status = MessageStatus.SENDING, isMine = true,
            ),
        )
        bumpPreview(conversationId, previewFor(kind))

        val conv = directConversations.firstOrNull { it.id == conversationId }
        if (conv == null) {
            markStatus(tempId, conversationId, MessageStatus.SENT)   // group: not supported yet
            return
        }
        viewModelScope.launch {
            try {
                val peer = peerUserId(conv)
                val echo = engine.sendMedia(data, mime, caption, conversationId, peer)
                // Local-first: cache the ORIGINAL plaintext under the R2 key so this sender
                // renders its own photo/voice instantly and offline — never re-downloads it.
                echo.media?.mediaUrl?.let { com.voiid.app.main.MediaCache.putData(appContext, it, data) }
                removeMessage(tempId, conversationId)
                refresh(conversationId)
            } catch (e: Exception) {
                markStatus(tempId, conversationId, MessageStatus.FAILED)
                loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t send media."
            }
        }
    }

    /** Resolve + cache the peer user_id for a direct conversation. */
    private suspend fun peerUserId(conv: VConversation): String {
        // NOTE TO SELF: the peer IS me. Without this case the generic path below asks
        // resolvePeer for "the member who isn't me" — of a conversation whose only member is
        // me — gets null, and throws 404 "no peer". That throw is why the whole feature was
        // dead: every send failed before it reached the fan-out that was already written to
        // handle this case correctly.
        if (conv.type == ConversationType.SELF) {
            return com.voiid.app.net.TokenStore.get(getApplication()).userId ?: ""
        }

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
            LocalStore.saveConversations(appContext, listOf(conv))   // survives a restart before the first sync
            conv
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t start chat."
            null
        }
    }

    /** Create a real E2EE (MLS) group: create the server container, build the MLS group
     *  (fetch members' KeyPackages, add each, distribute Welcome/Commit), then add it to
     *  the list. Returns the new conversation for navigation, or null on failure. */
    suspend fun createGroup(name: String, memberUserIds: List<String>): VConversation? {
        return try {
            val convId = chatService.createGroup(name, memberUserIds)
            groupEngine.createGroup(convId, memberUserIds)
            val conv = VConversation(
                id = convId, type = ConversationType.GROUP, title = name,
                memberCount = memberUserIds.size + 1,
            )
            if (groupConversations.none { it.id == convId }) groupConversations.add(0, conv)
            LocalStore.saveConversations(appContext, listOf(conv))
            conv
        } catch (e: Exception) {
            loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t create the group."
            null
        }
    }

    /** Admin: add a user to an existing MLS group, then refresh members. */
    fun addGroupMember(conversationId: String, userId: String, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            runCatching { groupEngine.addMember(conversationId, userId) }
                .onFailure { loadError = (it as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t add member." }
            onDone()
        }
    }

    /** Admin: remove a user from an MLS group (rekeys), then refresh members. */
    fun removeGroupMember(conversationId: String, userId: String, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            runCatching { groupEngine.removeMember(conversationId, userId) }
                .onFailure { loadError = (it as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t remove member." }
            onDone()
        }
    }

    /**
     * Promote a member to admin, or demote one back.
     *
     * The server owns the policy (036_group_roles.sql + conversations.ts): an admin may
     * promote, but only the OWNER may dismiss an admin. A refusal comes back as a readable
     * message and is surfaced verbatim — a generic "couldn't do that" would leave an admin
     * puzzling over a button they can see but cannot use.
     */
    fun setMemberRole(conversationId: String, userId: String, role: MemberRole, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            runCatching { chatService.setMemberRole(conversationId, userId, role.name.lowercase()) }
                .onFailure { loadError = (it as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t change that role." }
            onDone()
        }
    }

    /** Hand the group over. Owner-only; the server does both halves in one transaction. */
    fun transferOwnership(conversationId: String, userId: String, onDone: () -> Unit = {}) {
        viewModelScope.launch {
            runCatching { chatService.transferOwnership(conversationId, userId) }
                .onFailure { loadError = (it as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t transfer ownership." }
            onDone()
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
        val conv = directConversations.firstOrNull { it.id == conversationId }
        // Real E2EE group text over MLS: persist an echo in the shared store, then encrypt
        // + fan out in the background. Non-text group content still falls through to echo.
        val group = groupConversations.firstOrNull { it.id == conversationId }
        if (group != null && kind == MessageKind.TEXT) {
            viewModelScope.launch {
                try {
                    groupEngine.sendGroupMessage(conversationId, text)
                    refresh(conversationId)
                    bumpPreview(conversationId, text)
                } catch (e: Exception) {
                    loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t send group message."
                }
            }
            refresh(conversationId)
            bumpPreview(conversationId, text)
            return
        }
        if (conv == null || kind != MessageKind.TEXT) {
            // Group / non-text (e.g. forwarded media) — transient local echo only.
            val tempId = UUID.randomUUID().toString()
            list(conversationId).add(
                VMessage(
                    id = tempId, conversationId = conversationId, senderId = "me",
                    kind = kind, text = text, createdAt = System.currentTimeMillis(),
                    status = MessageStatus.SENDING, isMine = true, forwarded = forwarded,
                    replyToSender = replyTo?.let { if (it.isMine) "You" else it.senderName.ifEmpty { "" } },
                    replyToText = replyTo?.let { if (it.kind == MessageKind.TEXT) it.text else "Attachment" },
                ),
            )
            bumpPreview(conversationId, if (kind == MessageKind.TEXT) text else previewFor(kind))
            markStatus(tempId, conversationId, MessageStatus.SENT)
            return
        }

        // A quoted reply travels as its own E2EE envelope so the quote reaches the peer.
        if (replyTo != null) {
            bumpPreview(conversationId, text)
            val quotedId = replyTo.id
            val preview = if (replyTo.kind == MessageKind.TEXT) replyTo.text.take(80) else previewFor(replyTo.kind)
            val sender = if (replyTo.isMine) "You" else replyTo.senderName.ifEmpty { "" }
            viewModelScope.launch {
                try {
                    val peer = peerUserId(conv)
                    engine.sendReply(text, quotedId, preview, sender, conversationId, peer)
                    refresh(conversationId)
                } catch (e: Exception) {
                    loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t resolve the recipient."
                }
            }
            return
        }

        // Text: persist as PENDING in the engine store now (instant + offline-visible),
        // then flush (send) in the background. The store is the single source of truth.
        engine.enqueueText(text, conversationId)
        refresh(conversationId)
        bumpPreview(conversationId, text)
        viewModelScope.launch {
            try {
                val peer = peerUserId(conv)
                engine.flushPending(conversationId, peer)
                refresh(conversationId)
            } catch (e: Exception) {
                loadError = (e as? com.voiid.app.net.ApiError)?.userMessage ?: "Couldn’t resolve the recipient."
            }
        }
    }

    // MARK: - Realtime (WebSocket) glue

    private fun startRealtime() {
        if (realtimeInstalled) return
        realtimeInstalled = true
        ws.onMessageRef = { cid -> viewModelScope.launch { handleIncoming(cid) } }
        ws.onTyping = { cid, _, isTyping ->
            if (isTyping) {
                if (!typingConversations.contains(cid)) typingConversations.add(cid)
                // EXPIRE IT. "stop" is not guaranteed to arrive — the sender can background
                // the app, lose signal, or have the socket drop mid-word, and every one of
                // those leaves a permanent "typing…" that only a restart clears. The peer
                // re-sends "start" while still typing, so refreshing the deadline keeps a
                // genuine indicator alive. Mirrors iOS `typingExpiry`.
                typingExpiry.remove(cid)?.cancel()
                typingExpiry[cid] = viewModelScope.launch {
                    delay(8_000)
                    typingConversations.remove(cid)
                    typingExpiry.remove(cid)
                }
            } else {
                typingExpiry.remove(cid)?.cancel()
                typingConversations.remove(cid)
            }
        }
        ws.onReceipt = { mid, status -> applyReceipt(mid, status) }
        // Peer asked us to re-establish — drop our sessions with that peer (all devices).
        ws.onSessionReset = { cid ->
            directConversations.firstOrNull { it.id == cid }?.peerUserId?.let { engine.resetSession(it) }
        }
        // An MLS welcome/commit was relayed for one of our groups — process it.
        ws.onMlsEvent = { viewModelScope.launch { handleMlsEvent() } }
        // connection is (re)established by loadConversations via ws.reconnect()
    }

    /** Send a typing frame for a direct chat (best-effort). */
    fun sendTyping(conversationId: String, isStart: Boolean) {
        // Settings -> Privacy -> "Send typing indicators": when off, this device emits
        // no `typing` WS frames at all (see PrivacySettings).
        if (!PrivacySettings.sendTypingIndicators(appContext)) return
        val peer = directConversations.firstOrNull { it.id == conversationId }?.peerUserId ?: return
        ws.sendTyping(conversationId, listOf(peer), isStart)
    }

    private suspend fun handleIncoming(conversationId: String) {
        android.util.Log.i("VOIID", "handleIncoming conv=$conversationId known=${directConversations.any { it.id == conversationId }}")
        (directConversations + groupConversations).firstOrNull { it.id == conversationId }?.let { syncMessages(it); return }
        // Unknown conversation (first message from a new contact / a group we were just
        // added to) — reload the list, THEN sync it so the message actually appears.
        reload()
        (directConversations + groupConversations).firstOrNull { it.id == conversationId }?.let { syncMessages(it) }
    }

    /** An MLS control event (welcome/commit) landed — process group events across all our
     *  groups so a just-received Welcome joins us + any group advances, then refresh. */
    private suspend fun handleMlsEvent() {
        runCatching {
            groupEngine.syncGroupEvents()
            // We may have just JOINED a group we don't yet list — reload to surface it.
            reload()
            groupConversations.forEach { runCatching { groupEngine.receiveGroupMessages(it.id); refresh(it.id) } }
        }.onFailure { android.util.Log.e("VOIID", "handleMlsEvent failed", it) }
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
        MessageKind.LOCATION -> "📍 Location"
        MessageKind.DOCUMENT -> "📄 Document"
        else -> "Message"
    }

    /** Forward a message to one or more conversations. Media is forwarded by RE-SENDING its
     *  E2EE reference — the ciphertext is already in R2, so no re-upload; key stays E2E. */
    fun forward(message: VMessage, conversationIds: List<String>) {
        for (cid in conversationIds) {
            val ref = message.mediaRef
            val conv = directConversations.firstOrNull { it.id == cid }
            if (ref != null && conv != null &&
                (message.kind == MessageKind.IMAGE || message.kind == MessageKind.VOICE || message.kind == MessageKind.DOCUMENT)) {
                viewModelScope.launch {
                    val peer = runCatching { peerUserId(conv) }.getOrNull() ?: return@launch
                    runCatching { engine.forwardMedia(ref, message.text, cid, peer) }
                    refresh(cid)
                }
            } else {
                send(text = message.text,
                     kind = if (message.kind == MessageKind.POLL) MessageKind.TEXT else message.kind,
                     conversationId = cid, forwarded = true)
            }
        }
    }

    /** Delete a message. forEveryone=true tombstones it AND tells the peer; else local-only. */
    fun deleteMessage(messageId: String, convId: String, forEveryone: Boolean) {
        val arr = messagesByConversation[convId] ?: return
        val idx = arr.indexOfFirst { it.id == messageId }
        if (idx < 0) return
        if (forEveryone) {
            arr[idx] = arr[idx].copy(deletedForEveryone = true, reaction = null)
            val conv = directConversations.firstOrNull { it.id == convId }
            if (conv != null) viewModelScope.launch {
                val peer = runCatching { peerUserId(conv) }.getOrNull() ?: return@launch
                runCatching { engine.sendDeleteForEveryone(messageId, convId, peer) }
            }
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

    /** Toggle an emoji reaction on a message — and DELIVER it to the peer over E2EE. */
    fun react(messageId: String, emoji: String, convId: String) {
        val arr = messagesByConversation[convId] ?: return
        val idx = arr.indexOfFirst { it.id == messageId }
        if (idx < 0) return
        val cleared = arr[idx].reaction == emoji
        arr[idx] = arr[idx].copy(reaction = if (cleared) null else emoji)   // optimistic local
        val conv = directConversations.firstOrNull { it.id == convId } ?: return
        viewModelScope.launch {
            val peer = runCatching { peerUserId(conv) }.getOrNull() ?: return@launch
            runCatching { engine.sendReaction(messageId, if (cleared) null else emoji, convId, peer) }
        }
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

    private fun bumpPreview(convId: String, rawPreview: String) {
        // A game invite is a text message carrying `voiid:game/...` marker lines. Callers pass the
        // message body straight through, so without this the chat LIST shows the raw markers
        // instead of a sentence. Normalised HERE rather than at each call site: one place, every
        // path. Mirrors the same guard in iOS Stores.swift.
        val preview = if (com.voiid.app.net.GameInvite.isInvite(rawPreview)) {
            com.voiid.app.net.GameInvite.preview(rawPreview)
        } else {
            rawPreview
        }
        val now = System.currentTimeMillis()
        val di = directConversations.indexOfFirst { it.id == convId }
        if (di >= 0) {
            directConversations[di] = directConversations[di].copy(lastMessagePreview = preview, lastMessageAt = now)
        } else {
            val gi = groupConversations.indexOfFirst { it.id == convId }
            if (gi >= 0) {
                groupConversations[gi] = groupConversations[gi].copy(lastMessagePreview = preview, lastMessageAt = now)
            }
        }
        // Persist so the chat LIST shows this snippet + ordering on the next cold launch
        // straight from Room, without decoding the message store on the launch path.
        LocalStore.updatePreview(appContext, convId, preview, now)
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
//
// REMOVED. Clips are a real, server-backed feature now — see model/ClipsStore.kt (paging,
// uploads, optimistic-but-reconciled likes/comments) and net/ClipService.kt. The store
// here held DummyData arrays whose likes and comments were lost on every relaunch.
