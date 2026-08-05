package com.voiid.app.net

import android.content.Context
import android.util.Base64
import com.voiid.app.model.MapConstants
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.serialization.EncodeDefault
import kotlinx.serialization.Serializable
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.builtins.MapSerializer
import kotlinx.serialization.builtins.serializer
import uniffi.voiid.MediaKey
import uniffi.voiid.Session
import uniffi.voiid.WireMessage
import uniffi.voiid.decryptMedia
import uniffi.voiid.encryptMedia

/**
 * Real E2EE 1:1 messaging on top of e2e-core + the backend. Mirrors iOS ChatEngine.
 *
 *  - Sessions are established lazily: the sender fetches the peer's prekey bundle
 *    and startSession; the receiver acceptSession on the first (PreKey) message.
 *  - Sessions are pickled (EncryptedSharedPreferences) per conversation.
 *  - The server only sees opaque ciphertext: the e2e-core WireMessage (msgType +
 *    body) is packed into one base64 "ciphertext" field:
 *        base64( JSON {"t": msgType, "b": body} ).
 *
 * Decrypt-once: double-ratchet ciphertext can't be safely re-decrypted on every
 * reload, so each inbound message is decrypted EXACTLY ONCE and its plaintext is
 * persisted (encrypted at rest) keyed by message id. Our own sent messages are
 * also stored (we can't decrypt our own ratchet output).
 *
 * Anti-MITM: the peer's identity key is pinned on first contact (TOFU); a changed
 * key is refused rather than silently re-keyed (the basis for "safety numbers").
 */
class ChatEngine private constructor(context: Context) {

    companion object {
        @Volatile private var instance: ChatEngine? = null
        fun get(context: Context): ChatEngine =
            instance ?: synchronized(this) {
                instance ?: ChatEngine(context.applicationContext).also { instance = it }
            }
    }

    private val appContext = context.applicationContext

