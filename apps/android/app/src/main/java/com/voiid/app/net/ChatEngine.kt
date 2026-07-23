package com.voiid.app.net

import android.content.Context
import android.util.Base64
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
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

    // NOTE: these MUST be declared BEFORE `init { loadStore() }` — Kotlin initializes
    // properties in source order, and loadStore() (run from init) uses both. If declared
    // after init they are null during loadStore → NPE → store never loads.
    private val storeSerializer = MapSerializer(String.serializer(), ListSerializer(DecryptedMessage.serializer()))
    // Decrypt-once plaintext store: a PLAIN app-internal file (sandboxed, excluded from
    // backup) — NOT EncryptedSharedPreferences, whose key can be wiped by SecurePrefs,
    // destroying all history on restart. A file can't be wiped by a key issue.
    private val storeFile = java.io.File(appContext.filesDir, "voiid_messages.json")

    init { loadStore() }

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
        val lat: Double,
        val lon: Double,
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
    }

    /** Locally-stored (already decrypted) messages for a conversation, oldest-first. */
    fun messages(conversationId: String): List<DecryptedMessage> =
        (store[conversationId] ?: emptyList()).filter { !it.control }.sortedBy { it.createdAt }

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
        val pendings = (store[conversationId] ?: emptyList()).filter { it.isMine && it.pending && it.media == null }
        for (p in pendings) {
            try {
                // Fan-out: encrypt ONCE PER TARGET DEVICE (peer's devices + our own other
                // devices), build the per-device bundle, and POST it in one send.
                val messages = encryptFanout(p.text.encodeToByteArray(), peerUserId)
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
            if (m.sender_id == myId) {
                m.receipt_status?.let { applyReceipt(m.id, it) }
                continue
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
                val plain = decryptInbound(wire, peerUserId, m.sender_device_id)
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
        val rank = mapOf("sent" to 0, "delivered" to 1, "read" to 2)
        for ((cid, arr) in store) {
            val i = arr.indexOfFirst { it.isMine && (it.serverId == messageId || it.id == messageId) }
            if (i >= 0) {
                val cur = arr[i].deliveryStatus ?: "sent"
                if ((rank[status] ?: 0) > (rank[cur] ?: 0)) {
                    arr[i] = arr[i].copy(deliveryStatus = status)
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
        val body = ApiClient.json.encodeToString(MarkReadBody.serializer(), MarkReadBody(ids, status))
        runCatching { api.request("POST", "receipts/mark", jsonBody = body) }
    }

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

    /** Mark all stored inbound messages in a conversation read → server fans out a
     *  `receipt` WS event to the senders (blue ticks). */
    suspend fun markRead(conversationId: String) {
        val ids = (store[conversationId] ?: emptyList()).filter { !it.isMine }.map { it.id }
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
        val peerDevs: DevicesResponse = api.requestAs("GET", "devices/$peerUserId")
        peerDevs.devices.forEach { targets.add(TargetDevice(peerUserId, it.id)) }
        // Our own OTHER devices (linked-device sync of sent messages), excluding this one.
        val myId = tokens.userId
        val myDev = e2e.deviceId
        if (myId != null) {
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
            val devs = runCatching { api.requestAs<DevicesResponse>("GET", "devices/$uid") }.getOrNull() ?: continue
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
            val wire = decodeWire(ciphertextB64) ?: return@withLock null
            runCatching { decryptInbound(wire, senderUserId, senderDeviceId) }.getOrNull()
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
    fun decryptStoryReceipt(ciphertextB64: String): String? {
        val wire = decodeWire(ciphertextB64) ?: return null
        for (list in sessions.values) for (s in list) {
            runCatching { s.decrypt(wire) }.getOrNull()?.let { return it.decodeToString() }
        }
        return null
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
    @Serializable private data class ReactionWire(val t: String = "msg_reaction", val v: Int = 1, val target: String, val emoji: String? = null)
    @Serializable private data class DeleteWire(val t: String = "msg_delete", val v: Int = 1, val target: String)
    @Serializable private data class ReplyWire(val t: String = "msg_reply", val v: Int = 1, val text: String, val quotedId: String, val quotedPreview: String, val quotedSender: String)
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
        persist()
    }
    fun applyDeleteForEveryone(convId: String, target: String) {
        val arr = store[convId] ?: return
        val i = arr.indexOfFirst { it.serverId == target || it.id == target }
        if (i < 0) return
        arr[i] = arr[i].copy(deletedForEveryone = true, text = "", media = null, reactions = null)
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
    private fun controlSeenIds(): Set<String> = prefs.getStringSet("loc_control_seen", emptySet()) ?: emptySet()
    private fun markControlSeen(id: String) {
        val cur = HashSet(controlSeenIds()); cur.add(id)
        prefs.edit().putStringSet("loc_control_seen", cur).apply()
    }

    /** Wire shape of a story_reply envelope (kept local so `net` needn't depend on `model`). */
    @Serializable
    private data class StoryReplyWire(
        val v: Int = 1, val t: String = "story_reply",
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
    fun hasMessage(conversationId: String, id: String): Boolean =
        store[conversationId]?.any { it.id == id } == true

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
                val lat = env.lat ?: return; val lon = env.lon ?: return
                val expiresAt = env.expiresAt ?: (createdAt + 3_600_000L)
                storeLocationInbound(conversationId, "loclive_$shareId", senderId,
                    LocationRef(kind = "live_start", shareId = shareId, lat = lat, lon = lon,
                        acc = env.acc ?: 0.0, expiresAt = expiresAt, cadenceSeconds = env.cadence), createdAt)
            }
            "live_rekey" ->
                env.s?.let { sid -> env.key?.let { SecurePrefs.open(appContext, "voiid_location").edit().putString(sid, it).apply() } }
            "map_key" -> {
                val shareId = env.s ?: return
                val keyB64 = env.key ?: return
                MapInboundKeyStore.put(appContext, shareId, senderId, keyB64,
                    env.expiresAt ?: (System.currentTimeMillis() + 24L * 3600 * 1000))
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
        val arr = store.getOrPut(convId) { mutableListOf() }
        if (arr.any { it.id == m.id }) return
        arr.add(m)
        if (persist) persist()
    }

    /** Insert, or REPLACE an existing entry with the same id in place (keeps order).
     *  Lets a tombstone that later decrypts be upgraded to the real message. */
    private fun replace(convId: String, m: DecryptedMessage) {
        val arr = store.getOrPut(convId) { mutableListOf() }
        val i = arr.indexOfFirst { it.id == m.id }
        if (i >= 0) arr[i] = m else arr.add(m)
    }

    private fun loadStore() {
        // Prefer the file; fall back ONCE to the old encrypted-prefs location to migrate.
        val raw = runCatching { if (storeFile.exists()) storeFile.readText() else null }.getOrNull()
            ?: prefs.getString("message_store", null)
        if (raw.isNullOrBlank()) {
            android.util.Log.w("VOIID", "📂 loadStore: EMPTY (no persisted messages — fresh install)")
            return
        }
        runCatching {
            ApiClient.json.decodeFromString(storeSerializer, raw).forEach { (k, v) ->
                store[k] = v.toMutableList()
            }
        }.onSuccess {
            android.util.Log.i("VOIID", "📂 loadStore: restored ${store.values.sumOf { it.size }} msgs across ${store.size} convs")
            if (!storeFile.exists()) persist()   // migrate old prefs → file
        }.onFailure {
            android.util.Log.e("VOIID", "📂 loadStore FAILED to parse", it)
        }
    }

    private fun persist() {
        val raw = ApiClient.json.encodeToString(storeSerializer, store.mapValues { it.value.toList() })
        // Atomic write: tmp file then rename, so a crash mid-write can't corrupt the store.
        runCatching {
            val tmp = java.io.File(storeFile.parentFile, "voiid_messages.json.tmp")
            tmp.writeText(raw)
            if (!tmp.renameTo(storeFile)) { storeFile.writeText(raw); tmp.delete() }
        }.onFailure {
            android.util.Log.e("VOIID", "📂 persist FAILED to write store file", it)
        }
    }

    /** Serialize the ENTIRE decrypted message store to bytes (backup payload).
     *  Same JSON shape [loadStore]/[persist] use, so [importStore] can round-trip it. */
    fun exportStore(): ByteArray =
        ApiClient.json.encodeToString(storeSerializer, store.mapValues { it.value.toList() }).toByteArray()

    /** Replace the local message store with a restored backup blob, then persist to
     *  the on-disk file. Bad/empty input is ignored (never crash a restore). */
    fun importStore(bytes: ByteArray) {
        if (bytes.isEmpty()) return
        runCatching {
            val decoded = ApiClient.json.decodeFromString(storeSerializer, String(bytes))
            store.clear()
            decoded.forEach { (k, v) -> store[k] = v.toMutableList() }
        }.onSuccess {
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

    @Serializable private data class MarkReadBody(val message_ids: List<String>, val status: String = "read")
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