    /** Per-conversation lock so two concurrent syncs (4s poll + WS push) can't BOTH
     *  acceptSession the same PreKey messages — that races the one-time key and leaves
     *  the earliest messages permanently undecryptable (the Olm ratchet moves on). */
    private val syncLocks = java.util.concurrent.ConcurrentHashMap<String, Mutex>()
    private fun syncLock(conversationId: String): Mutex =
        syncLocks.getOrPut(conversationId) { Mutex() }
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)
    private val e2e = E2EManager.get(context)

    private val prefs = SecurePrefs.open(appContext, "voiid_chat")

    // (peerUserId, deviceId) -> ALL candidate Olm sessions for THAT specific remote
    // device. Multi-device fan-out: E2EE gives every device its own vodozemac session,
    // so sessions MUST be keyed per remote device (not per conversation/user) — a peer's
    // 2nd device can't decrypt the 1st device's ratchet output. The "remote" is either a
    // conversation peer's device OR one of the sender's own other (linked) devices.
    // During simultaneous initiation ("glare") both sides create their own session, so a
    // single device pair legitimately has MORE THAN ONE session. We must keep them all:
    // try each on decrypt, and append (never overwrite) a newly-accepted one — overwriting
    // strands the other side's early PreKey messages permanently.
    private val sessions = HashMap<String, MutableList<Session>>()  // key = sessionKey(userId, deviceId)
    private val store = HashMap<String, MutableList<DecryptedMessage>>() // conversationId -> messages (asc)
    private val media = MediaService(tokens)

    private val storeSerializer = MapSerializer(String.serializer(), ListSerializer(DecryptedMessage.serializer()))
    // Decrypt-once plaintext store: a PLAIN app-internal file (sandboxed, excluded from
    // backup) — NOT EncryptedSharedPreferences, whose key can be wiped by SecurePrefs,
    // destroying all history on restart. A file can't be wiped by a key issue.
    private val storeFile = java.io.File(appContext.filesDir, "voiid_messages.json")

    // NB: the store is NOT loaded in init anymore — it's decoded lazily on first access
    // (ensureLoaded), off the launch/list path. The chat list renders from Room instead.

    /**
     * The media reference carried INSIDE an E2EE message. The bytes live in R2 as
     * ciphertext at [mediaUrl] (opaque object key); [key]/[nonce]/[sha256] are the
     * per-message media key. The whole struct is the plaintext of a ratchet
     * message, so the media key never leaves E2E.
     */
    @Serializable
    data class MediaRef(
        val mediaUrl: String,
        val mime: String,
        val key: String,
        val nonce: String,
        val sha256: String,
    )

    /**
     * The RENDERABLE part of a location message (docs/LOCATION.md §4) — a pin, or the live
     * marker of a `live_start`. This is the keyless projection of a LocationEnvelope: the
     * shareKey is NEVER stored here (it lives in the secure store; see [LocationShareEngine]),
     * so persisting this struct in the message file is safe. Parallel to [MediaRef].
     */
    @Serializable
    data class LocationRef(
        val kind: String,                     // pin | live_start
        val shareId: String? = null,          // live_start only
        // Nullable: a live_start from iOS carries NO initial coordinate (iOS shows the live
        // marker purely from the WS fix stream). The bubble renders a "locating…" state until
        // the first fix arrives. A pin always has coordinates.
        val lat: Double? = null,
        val lon: Double? = null,
        val acc: Double = 0.0,
        val label: String? = null,
        val expiresAt: Long? = null,          // millis — live_start only
        val cadenceSeconds: Int? = null,
    )

    @Serializable
    data class DecryptedMessage(
        val id: String,                 // stable LOCAL id
        val senderId: String,
        val text: String,
        val createdAt: Long,
        val isMine: Boolean,
        val media: MediaRef? = null,
        /** Set for a location message (pin / live_start). The live/ended STATE is not stored
         *  here — it is derived from [LocationShareEngine] + expiresAt (the timer guarantee). */
        val location: LocationRef? = null,
        /** True until the server accepts it (offline/un-sent) — visible + retried. */
        val pending: Boolean = false,
        /** True if the last send attempt failed (e.g. peer has no prekeys). Still
         *  pending (auto-retried on the next flush) but surfaced as an error in UI. */
        val failed: Boolean = false,
        /** Server id once accepted (matches read/delivery receipts). */
        val serverId: String? = null,
        /** Delivery state of OUR sent message: "sent"/"delivered"/"read". Persisted
         *  so it never regresses when the message list is rebuilt. */
        val deliveryStatus: String? = null,
        /** When the message reached the recipient / was read (epoch millis) — stamped once
         *  each as receipts arrive, persisted, so the Message Info sheet shows real times. */
        val deliveredAt: Long? = null,
        val readAt: Long? = null,
        /** Per-USER reactions (userId -> emoji), so two people can react differently. */
        val reactions: Map<String, String>? = null,
        /** Delete-for-everyone tombstone from the original author. */
        val deletedForEveryone: Boolean = false,
        /** Quoted-reply snapshot (server id + short preview + who), so it renders even if
         *  the original was deleted. */
        val quotedId: String? = null,
        val quotedPreview: String? = null,
        val quotedSender: String? = null,
        /** "Forwarded" tag. */
        val forwarded: Boolean = false,
        /** A control message (reaction/delete signal): kept for dedup, never rendered. */
        val control: Boolean = false,
    )

    /** The E2EE plaintext of a media message: the reference + an optional caption. */
    @Serializable
    private data class MediaEnvelope(val v: Int = 1, val media: MediaRef, val caption: String)

    // MARK: - Public API

    /**
     * Drop every in-memory session and decrypted message BEFORE the caller deletes the
     * backing files (see [com.voiid.app.net.SessionTeardown]). Deleting files first would
     * leave this map to flush its stale contents right back to disk on the next [persist]
     * (e.g. from a send that raced the sign-out). Does NOT touch the files itself.
     */
    fun wipeInMemoryState() {
        sessions.clear()
        store.clear()
        dirtyConversations.clear()
        storeLoaded = false   // next login lazily loads the new account's shards
    }

    /** Locally-stored (already decrypted) messages for a conversation, oldest-first. */
    fun messages(conversationId: String): List<DecryptedMessage> {
        ensureLoaded()
        return (store[conversationId] ?: emptyList()).filter { !it.control }.sortedBy { it.createdAt }
    }

    /** Queue a text message as PENDING locally (instant + offline + survives restart),
     *  WITHOUT touching the network. Call [flushPending] to actually send. */
    fun enqueueText(text: String, conversationId: String): DecryptedMessage {
        val msg = DecryptedMessage(
            id = java.util.UUID.randomUUID().toString(),
            senderId = tokens.userId ?: "me", text = text,
            createdAt = System.currentTimeMillis(), isMine = true, pending = true,
        )
        append(conversationId, msg)
        return msg
    }

    /** Try to send every PENDING text message (offline retry). Failures are swallowed
     *  — the message stays pending and is retried on the next flush. */
    suspend fun flushPending(conversationId: String, peerUserId: String) {
        ensureLoaded()
        val pendings = (store[conversationId] ?: emptyList()).filter { it.isMine && it.pending && it.media == null }
        for (p in pendings) {
            try {
                // Fan-out: encrypt ONCE PER TARGET DEVICE (peer's devices + our own other
                // devices), build the per-device bundle, and POST it in one send.
                val messages = encryptFanout(p.text.encodeToByteArray(), peerUserId)

                // A single-device NOTE TO SELF has no target devices (see encryptFanout).
                // There is nothing to upload — the note already lives in the local store,
                // which is the only place it was ever going to be read from. Mark it sent so
                // it does not sit under a spinner forever awaiting a delivery with no
                // recipient.
                if (messages.isEmpty()) {
                    markSent(p.id, conversationId, p.id)
                    continue
                }

                val body = ApiClient.json.encodeToString(
                    SendBundleBody.serializer(),
                    SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "text"))
                val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
                markSent(p.id, conversationId, res.message_id)
                android.util.Log.i("VOIID", "✅ sent text id=${res.message_id} conv=$conversationId devices=${messages.size}")
            } catch (e: Exception) {
                // "peer has no available prekeys" means the recipient hasn't published
                // keys yet (not registered / logged out / momentary race). Olm REQUIRES
                // a one-time key to start a session, so we genuinely can't send yet —
                // keep the message PENDING (clock, not red "failed") so the 4s poll
                // retries and it delivers the moment the peer publishes keys. Only
                // surface a hard failure for unexpected errors.
                val retryable = (e as? ApiError.Http)?.let { it.status == 409 || it.status == 404 } == true ||
                    e is java.io.IOException
                if (retryable) {
                    android.util.Log.w("VOIID", "⏳ send pending (peer not ready) conv=$conversationId: ${e.message}")
                } else {
                    markFailed(p.id, conversationId)
                    android.util.Log.e("VOIID", "❌ sendText FAILED conv=$conversationId", e)
                }
            }
        }
    }

    /** Flag a still-pending message as failed so the UI can show an error + retry. */
    private fun markFailed(localId: String, conversationId: String) {
        val arr = store[conversationId] ?: return
        val i = arr.indexOfFirst { it.id == localId }
        if (i < 0 || arr[i].failed) return
        arr[i] = arr[i].copy(failed = true)
        markDirty(conversationId)
        persist()
    }

    /** Backwards-compatible one-shot send (enqueue + flush). */
    suspend fun sendText(text: String, conversationId: String, peerUserId: String): DecryptedMessage {
        val msg = enqueueText(text, conversationId)
        flushPending(conversationId, peerUserId)
        return msg
    }

    private fun markSent(localId: String, conversationId: String, serverId: String) {
        val arr = store[conversationId] ?: return
        val i = arr.indexOfFirst { it.id == localId }
        if (i < 0) return
        arr[i] = arr[i].copy(pending = false, failed = false, serverId = serverId)
        markDirty(conversationId)
        persist()
    }

    /**
     * Encrypt + send a MEDIA message. The blob is encrypted on-device, the
     * ciphertext is uploaded to R2, and the media reference (object key + media
     * key) is packed into the E2EE message plaintext as a JSON envelope — so the
     * key stays end-to-end. [caption] is optional text shown with the media.
     */
    suspend fun sendMedia(
        data: ByteArray, mime: String, caption: String = "",
        conversationId: String, peerUserId: String,
    ): DecryptedMessage {
        // 1. Encrypt the blob (e2e-core) → ciphertext + media key.
        val enc = encryptMedia(data)
        // 2. Upload the CIPHERTEXT to R2; get back the opaque object key.
        val key = media.upload(enc.ciphertext, mime)
        val ref = MediaRef(key, mime, enc.mediaKey.key, enc.mediaKey.nonce, enc.mediaKey.ciphertextSha256)
        // 3. The E2EE message plaintext is a media envelope (key never leaves E2E). The
        //    SAME envelope is encrypted per target device (fan-out); every device's copy
        //    references the one shared R2 blob via [key], so the media key stays E2E.
        val envelopeJson = ApiClient.json.encodeToString(MediaEnvelope.serializer(), MediaEnvelope(media = ref, caption = caption))
        val messages = encryptFanout(envelopeJson.encodeToByteArray(), peerUserId)
        // 4. Send the per-device bundle, tagging it as media + the opaque ref for the server.
        val body = ApiClient.json.encodeToString(
            SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "media", media_url = key, media_mime = mime))
        val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
        val echo = DecryptedMessage(res.message_id, tokens.userId ?: "me", caption, res.created_at?.let { parseIso(it) } ?: System.currentTimeMillis(), true, ref)
        append(conversationId, echo)
        return echo
    }

    /** Fetch + decrypt a media blob referenced by a message → PLAINTEXT bytes. */
    suspend fun fetchMedia(ref: MediaRef): ByteArray {
        val ciphertext = media.download(ref.mediaUrl)
        return decryptMedia(MediaKey(ref.key, ref.nonce, ref.sha256), ciphertext)
    }

    /** Fetch the server list, decrypt only unseen ids, persist, return full convo (asc). */
    suspend fun sync(conversationId: String, peerUserId: String): List<DecryptedMessage> =
      syncLock(conversationId).withLock {
        ensureLoaded()   // decrypt-once dedup + append below read/write the store
        flushPending(conversationId, peerUserId)   // push any queued sends first
        lastSyncHadDecryptFailure = false
        // Pass our own device_id so the server hands back only THIS device's per-device
        // ciphertext (each device has its own session, hence its own ciphertext).
        val devParam = e2e.deviceId?.let { "?device_id=$it" } ?: ""
        val env: MessagesResponse = api.requestAs("GET", "messages/conversation/$conversationId$devParam")
        android.util.Log.i("VOIID", "sync conv=$conversationId: server has ${env.messages.size} msgs")
        val myId = tokens.userId
        // "seen" = ALL stored ids INCLUDING tombstones. A decrypt-once Olm message that
        // failed can NEVER be re-decrypted (recovery comes from the peer RE-SENDING a new
        // message, not retrying the dead id). Retrying tombstones every sync just re-fails
        // and keeps re-triggering session_reset, which destroys the working session
        // ("no matching session" cascade). So tombstone once, never retry.
        val seen = (store[conversationId] ?: emptyList()).map { it.id }.toHashSet().apply { addAll(controlSeenIds()) }
        val newlyReceived = mutableListOf<String>()
        for (m in env.messages.asReversed()) {        // server DESC -> process ASC
            // Our OWN sent message: can't decrypt our ratchet output, but the server
            // reports the recipient's receipt state — advance Sent→Delivered→Seen even
            // if the live WS receipt push was missed (WS-independent status).
            // Our OWN account sent this. Two different cases, and conflating them is what
            // kept sent messages from ever appearing on a linked device — and made NOTE TO
            // SELF show nothing at all, since there every message has sender_id == myId.
            //
            //  * Sent from THIS device — there is genuinely nothing to decrypt (we never
            //    encrypt to ourselves), so only the receipt state matters.
            //  * Sent from ANOTHER of my devices — the fan-out addressed a real per-device
            //    ciphertext to this device precisely so it could sync. Decrypting it is the
            //    entire point; skipping it threw that ciphertext away.
            if (m.sender_id == myId) {
                val fromThisDevice = m.sender_device_id == null || m.sender_device_id == e2e.deviceId
                if (fromThisDevice || m.ciphertext == null) {
                    m.receipt_status?.let { applyReceipt(m.id, it) }
                    continue
                }
                // Falls through to the normal decrypt path below: a sibling device's message
                // is ordinary inbound ciphertext, just authored by us.
            }
            if (seen.contains(m.id)) continue
            // A null ciphertext means the server had no per-device blob for us yet (e.g. our
            // device_id wasn't resolved when this row's fan-out was written, or delivery to
            // this device is still pending) — skip for now, it'll show up once available.
            val wire = m.ciphertext?.let { decodeWire(it) } ?: run {
                android.util.Log.w("VOIID", "⚠️ skipping inbound id=${m.id}: no ciphertext for this device")
                null
            } ?: continue
            runCatching {
                // Session lookup keys on WHO SENT IT, not on who the conversation is with.
                // For a sibling-device sync (m.sender_id == myId) the session is with our own
                // account, so passing the conversation's peer would look up the wrong session
                // and fail to decrypt. Identical for every other message, where sender_id IS
                // the peer.
                val plain = decryptInbound(wire, m.sender_id, m.sender_device_id)
                android.util.Log.i("VOIID", "✅ decrypted inbound id=${m.id} senderDev=${m.sender_device_id}")
                // Location-protocol message (docs/LOCATION.md §4). Recognise it by
                // content_type OR by the `_vloc` marker — an iOS envelope that didn't route on
                // content_type still gets handled instead of rendering as "Unsupported message".
                if (m.content_type == "location" || LocationRelay.looksLikeEnvelope(plain)) {
                    // Render/capture DIRECTLY here (like iOS's ChatEngine.sync), not only via
                    // LocationRelay: the location engines are subscribed ONLY in the foreground,
                    // so a pin/live/map key arriving in the FCM BACKGROUND process would be lost.
                    // Renderable kinds (pin / live_start) become an inline bubble; a map_key is
                    // captured background-safe so the Map can decrypt this contact's fixes even
                    // if the Map engine was never alive. Then still fan out to any live engines
                    // for the WS fix stream + share-state timers.
                    handleLocationInbound(plain, m.sender_id, conversationId, parseIso(m.created_at))
                    LocationRelay.dispatchControl(plain, m.sender_id, conversationId)
                    markControlSeen(m.id)
                    newlyReceived.add(m.id)
                    return@runCatching
                }
                // ACTION envelopes decorate an EXISTING message rather than adding a bubble.
                val probeT = runCatching { ApiClient.json.decodeFromString(ActionProbe.serializer(), plain).t }.getOrNull()
                if (probeT == "msg_reaction" || probeT == "msg_delete") {
                    if (probeT == "msg_reaction") {
                        val e = ApiClient.json.decodeFromString(ReactionWire.serializer(), plain)
                        applyReaction(conversationId, e.target, m.sender_id, e.emoji)
                    } else {
                        val e = ApiClient.json.decodeFromString(DeleteWire.serializer(), plain)
                        // Only the ORIGINAL AUTHOR may delete: the target must be from this peer.
                        val t = store[conversationId]?.firstOrNull { it.serverId == e.target || it.id == e.target }
                        if (t != null && t.senderId == m.sender_id) applyDeleteForEveryone(conversationId, e.target)
                    }
                    // Keep the control id in the store (seen) but hidden from the UI.
                    append(conversationId, DecryptedMessage(m.id, m.sender_id, "", parseIso(m.created_at), false, control = true))
                    newlyReceived.add(m.id)
                    return@runCatching
                }
                if (probeT == "msg_reply") {
                    val e = ApiClient.json.decodeFromString(ReplyWire.serializer(), plain)
                    replace(conversationId, DecryptedMessage(m.id, m.sender_id, e.text, parseIso(m.created_at), false,
                        quotedId = e.quotedId, quotedPreview = e.quotedPreview, quotedSender = e.quotedSender))
                    newlyReceived.add(m.id)
                    return@runCatching
                }
                // A media message's plaintext is a JSON MediaEnvelope; text is just
                // the string. Detect via the server's content_type hint.
                val (caption, ref) = decodeEnvelope(plain, m.content_type)
                replace(conversationId, DecryptedMessage(m.id, m.sender_id, caption, parseIso(m.created_at), false, ref))
                newlyReceived.add(m.id)
            }.onFailure {
                android.util.Log.e("VOIID", "❌ inbound decrypt FAILED id=${m.id} senderDev=${m.sender_device_id}", it)
                // Tombstone it (failed==true) so the chat shows a placeholder, asks the
                // sender to re-establish the session, and RETRIES on the next sync.
                if (e2e.identity != null) {
                    lastSyncHadDecryptFailure = true
                    replace(conversationId, DecryptedMessage(m.id, m.sender_id,
                        "🔒 Message couldn’t be decrypted", parseIso(m.created_at), false, failed = true))
                }
            }
        }
        persist()
        // Mark just-received messages DELIVERED (double-grey tick on the sender) —
        // even if the chat isn't open. Read is marked separately when it's opened.
        if (newlyReceived.isNotEmpty()) markReceipts(newlyReceived, "delivered")
        messages(conversationId)
    }

    /** Apply a delivery/read receipt to one of OUR sent messages (persisted, never
     *  downgraded). Returns the conversation id so the UI can refresh just that chat. */
    fun applyReceipt(messageId: String, status: String): String? {
        ensureLoaded()   // a WS receipt can arrive while on the chat LIST (store not yet lazily
                         // loaded); without this the tick update would be dropped until re-sync.
        val rank = mapOf("sent" to 0, "delivered" to 1, "read" to 2)
        for ((cid, arr) in store) {
            val i = arr.indexOfFirst { it.isMine && (it.serverId == messageId || it.id == messageId) }
            if (i >= 0) {
                val cur = arr[i].deliveryStatus ?: "sent"
                if ((rank[status] ?: 0) > (rank[cur] ?: 0)) {
                    // Stamp the transition time ONCE (for the Message Info sheet). "read"
                    // implies delivered, so backfill a missing deliveredAt too.
                    val now = System.currentTimeMillis()
                    val delivered = arr[i].deliveredAt ?: if (status == "delivered" || status == "read") now else null
                    val read = arr[i].readAt ?: if (status == "read") now else null
                    arr[i] = arr[i].copy(deliveryStatus = status, deliveredAt = delivered, readAt = read)
                    markDirty(cid)
                    persist()
                }
                return cid
            }
        }
        return null
    }

    private suspend fun markReceipts(ids: List<String>, status: String) {
        if (ids.isEmpty()) return
        android.util.Log.i("VOIID", "📤 receipt $status x${ids.size}")
        // SEND THE DEVICE ID. The login token carries only user_id (POST /auth/firebase
        // issues no device claim), so without this the server records every receipt against a
        // NULL device — see the callerDeviceId note in routes/receipts.ts.
        val body = ApiClient.json.encodeToString(
            MarkReadBody.serializer(), MarkReadBody(ids, status, e2e.deviceId),
        )
        android.util.Log.i("VOIIDReceipt", "POST receipts/mark status=$status n=${ids.size} device=${e2e.deviceId}")
        // NOT the caller's coroutine. The 4-second poll that calls markRead lives on the CHAT
        // SCREEN's scope, so navigating away — or that loop being cancelled — killed the POST
        // mid-flight. `runCatching` then caught the CancellationException, released the ids,
        // and nothing retried them, because the thing that would have retried was the
        // coroutine that just died. Opening a chat and backing out promptly meant the read
        // receipt was never delivered at all.
        //
        // `receiptScope` outlives the screen, so a receipt that has STARTED will finish.
        receiptScope.launch {
            runCatching { api.request("POST", "receipts/mark", jsonBody = body) }
                .onSuccess { android.util.Log.i("VOIIDReceipt", "receipt $status OK for ${ids.size}") }
                .onFailure {
                    // PUT THEM BACK. `markRead` records an id as reported BEFORE the POST, so
                    // a dropped request would otherwise strand it forever — the sender stuck
                    // on Delivered with nothing to retry it. Re-marking on the next sync is
                    // cheap; never re-marking is unrecoverable.
                    if (status == "read") readReported.removeAll(ids.toSet())
                    android.util.Log.w("VOIIDReceipt", "receipt $status failed, will retry", it)
                }
        }
    }

    /**
     * Outlives any screen. Receipts are fire-and-forget by nature — no caller awaits the
     * result — but they must not be CANCELLED by the caller going away.
     */
    private val receiptScope = kotlinx.coroutines.CoroutineScope(
        kotlinx.coroutines.SupervisorJob() + kotlinx.coroutines.Dispatchers.IO,
    )

    /**
     * Decode a decrypted plaintext into (displayText, media?), keyed off the server's
     * content_type hint.
     *
     * BACK-COMPAT HAZARD (Stories, §5.3): a client that predates a typed content_type only tried
     * JSON-envelope decoding for "media", so a story_reply's JSON would render as raw text in a
     * bubble. This is handled TWO ways, both additive: (1) an explicit "story_reply" branch, and
     * (2) a defensive fallback — if the plaintext is a JSON object carrying a recognised "t", it is
     * decoded rather than shown verbatim. Never leave a raw JSON blob in a message bubble.
     */
    private fun decodeEnvelope(plain: String, contentType: String?): Pair<String, MediaRef?> {
        // MEDIA — decode by SHAPE, not just the content_type hint. A cross-platform message
        // (iOS → Android) whose hint didn't round-trip must STILL render as media, not raw
        // JSON. A real MediaEnvelope always has a non-empty media.mediaUrl.
        runCatching {
            val env = ApiClient.json.decodeFromString(MediaEnvelope.serializer(), plain)
            if (env.media.mediaUrl.isNotEmpty()) return env.caption to env.media
        }
        // Story reply → its body (reaction/text), never the raw JSON.
        if (plain.contains("\"story_reply\"")) {
            runCatching { return decodeStoryReplyText(plain) to null }
        }
        // Text reply envelope reaching here (no probe upstream) → show its text.
        if (plain.contains("\"msg_reply\"")) {
            runCatching {
                return ApiClient.json.decodeFromString(ReplyWire.serializer(), plain).text to null
            }
        }
        // Plain text is the normal case. But NEVER leak an unrecognised JSON object into a
        // bubble — that is the bug where Android/iOS envelopes rendered as literal `{...}`.
        val t = plain.trim()
        if (t.startsWith("{") && t.endsWith("}")) return "Unsupported message" to null
        return plain to null
    }

    /** Render a story_reply envelope as a chat bubble string (reaction prefix + text). */
    private fun decodeStoryReplyText(plain: String): String {
        val env = ApiClient.json.decodeFromString(StoryReplyWire.serializer(), plain)
        return env.reaction?.let { r -> if (env.text.isBlank()) r else "$r ${env.text}" } ?: env.text
    }

    /**
     * Server ids this device has already reported as READ.
     *
     * CONCURRENT-SAFE, and serialised by [readLock] below. `markRead` runs from at least two
     * coroutines at once — `openConversation` launches one and the 4-second poll runs
     * another — and a plain `mutableSetOf` is neither atomic nor safe under that.
     */
    private val readReported = java.util.Collections.newSetFromMap(
        java.util.concurrent.ConcurrentHashMap<String, Boolean>(),
    )

    /**
     * Serialises markRead.
     *
     * THE RACE THIS FIXES: `readReported.add()` claims an id BEFORE the POST is sent. Two
     * concurrent markReads — the open and the poll, which is exactly what happens the moment
     * a chat is opened — would have the first claim every id and the second find nothing to
     * send. If the first one's POST then failed or was cancelled mid-flight (its coroutine
     * belongs to the screen), the ids were released only after the second had already given
     * up, so the read receipt was simply never sent and the sender sat on Delivered.
     *
     * `sync()` has its own per-conversation lock; markRead was outside it entirely.
     */
    private val readLock = Mutex()

    /**
     * Mark inbound messages in a conversation READ → the server fans out a `receipt` WS event
     * to the senders, and the message stops counting toward their unread badge.
     *
     * ONLY EVER CALL THIS FOR A CHAT THE USER IS LOOKING AT. It used to run from every
     * `syncMessages`, including the one `handleIncoming` fires for a background push — so a
     * message was marked read the instant it arrived in a chat the user had never opened.
     *
     * Three filters, each fixing a real defect:
     *   - `!control`  — control envelopes (reactions, deletes, location keys) are not
     *                   messages; marking them read is meaningless traffic.
     *   - `!failed`   — a tombstone we could not decrypt has not been READ by anyone. Saying
     *                   otherwise tells the sender it was seen when it never rendered.
     *   - `readReported` — this resent EVERY inbound id on EVERY sync. A chat with 200
     *                   messages POSTed 200 ids each time it was opened or polled, and the
     *                   server looped an UPDATE per id. Only newly-read ids go now.
     */
    suspend fun markRead(conversationId: String) = readLock.withLock {
        ensureLoaded()
        val inbound = (store[conversationId] ?: emptyList())
            .filter { !it.isMine && !it.control && !it.failed }
        val ids = inbound.map { it.id }.filter { readReported.add(it) }
        // Diagnostic: distinguishes "nothing inbound to read" from "already reported this
        // session" from "sent". Without it, a silent no-op here is indistinguishable from a
        // failed POST, which is what made "read never happens" impossible to place.
        android.util.Log.i(
            "VOIIDReceipt",
            "markRead conv=$conversationId inbound=${inbound.size} new=${ids.size}",
        )
        if (ids.isEmpty()) return
        markReceipts(ids, "read")
    }

    private suspend fun decryptInbound(wire: WireMessage, peerUserId: String, senderDeviceId: String?): String {
        // Decrypt with the session for the SPECIFIC (peer, sending device) that produced
        // this ciphertext — the server already handed us only our device's copy, and the
        // message names which of the sender's devices encrypted it.
        val devId = senderDeviceId ?: "default"
        val list = candidateSessions(peerUserId, devId)
        // 1. Try EVERY known session for that device pair (glare → multiple). A non-matching
        //    session fails cleanly; the matching one decrypts (including later PreKey msgs of
        //    an already-accepted session, so no re-accept / no extra OTK consumed).
        for (s in list) {
            val data = runCatching { s.decrypt(wire) }.getOrNull()
            if (data != null) {
                saveSessions(peerUserId, devId)
                return data.decodeToString()
            }
        }
        // 2. No existing session matched. Only a PreKey message can establish one.
        if (wire.msgType != 0uL) throw ApiError.Http(422, "no matching session for message")
        // 2b. DEDUP (libsignal promote_matching_session equivalent): if we ALREADY hold
        //     the session this PreKey would establish (same session id), it's a replay /
        //     out-of-order PreKey for a known session — never re-accept (that would burn
        //     another one-time key). Decrypt with the matching session instead.
        val incomingId = uniffi.voiid.prekeySessionId(wire)
        if (incomingId != null) {
            list.firstOrNull { it.sessionId() == incomingId }?.let { s ->
                val data = s.decrypt(wire)   // throws if genuinely undecryptable
                saveSessions(peerUserId, devId)
                return data.decodeToString()
            }
        }
        // 3. Accept a NEW inbound session and APPEND it (do not discard the others).
        //    vodozemac decrypts before consuming the OTK, so a failed accept is safe;
        //    a successful one consumes exactly one OTK for this distinct PreKey.
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val (peerKey, resolvedDev) = peerIdentity(peerUserId, senderDeviceId)
        verifyAndPinIdentity(peerKey, peerUserId, resolvedDev)   // anti-MITM (TOFU, per device)
        val accepted = id.acceptSession(peerKey, wire)
        list.add(accepted.session)
        saveSessions(peerUserId, devId)
        e2e.persistIdentity()   // acceptSession consumed a one-time key — save it or the
                                // first message is lost on restart (resurrected stale OTK).
        return accepted.plaintext.decodeToString()
    }

    // MARK: - Multi-device fan-out (encrypt once per target device)

    /** A remote device we must deliver to: a conversation peer's device, or one of our
     *  own OTHER (linked) devices. [userId] owns [deviceId]. */
    private data class TargetDevice(val userId: String, val deviceId: String)

    /**
     * Encrypt [plaintext] ONCE PER TARGET DEVICE and return the per-device bundle
     * (`[{recipient_device_id, ciphertext}]`). Targets = every active device of the
     * conversation peer PLUS our own OTHER devices, EXCLUDING this sending device.
     * Devices we can't build a session for (no published prekey) are skipped + logged
     * so the rest still deliver; if NOTHING is deliverable we throw a retryable error
     * so the message stays pending and re-sends once prekeys appear.
     */
    private suspend fun encryptFanout(plaintext: ByteArray, peerUserId: String): List<DeviceCiphertext> {
        val targets = resolveTargets(peerUserId)

        // NOTE TO SELF on a single device: `peerUserId` is our own id, so resolveTargets
        // correctly returns our other devices MINUS this one — an empty list when there is
        // only one. That is not a failure and must not be retried forever: there is genuinely
        // nowhere to send, because the only reader already holds the plaintext.
        //
        // The moment a second device is linked it starts receiving new notes like any other
        // message. Notes written before that stay on the device that wrote them — there is no
        // ciphertext on the server to backfill from, which is the honest consequence of
        // end-to-end encryption rather than a gap to paper over. Mirrors iOS.
        if (targets.isEmpty() && peerUserId == tokens.userId) return emptyList()

        if (targets.isEmpty()) throw ApiError.Http(409, "no target devices for peer")
        val out = mutableListOf<DeviceCiphertext>()
        // Group by owning user so we fetch each user's prekey bundles at most once per
        // send (each GET consumes a one-time key per device — don't call it per device).
        for ((userId, devs) in targets.groupBy { it.userId }) {
            val needBundles = devs.any { candidateSessions(userId, it.deviceId).isEmpty() }
            val bundles = if (needBundles) runCatching { fetchBundles(userId) }.getOrDefault(emptyMap()) else emptyMap()
            for (t in devs) {
                val session = outboundSessionFor(t, bundles)
                if (session == null) {
                    android.util.Log.w("VOIID", "⏭️ fan-out skip device=${t.deviceId} user=${t.userId} (no session/prekey)")
                    continue
                }
                val wire = session.encrypt(plaintext)
                saveSessions(t.userId, t.deviceId)
                out.add(DeviceCiphertext(t.deviceId, encodeWire(wire)))
            }
        }
        // Nothing deliverable (e.g. peer hasn't published prekeys yet) — retryable, like
        // the legacy single-device path, so the 4s poll re-sends when keys appear.
        if (out.isEmpty()) throw ApiError.Http(409, "peer has no available prekeys")
        return out
    }

    /** All target devices for a send: peer's active devices + our OWN other devices,
     *  minus this sending device. */
    private suspend fun resolveTargets(peerUserId: String): List<TargetDevice> {
        val targets = mutableListOf<TargetDevice>()
        // THIS device is never a target — you do not encrypt to yourself. Filtering here
        // rather than only in the own-devices block below is what makes NOTE TO SELF work:
        // there peerUserId IS my id, so the peer loop would otherwise return the sending
        // device itself, and the note would be encrypted to the device that wrote it.
        val myId = tokens.userId
        val myDev = e2e.deviceId

        val peerDevs: DevicesResponse = api.requestAs("GET", "devices/$peerUserId")
        peerDevs.devices
            .filterNot { peerUserId == myId && it.id == myDev }
            .forEach { targets.add(TargetDevice(peerUserId, it.id)) }

        // Our own OTHER devices (linked-device sync of sent messages), excluding this one.
        // SKIPPED when the peer is me: the loop above already returned exactly those devices,
        // and appending them again meant every note was encrypted TWICE to each linked device
        // — two ratchet steps for one message, one of whose outputs the server then discards
        // as a duplicate row, leaving the receiving ratchet to absorb a skipped key.
        if (myId != null && peerUserId != myId) {
            val mine: DevicesResponse = api.requestAs("GET", "devices/$myId")
            mine.devices.filter { it.id != myDev }.forEach { targets.add(TargetDevice(myId, it.id)) }
        }
        return targets
    }

    /** Get (reuse) or establish the outbound session for one target device. Returns null
     *  — skip this device — when it has no bundle / no available one-time prekey. */
    private fun outboundSessionFor(t: TargetDevice, bundles: Map<String, BundleDTO>): Session? {
        // Reuse the stable (first/oldest) existing session so we don't keep minting new ones.
        candidateSessions(t.userId, t.deviceId).firstOrNull()?.let { return it }
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val b = bundles[t.deviceId] ?: return null           // no bundle for this device
        val otk = b.one_time_prekey ?: return null           // no available prekey → skip
        verifyAndPinIdentity(b.identity_public_key, t.userId, t.deviceId)  // anti-MITM (TOFU, per device)
        val s = id.startSession(b.identity_public_key, otk.public_key)
        candidateSessions(t.userId, t.deviceId).add(s)
        saveSessions(t.userId, t.deviceId)
        return s
    }

    /** Fetch a user's prekey bundles, keyed by device id (one bundle per device; each
     *  consumes one of that device's one-time prekeys). */
    private suspend fun fetchBundles(userId: String): Map<String, BundleDTO> {
        val env: PrekeysResponse = api.requestAs("GET", "prekeys/$userId")
        return env.bundles.mapNotNull { b -> b.device_id?.let { it to b } }.toMap()
    }

    // MARK: - Broadcast fan-out (Stories) — encryptFanout widened from one peer to an audience
    //
    // Stories reuse ALL of the single-peer fan-out's hard-won correctness (per-remote-device
    // session keying, OTK fetched once per user, glare tolerance, append-never-overwrite on
    // accept) rather than reimplementing it, which would produce undecryptable stories. The ONLY
    // difference is the target set: an arbitrary list of recipient users instead of one peer.

    /** One target device's ciphertext in a broadcast bundle. Public so StoryEngine can consume it. */
    data class BroadcastCiphertext(val recipientDeviceId: String, val ciphertext: String)

    /**
     * Encrypt [plaintext] ONCE PER TARGET DEVICE across every active device of [recipientUserIds]
     * (plus, when [includeOwnDevices], our own OTHER devices — so linked devices see "My story"
     * and can collect view receipts), EXCLUDING this posting device. Devices with no published
     * prekey are skipped + logged, never fatal: partial delivery is already the norm on this
     * transport, and a story that fails entirely because one contact ran dry is worse.
     */
    suspend fun encryptBroadcast(
        plaintext: ByteArray,
        recipientUserIds: List<String>,
        includeOwnDevices: Boolean = true,
    ): List<BroadcastCiphertext> {
        val myId = tokens.userId
        val myDev = e2e.deviceId
        val userIds = LinkedHashSet(recipientUserIds)
        if (includeOwnDevices && myId != null) userIds.add(myId)
        val targets = mutableListOf<TargetDevice>()
        for (uid in userIds) {
            // Retried, then LOGGED. A bare `?: continue` meant a transient network blip
            // silently resolved ZERO devices for that recipient: the post "succeeded" while
            // that person never received it, with nothing to explain why.
            var devs = runCatching { api.requestAs<DevicesResponse>("GET", "devices/$uid") }.getOrNull()
            if (devs == null) {
                kotlinx.coroutines.delay(300)
                devs = runCatching { api.requestAs<DevicesResponse>("GET", "devices/$uid") }
                    .onFailure { android.util.Log.w("VOIID", "⏭️ broadcast: device lookup FAILED for $uid — they will NOT receive this", it) }
                    .getOrNull()
            }
            if (devs == null) continue
            if (devs.devices.isEmpty()) {
                android.util.Log.w("VOIID", "⏭️ broadcast: $uid has no active devices — they will NOT receive this")
            }
            for (d in devs.devices) {
                if (uid == myId && d.id == myDev) continue    // never fan out to the posting device
                targets.add(TargetDevice(uid, d.id))
            }
        }
        val out = mutableListOf<BroadcastCiphertext>()
        // One prekey fetch per user (each GET consumes a one-time key per device) — never per device.
        for ((uid, devs) in targets.groupBy { it.userId }) {
            val needBundles = devs.any { candidateSessions(uid, it.deviceId).isEmpty() }
            val bundles = if (needBundles) runCatching { fetchBundles(uid) }.getOrDefault(emptyMap()) else emptyMap()
            for (t in devs) {
                val session = outboundSessionFor(t, bundles)
                if (session == null) {
                    android.util.Log.w("VOIID", "⏭️ broadcast skip device=${t.deviceId} user=${t.userId} (no prekey)")
                    continue
                }
                val wire = session.encrypt(plaintext)
                saveSessions(t.userId, t.deviceId)
                out.add(BroadcastCiphertext(t.deviceId, encodeWire(wire)))
            }
        }
        return out
    }

    /**
     * Decrypt a story-key ciphertext from a KNOWN sender (the author). Serialized per sender via
     * the same [syncLock] the 1:1 sync uses, so two concurrent story deliveries from one author
     * can't race that author's one-time key and strand the earliest key permanently (§3.5).
     */
    suspend fun decryptBroadcast(ciphertextB64: String, senderUserId: String, senderDeviceId: String?): String? =
        syncLock(senderUserId).withLock {
            val wire = decodeWire(ciphertextB64)
            if (wire == null) {
                // Distinct from a crypto failure: the base64/JSON wrapper itself was malformed,
                // which points at the SENDER's encoding rather than at our session state.
                android.util.Log.w("VOIID", "story key: wire decode failed from=$senderUserId device=$senderDeviceId")
                return@withLock null
            }
            // The exception was swallowed by a bare getOrNull(), leaving "⚠️ story key
            // undecryptable" as the only trace — which cannot distinguish "no session with that
            // device" from "session exists but the ratchet rejected it". Both are real causes
            // with completely different fixes, so log the reason and the session count.
            runCatching { decryptInbound(wire, senderUserId, senderDeviceId) }
                .onFailure { e ->
                    val known = senderDeviceId?.let { candidateSessions(senderUserId, it).size } ?: -1
                    android.util.Log.w(
                        "VOIID",
                        "story key decrypt FAILED from=$senderUserId device=$senderDeviceId " +
                            "type=${wire.msgType} sessions=$known: ${e.message}",
                    )
                }
                .getOrNull()
        }

    /**
     * Decrypt a view receipt whose sender the server deliberately does NOT name (story_receipts
     * has no viewer_user_id column). We try every ESTABLISHED session we already hold; the one
     * that MACs the ciphertext decrypts it, exactly like the candidate loop in [decryptInbound]
     * (a non-matching session fails cleanly without touching its ratchet state). A receipt that
     * would need a brand-new inbound session accepted can't be attributed without a sender id and
     * is dropped — acceptable because receipts are opt-in and best-effort, and the session the
     * author minted while fanning the story out is already in memory for exactly these viewers.
     */
    fun decryptStoryReceipt(ciphertextB64: String, audienceUserIds: List<String> = emptyList()): String? {
        val wire = decodeWire(ciphertextB64) ?: return null
        // Load the audience's sessions from DISK before scanning. `sessions` is a LAZY cache
        // populated only by candidateSessions() — so on a cold start (the usual case when you
        // open Moments to check your views) it is EMPTY, every receipt failed to decrypt, and
        // the viewer list was permanently blank. Receipts are deliver-once, so each miss was
        // unrecoverable. iOS passes the audience for exactly this reason; Android scanned only
        // whatever happened to be in memory. Restoring by device is what makes the sessions the
        // author minted while fanning the story out available to match against.
        for (uid in audienceUserIds) {
            val devices = runCatching { deviceIdsWithSessions(uid) }.getOrDefault(emptyList())
            for (deviceId in devices) candidateSessions(uid, deviceId)
        }
        for (list in sessions.values) for (s in list) {
            runCatching { s.decrypt(wire) }.getOrNull()?.let { return it.decodeToString() }
        }
        return null
    }

    /** Every device id we hold a PERSISTED session for with [userId], read straight from prefs.
     *  Lets the receipt path rehydrate sessions it has never touched this process. */
    private fun deviceIdsWithSessions(userId: String): List<String> {
        val prefix = "sess::$userId::"
        return prefs.all.keys.filter { it.startsWith(prefix) }.map { it.removePrefix(prefix) }
    }

    /**
     * Send a story reply as an ORDINARY 1:1 message (content_type "story_reply") into the chat
     * with the author. It appears as a normal message for both parties, gets normal receipts, and
     * does NOT expire with the story. Reuses the broadcast fan-out (author's devices + our own),
     * persists a local echo, and returns it.
     */
    suspend fun sendStoryReply(
        conversationId: String, authorId: String,
        storyId: String, storyCreatedAtMs: Long,
        text: String, reaction: String?,
    ): DecryptedMessage {
        val env = StoryReplyWire(
            storyId = storyId, storyAuthorId = authorId, storyCreatedAt = storyCreatedAtMs,
            text = text, reaction = reaction,
        )
        val json = ApiClient.json.encodeToString(StoryReplyWire.serializer(), env)
        val bcast = encryptBroadcast(json.encodeToByteArray(), listOf(authorId), includeOwnDevices = true)
        if (bcast.isEmpty()) throw ApiError.Http(409, "author has no available prekeys")
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(
            SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "story_reply"),
        )
        val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
        val display = reaction?.let { r -> if (text.isBlank()) r else "$r $text" } ?: text
        val echo = DecryptedMessage(
            res.message_id, tokens.userId ?: "me", display,
            res.created_at?.let { parseIso(it) } ?: System.currentTimeMillis(), true,
        )
        append(conversationId, echo)
        return echo
    }

    // MARK: - Message actions (reaction / delete-for-everyone / reply / forward)
    //
    // Mirror of iOS MessageActionWire + the ChatEngine senders. Each rides the SAME per-device
    // E2EE fan-out; the server sees only opaque ciphertext + a content_type hint. Receivers
    // apply them in [sync] by probing the plaintext "t" discriminator. Envelope JSON field
    // names MUST match iOS byte-for-byte.
    //
    // @EncodeDefault ON `t` AND `v`, mandatory. kotlinx omits default-valued fields (ApiClient's
    // Json leaves `encodeDefaults` off), and `t` is the discriminator the receiver probes to
    // decide what a plaintext IS — so without this a reaction serialises to `{"target":"…"}`
    // and arrives indistinguishable from an ordinary message. Unlike the receipt bug there is
    // no server-side default to mask it: the server only sees ciphertext. See
    // ReceiptEncodingTest, and MapPresenceService, which already had to solve this.
    @Serializable private data class ReactionWire(@EncodeDefault val t: String = "msg_reaction", @EncodeDefault val v: Int = 1, val target: String, val emoji: String? = null)
    @Serializable private data class DeleteWire(@EncodeDefault val t: String = "msg_delete", @EncodeDefault val v: Int = 1, val target: String)
    @Serializable private data class ReplyWire(@EncodeDefault val t: String = "msg_reply", @EncodeDefault val v: Int = 1, val text: String, val quotedId: String, val quotedPreview: String, val quotedSender: String)
    @Serializable private data class ActionProbe(val t: String? = null)

    /** Send (or clear, emoji=null) a reaction to [targetServerId]. No bubble. */
    suspend fun sendReaction(targetServerId: String, emoji: String?, conversationId: String, peerUserId: String) {
        val json = ApiClient.json.encodeToString(ReactionWire.serializer(), ReactionWire(target = targetServerId, emoji = emoji))
        val bcast = encryptBroadcast(json.encodeToByteArray(), listOf(peerUserId), includeOwnDevices = true)
        if (bcast.isEmpty()) return
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "msg_reaction"))
        api.requestAs<SendResponse>("POST", "messages/send", jsonBody = body)
        applyReaction(conversationId, targetServerId, tokens.userId ?: "me", emoji)
    }

    /** Ask recipients to tombstone [targetServerId] (honoured only from the original author). */
    suspend fun sendDeleteForEveryone(targetServerId: String, conversationId: String, peerUserId: String) {
        val json = ApiClient.json.encodeToString(DeleteWire.serializer(), DeleteWire(target = targetServerId))
        val bcast = encryptBroadcast(json.encodeToByteArray(), listOf(peerUserId), includeOwnDevices = true)
        if (bcast.isEmpty()) return
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "msg_delete"))
        api.requestAs<SendResponse>("POST", "messages/send", jsonBody = body)
        applyDeleteForEveryone(conversationId, targetServerId)
    }

    /** Send a text reply quoting another message. Renders as a normal bubble with a quote. */
    suspend fun sendReply(text: String, quotedId: String, quotedPreview: String, quotedSender: String,
                          conversationId: String, peerUserId: String): DecryptedMessage {
        val env = ReplyWire(text = text, quotedId = quotedId, quotedPreview = quotedPreview, quotedSender = quotedSender)
        val json = ApiClient.json.encodeToString(ReplyWire.serializer(), env)
        val bcast = encryptBroadcast(json.encodeToByteArray(), listOf(peerUserId), includeOwnDevices = true)
        if (bcast.isEmpty()) throw ApiError.Http(409, "peer has no available prekeys")
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "msg_reply"))
        val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
        val echo = DecryptedMessage(res.message_id, tokens.userId ?: "me", text,
            res.created_at?.let { parseIso(it) } ?: System.currentTimeMillis(), true,
            quotedId = quotedId, quotedPreview = quotedPreview, quotedSender = quotedSender)
        append(conversationId, echo)
        return echo
    }

    /** Forward existing media WITHOUT re-uploading — re-send its MediaRef (key stays E2E). */
    suspend fun forwardMedia(ref: MediaRef, caption: String, conversationId: String, peerUserId: String): DecryptedMessage {
        val env = MediaEnvelope(media = ref, caption = caption)
        val json = ApiClient.json.encodeToString(MediaEnvelope.serializer(), env)
        val bcast = encryptBroadcast(json.encodeToByteArray(), listOf(peerUserId), includeOwnDevices = true)
        if (bcast.isEmpty()) throw ApiError.Http(409, "peer has no available prekeys")
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "media", media_url = ref.mediaUrl, media_mime = ref.mime))
        val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
        val echo = DecryptedMessage(res.message_id, tokens.userId ?: "me", caption,
            res.created_at?.let { parseIso(it) } ?: System.currentTimeMillis(), true, media = ref, forwarded = true)
        append(conversationId, echo)
        return echo
    }

    // Local appliers — shared by senders (our own) and inbound (a peer's).
    fun applyReaction(convId: String, target: String, fromUserId: String, emoji: String?) {
        val arr = store[convId] ?: return
        val i = arr.indexOfFirst { it.serverId == target || it.id == target }
        if (i < 0) return
        val map = (arr[i].reactions ?: emptyMap()).toMutableMap()
        if (emoji != null) map[fromUserId] = emoji else map.remove(fromUserId)
        arr[i] = arr[i].copy(reactions = map.ifEmpty { null })
        markDirty(convId)
        persist()
    }
    fun applyDeleteForEveryone(convId: String, target: String) {
        val arr = store[convId] ?: return
        val i = arr.indexOfFirst { it.serverId == target || it.id == target }
        if (i < 0) return
        arr[i] = arr[i].copy(deletedForEveryone = true, text = "", media = null, reactions = null)
        markDirty(convId)
        persist()
    }

    /**
     * Send a SILENT E2EE location-protocol control envelope (docs/LOCATION.md P2) to a 1:1 peer
     * over the Double Ratchet — map_key / map_off / live_*. content_type "location" so the server
     * routes it as an ordinary message (content-free wake push) while the client SUPPRESSES the
     * bubble (see the `content_type == "location"` intercept in [sync]). Renders NOTHING locally —
     * this is control, not chat, and [envelopeJson] (which carries the shareKey for a map_key)
     * never leaves E2E. Mirrors [sendStoryReply]'s broadcast fan-out, recipient-only.
     */
    suspend fun sendLocationControl(envelopeJson: String, conversationId: String, peerUserId: String) {
        val bcast = encryptBroadcast(envelopeJson.encodeToByteArray(), listOf(peerUserId), includeOwnDevices = false)
        if (bcast.isEmpty()) throw ApiError.Http(409, "peer has no available prekeys")
        val messages = bcast.map { DeviceCiphertext(it.recipientDeviceId, it.ciphertext) }
        val body = ApiClient.json.encodeToString(
            SendBundleBody.serializer(),
            SendBundleBody(conversationId, e2e.deviceId, messages, content_type = "location"),
        )
        api.requestAs<SendResponse>("POST", "messages/send", jsonBody = body)
    }

    // Ids of consumed silent location-control messages (docs/LOCATION.md P2). Recorded so a
    // decrypt-once Olm control message is never re-fetched and re-failed into a bogus tombstone
    // bubble. A handful per share — persisted in the chat prefs, unioned into `seen` on sync.
    /**
     * True if [messageId] was consumed as a silent location-protocol control envelope
     * (map_key / map_off / live_*) rather than becoming a chat message.
     *
     * The FCM path needs this to tell "the wake carried a control envelope, post NOTHING"
     * apart from "decrypt failed, post the generic fallback" — both leave the store without
     * a new message, so without this a map_key surfaced as a phantom "New message".
     */
    fun wasControlMessage(messageId: String): Boolean = controlSeenIds().contains(messageId)

    private fun controlSeenIds(): Set<String> = prefs.getStringSet("loc_control_seen", emptySet()) ?: emptySet()
    private fun markControlSeen(id: String) {
        val cur = HashSet(controlSeenIds()); cur.add(id)
        prefs.edit().putStringSet("loc_control_seen", cur).apply()
    }

    /** Wire shape of a story_reply envelope (kept local so `net` needn't depend on `model`). */
    @Serializable
    private data class StoryReplyWire(
        @EncodeDefault val v: Int = 1, @EncodeDefault val t: String = "story_reply",
        val storyId: String, val storyAuthorId: String, val storyCreatedAt: Long,
        val text: String, val reaction: String? = null,
    )

    // MARK: - Identity pinning (anti-MITM / "safety numbers", trust-on-first-use)

    /** Pinned PER (peer, device): a multi-device peer legitimately has a different
     *  identity key per device, so keying the pin by device avoids a false MITM
     *  rejection while still catching a real key-swap on a given device. */
    private fun verifyAndPinIdentity(identityKey: String, peerUserId: String, deviceId: String?) {
        val pinName = "idpin_${peerUserId}_${deviceId ?: "default"}"
        val pinned = prefs.getString(pinName, null)
        if (pinned != null) {
            if (pinned != identityKey) {
                throw ApiError.Http(495, "peer identity key changed — possible MITM; verify safety number before continuing")
            }
        } else {
            prefs.edit().putString(pinName, identityKey).apply()
        }
    }

    // MARK: - Peer key resolution

    /** One of the peer's devices, for safety-number comparison. */
    data class PeerIdentity(val id: String, val identityKey: String)

    /**
     * EVERY device the peer has published a key for, for the safety-number screen.
     *
     * ALL of them, not just the first: a safety number is per DEVICE PAIR, because each device
     * has its own identity key. A contact with a phone and a tablet has two numbers and both must
     * match — collapsing them into one would show "verified" while an unverified second device
     * sat silently on the account, which is precisely the thing this feature exists to catch.
     *
     * Mirrors iOS `ChatEngine.peerIdentities`.
     */
    suspend fun peerIdentities(userId: String): List<PeerIdentity> {
        val res: DevicesResponse = api.requestAs("GET", "devices/$userId")
        return res.devices.map { PeerIdentity(it.id, it.identity_public_key) }
    }

    /** Peer's identity key + device id, resolving the SPECIFIC device that sent the
     *  message (a multi-device sender may use a non-first device); falls back to first. */
    private suspend fun peerIdentity(userId: String, deviceId: String?): Pair<String, String> {
        val env: DevicesResponse = api.requestAs("GET", "devices/$userId")
        val d = (deviceId?.let { id -> env.devices.firstOrNull { it.id == id } }) ?: env.devices.firstOrNull()
            ?: throw ApiError.Http(404, "peer has no device")
        return Pair(d.identity_public_key, d.id)
    }

    // MARK: - Group message store (MLS)
    //
    // Group messages are E2EE via MLS (see GroupEngine), but their DECRYPTED plaintext
    // lives in the SAME on-disk store as 1:1 messages so the existing chat UI renders
    // them unchanged. GroupEngine owns the crypto; these helpers only persist results.

    /** True if this conversation already holds a message with [id] (decrypt-once dedup). */
    fun hasMessage(conversationId: String, id: String): Boolean {
        ensureLoaded()
        return store[conversationId]?.any { it.id == id } == true
    }

    /** Persist a local echo of a group message WE just sent (we can't decrypt our own
     *  MLS ratchet output, so we store the plaintext directly). Returns the stored row. */
    fun storeGroupOutgoing(conversationId: String, text: String): DecryptedMessage {
        val msg = DecryptedMessage(
            id = java.util.UUID.randomUUID().toString(),
            senderId = tokens.userId ?: "me", text = text,
            createdAt = System.currentTimeMillis(), isMine = true,
            // A group send is fire-and-forget over the fan-out relay; mark it delivered
            // so the UI shows a sent state (no per-member receipts in this increment).
            deliveryStatus = "sent",
        )
        append(conversationId, msg)
        return msg
    }

    /** Persist a decrypted INBOUND group message (idempotent by [id]). */
    fun storeGroupInbound(conversationId: String, id: String, senderId: String, text: String, createdAt: Long) {
        if (hasMessage(conversationId, id)) return
        replace(conversationId, DecryptedMessage(id, senderId, text, createdAt, isMine = false))
        persist()
    }

    /**
     * Persist a local echo of a location message WE just sent (pin or the live_start marker), so
     * it renders as a bubble immediately. The keyless [ref] is safe to store; the shareKey lives
     * in the secure store. See docs/LOCATION.md §4 / [LocationShareEngine].
     */
    fun storeLocationOutgoing(conversationId: String, ref: LocationRef): DecryptedMessage {
        val msg = DecryptedMessage(
            id = java.util.UUID.randomUUID().toString(),
            senderId = tokens.userId ?: "me", text = "",
            createdAt = System.currentTimeMillis(), isMine = true,
            location = ref, deliveryStatus = "sent",
        )
        append(conversationId, msg)
        return msg
    }

    /**
     * Persist a decrypted INBOUND location bubble (idempotent by [id]). The message itself came
     * off the ratchet/MLS and was intercepted as content_type "location" (or `_vloc`) and handed
     * to the location engine via [LocationRelay]; this only records the renderable projection.
     */
    fun storeLocationInbound(conversationId: String, id: String, senderId: String, ref: LocationRef, createdAt: Long) {
        if (hasMessage(conversationId, id)) return
        replace(conversationId, DecryptedMessage(id, senderId, "", createdAt, isMine = false, location = ref))
        persist()
    }

    /**
     * Decrypted-side handling of an inbound location envelope, run in BOTH the foreground and
     * the FCM background process — mirrors iOS handling directly in ChatEngine.sync. Renders a
     * pin / live_start as an inline bubble and captures share/map keys, so NOTHING depends on a
     * foreground-only engine subscription (the cause of iOS location "not coming" / showing as
     * "Unsupported message", and of live-Map contacts never appearing). Idempotent with
     * [LocationShareEngine.onControl] — it uses the SAME message ids and key stores, so a
     * message processed by both paths never double-renders.
     */
    private fun handleLocationInbound(plain: String, senderId: String, conversationId: String, createdAt: Long) {
        val env = runCatching {
            ApiClient.json.decodeFromString(com.voiid.app.model.LocationEnvelope.serializer(), plain)
        }.getOrNull() ?: return
        when (env.k) {
            "pin" -> {
                val lat = env.lat ?: return; val lon = env.lon ?: return
                storeLocationInbound(conversationId, "locpin_${senderId}_${env.t}", senderId,
                    LocationRef(kind = "pin", lat = lat, lon = lon, acc = env.acc ?: 0.0, label = env.label), createdAt)
            }
            "live_start" -> {
                val shareId = env.s ?: return
                // Same key store LocationShareEngine reads, so the WS fix stream can decrypt
                // this share once the app is foregrounded.
                env.key?.let { SecurePrefs.open(appContext, "voiid_location").edit().putString(shareId, it).apply() }
                // Do NOT require coordinates: an iOS live_start carries none (iOS drives the
                // marker purely from the WS fix stream). Store the bubble anyway — it shows a
                // "locating…" state until the first fix, then the live view (rehydrated from the
                // server on chat open) drives the moving position. Dropping here was why an iOS
                // live share never appeared on Android.
                val expiresAt = env.expiresAt ?: (createdAt + 3_600_000L)
                storeLocationInbound(conversationId, "loclive_$shareId", senderId,
                    LocationRef(kind = "live_start", shareId = shareId, lat = env.lat, lon = env.lon,
                        acc = env.acc ?: 0.0, expiresAt = expiresAt, cadenceSeconds = env.cadence), createdAt)
            }
            "live_rekey" ->
                env.s?.let { sid -> env.key?.let { SecurePrefs.open(appContext, "voiid_location").edit().putString(sid, it).apply() } }
            "map_key" -> {
                val shareId = env.s ?: return
                val keyB64 = env.key ?: return
                // Shared constant with MapPresenceEngine.onControl — these two capture paths
                // MUST agree, or the same key expires at different times depending only on
                // whether the app was foregrounded when it arrived.
                MapInboundKeyStore.put(appContext, shareId, senderId, keyB64,
                    env.expiresAt ?: (System.currentTimeMillis() + MapConstants.DEFAULT_KEY_TTL_MS))
            }
            "map_off" -> env.s?.let { MapInboundKeyStore.remove(appContext, it) }
            // live_stop → LocationShareEngine ends the inbound view; nothing to render here.
        }
    }

    /** Tombstone a group message we couldn't decrypt so it isn't retried forever
     *  (an MLS application message can't be safely re-decrypted). */
    fun storeGroupTombstone(conversationId: String, id: String, senderId: String, createdAt: Long) {
        if (hasMessage(conversationId, id)) return
        replace(conversationId, DecryptedMessage(id, senderId, "🔒 Message couldn’t be decrypted", createdAt, isMine = false, failed = true))
        persist()
    }

    // MARK: - Local message store (decrypt-once; encrypted at rest)

    private fun append(convId: String, m: DecryptedMessage, persist: Boolean = true) {
        ensureLoaded()   // never mutate/persist an unloaded store (would clobber on-disk history)
        val arr = store.getOrPut(convId) { mutableListOf() }
        if (arr.any { it.id == m.id }) return
        arr.add(m)
        markDirty(convId)
        if (persist) persist()
    }

    /** Insert, or REPLACE an existing entry with the same id in place (keeps order).
     *  Lets a tombstone that later decrypts be upgraded to the real message. */
    private fun replace(convId: String, m: DecryptedMessage) {
        ensureLoaded()
        val arr = store.getOrPut(convId) { mutableListOf() }
        val i = arr.indexOfFirst { it.id == m.id }
        if (i >= 0) arr[i] = m else arr.add(m)
        markDirty(convId)
    }

    // The message store is decoded LAZILY on first access, not at init — that whole-file JSON
    // decode used to run on the app-launch / chat-LIST path. The list now renders from Room
    // (LocalStore), so the store is only decoded when a chat is opened / synced.
    @Volatile private var storeLoaded = false

    /** Decode the store on first access. Idempotent. */
    private fun ensureLoaded() { if (!storeLoaded) loadStore() }

    // PHASE 2: per-conversation SHARDED storage. The store used to be one voiid_messages.json
    // re-encoded IN FULL on every message (O(entire history), the scalability wall). It's now
    // one file per conversation under messages/<convId>.json, and persist() rewrites ONLY the
    // conversations changed this turn (the dirty set). The whole set is still held in memory
    // (single process; no cross-process reload), so reads/dedup are unchanged. The legacy blob
    // is migrated once and KEPT for rollback.
    private val shardSerializer = ListSerializer(DecryptedMessage.serializer())
    private val messagesDir = java.io.File(appContext.filesDir, "messages").apply { mkdirs() }
    private fun shardFile(convId: String) = java.io.File(messagesDir, "$convId.json")
    private val dirtyConversations = java.util.Collections.synchronizedSet(mutableSetOf<String>())
    private fun markDirty(convId: String) { dirtyConversations.add(convId) }

    private fun loadStore() {
        val shards = messagesDir.listFiles { f -> f.extension == "json" }?.toList() ?: emptyList()

        // ONE-TIME migration: no shards yet but the legacy blob (or old prefs) exists → split
        // it into shards. Keep the blob (don't delete) so a rollback to pre-shard code works.
        if (shards.isEmpty()) {
            val raw = runCatching { if (storeFile.exists()) storeFile.readText() else null }.getOrNull()
                ?: prefs.getString("message_store", null)
            if (raw.isNullOrBlank()) {
                android.util.Log.w("VOIID", "📂 loadStore: EMPTY (fresh install)")
                storeLoaded = true
                return
            }
            runCatching {
                ApiClient.json.decodeFromString(storeSerializer, raw).forEach { (k, v) -> store[k] = v.toMutableList() }
            }.onSuccess {
                storeLoaded = true
                store.keys.forEach { persistShard(it) }   // write each conversation as a shard
                android.util.Log.i("VOIID", "📂 migrated ${store.size} convs from blob → shards")
            }.onFailure {
                android.util.Log.e("VOIID", "📂 loadStore FAILED to parse blob", it)   // don't mark loaded
            }
            return
        }

        // Normal path: load every shard.
        shards.forEach { f ->
            val conv = f.nameWithoutExtension
            runCatching { ApiClient.json.decodeFromString(shardSerializer, f.readText()) }
                .onSuccess { store[conv] = it.toMutableList() }
                .onFailure { android.util.Log.e("VOIID", "📂 shard parse FAILED conv=$conv", it) }
        }
        storeLoaded = true
        android.util.Log.i("VOIID", "📂 loadStore (sharded): ${store.values.sumOf { it.size }} msgs across ${store.size} convs")
    }

    private fun persist() {
        if (!storeLoaded) {   // never let an unloaded store overwrite good on-disk history
            android.util.Log.w("VOIID", "📂 persist skipped — store not loaded")
            return
        }
        // Write ONLY the conversations changed this turn.
        val snapshot = synchronized(dirtyConversations) { dirtyConversations.toList().also { dirtyConversations.clear() } }
        for (conv in snapshot) persistShard(conv)
    }

    /** Atomically write one conversation's shard (tmp + rename). */
    private fun persistShard(convId: String) {
        val arr = store[convId]?.toList() ?: emptyList()
        val raw = ApiClient.json.encodeToString(shardSerializer, arr)
        runCatching {
            val tmp = java.io.File(messagesDir, "$convId.json.tmp")
            tmp.writeText(raw)
            if (!tmp.renameTo(shardFile(convId))) { shardFile(convId).writeText(raw); tmp.delete() }
        }.onFailure {
            android.util.Log.e("VOIID", "📂 shard WRITE FAILED conv=$convId", it)
        }
    }

    /** Serialize the ENTIRE decrypted message store to bytes (backup payload).
     *  Same JSON shape [loadStore]/[persist] use, so [importStore] can round-trip it. */
    fun exportStore(): ByteArray {
        ensureLoaded()   // a backup must contain the whole history, not an empty just-launched store
        return ApiClient.json.encodeToString(storeSerializer, store.mapValues { it.value.toList() }).toByteArray()
    }

    /** Replace the local message store with a restored backup blob, then persist to
     *  the on-disk file. Bad/empty input is ignored (never crash a restore). */
    fun importStore(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        storeLoaded = true   // we are about to REPLACE the store wholesale; persist must be allowed
        runCatching {
            val decoded = ApiClient.json.decodeFromString(storeSerializer, String(bytes))
            store.clear()
            decoded.forEach { (k, v) -> store[k] = v.toMutableList() }
        }.onSuccess {
            // A restore REPLACES the store wholesale: wipe old shards, then write every
            // restored conversation as its own shard (persist() only writes DIRTY shards, so
            // mark them all).
            runCatching { messagesDir.listFiles()?.forEach { it.delete() } }
            store.keys.forEach { markDirty(it) }
            persist()
            android.util.Log.i("VOIID", "📥 importStore: restored ${store.values.sumOf { it.size }} msgs across ${store.size} convs")
        }.onFailure {
            android.util.Log.e("VOIID", "📥 importStore FAILED to parse backup blob", it)
        }
    }

    // MARK: - Session persistence (pickled, encrypted at rest)

    /** True when the last sync had an inbound decrypt failure (caller may ask the
     *  sender to re-establish the session). */
    var lastSyncHadDecryptFailure = false; private set

    /** In-memory + on-disk key for a remote device's session list. */
    private fun sessionKey(userId: String, deviceId: String) = "$userId::$deviceId"
    private fun sessionPrefsKey(userId: String, deviceId: String) = "sess::${sessionKey(userId, deviceId)}"

    /** Drop ALL cached + persisted sessions with [peerUserId] (across every one of that
     *  peer's devices) so the NEXT outbound message re-establishes fresh sessions. */
    fun resetSession(peerUserId: String) {
        val memPrefix = "$peerUserId::"
        sessions.keys.filter { it.startsWith(memPrefix) }.toList().forEach { sessions.remove(it) }
        val diskPrefix = "sess::$peerUserId::"
        val editor = prefs.edit()
        prefs.all.keys.filter { it.startsWith(diskPrefix) }.forEach { editor.remove(it) }
        editor.apply()
        android.util.Log.i("VOIID", "session reset for peer=$peerUserId (all devices)")
    }

    /** All candidate sessions for one (peer, device) pair (loaded from disk on first access). */
    private fun candidateSessions(userId: String, deviceId: String): MutableList<Session> =
        sessions.getOrPut(sessionKey(userId, deviceId)) { restoreSessions(userId, deviceId) }

    /** Restore a device's persisted session list (newline-separated pickles). */
    private fun restoreSessions(userId: String, deviceId: String): MutableList<Session> {
        val raw = prefs.getString(sessionPrefsKey(userId, deviceId), null) ?: return mutableListOf()
        return raw.split("\n").filter { it.isNotBlank() }
            .mapNotNull { runCatching { Session.restore(it, sessionPickleKey()) }.getOrNull() }
            .toMutableList()
    }

    /** Persist a device's sessions as newline-separated pickles. */
    private fun saveSessions(userId: String, deviceId: String) {
        val list = sessions[sessionKey(userId, deviceId)] ?: return
        runCatching {
            val blob = list.joinToString("\n") { it.toPickle(sessionPickleKey()) }
            prefs.edit().putString(sessionPrefsKey(userId, deviceId), blob).apply()
        }
    }

    private fun sessionPickleKey(): ByteArray {
        prefs.getString("session_pickle_key", null)?.let { return Base64.decode(it, Base64.NO_WRAP) }
        val bytes = ByteArray(32).also { java.security.SecureRandom().nextBytes(it) }
        prefs.edit().putString("session_pickle_key", Base64.encodeToString(bytes, Base64.NO_WRAP)).apply()
        return bytes
    }

    // MARK: - Wire (de)serialization

    @Serializable private data class WirePayload(val t: Long, val b: String)
    private fun encodeWire(w: WireMessage): String {
        val json = ApiClient.json.encodeToString(WirePayload.serializer(), WirePayload(w.msgType.toLong(), w.body))
        return Base64.encodeToString(json.encodeToByteArray(), Base64.NO_WRAP)
    }
    private fun decodeWire(ciphertext: String): WireMessage? = runCatching {
        val json = Base64.decode(ciphertext, Base64.NO_WRAP).decodeToString()
        val p = ApiClient.json.decodeFromString(WirePayload.serializer(), json)
        WireMessage(p.t.toULong(), p.b)
    }.getOrNull()

    private fun parseIso(s: String): Long =
        runCatching { java.time.Instant.parse(s).toEpochMilli() }.getOrDefault(System.currentTimeMillis())

    // MARK: - DTOs

    /**
     * NO DEFAULT ON `status`, deliberately.
     *
     * It used to be `= "read"`, and kotlinx omits any field equal to its default (ApiClient's
     * Json does not set `encodeDefaults`). So marking a message READ sent `{"message_ids":[…]}`
     * with no status — and routes/receipts.ts reads `status = 'delivered'` for a missing one.
     * The POST returned 200, so Android looked healthy while iOS never showed "Seen".
     *
     * See ReceiptEncodingTest, which pins both the fix and the original failure.
     */
    @Serializable private data class MarkReadBody(
        val message_ids: List<String>,
        val status: String,
        /** This device, because the JWT does not carry it. Null only before E2E setup. */
        val device_id: String? = null,
    )
    /** One target device's ciphertext in a fan-out bundle. */
    @Serializable private data class DeviceCiphertext(val recipient_device_id: String, val ciphertext: String)
    /** Multi-device fan-out send: one ciphertext per TARGET device. */
    @Serializable private data class SendBundleBody(
        val conversation_id: String,
        val sender_device_id: String? = null,   // which of OUR devices encrypted these
        val messages: List<DeviceCiphertext>,    // one entry per target device
        val content_type: String? = null,
        val media_url: String? = null,
        val media_mime: String? = null,
    )
    @Serializable private data class SendResponse(
        val message_id: String,
        val created_at: String? = null,
        val delivered_devices: Int = 0,
    )
    @Serializable private data class MessageDTO(
        val id: String,
        val sender_id: String,
        val ciphertext: String? = null,
        val created_at: String,
        val sender_device_id: String? = null,   // which of the SENDER's devices encrypted it
        val content_type: String? = null,
        val receipt_status: String? = null,      // "delivered"/"read" — recipient's state of OUR sent msg
    )
    @Serializable private data class MessagesResponse(val messages: List<MessageDTO>)
    @Serializable private data class DeviceDTO(val id: String, val identity_public_key: String)
    @Serializable private data class DevicesResponse(val devices: List<DeviceDTO>)
    @Serializable private data class OtkDTO(val public_key: String)
    @Serializable private data class BundleDTO(val device_id: String? = null, val identity_public_key: String, val one_time_prekey: OtkDTO? = null)
    @Serializable private data class PrekeysResponse(val bundles: List<BundleDTO>)
}
