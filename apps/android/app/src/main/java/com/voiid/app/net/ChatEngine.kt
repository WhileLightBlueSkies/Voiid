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

    // conversationId -> ALL candidate Olm sessions. During simultaneous initiation
    // ("glare") both peers create their own session, so a conversation legitimately has
    // MORE THAN ONE session. We must keep them all: try each on decrypt, and append
    // (never overwrite) a newly-accepted one — overwriting strands the other side's
    // early PreKey messages permanently.
    private val sessions = HashMap<String, MutableList<Session>>()
    private val store = HashMap<String, MutableList<DecryptedMessage>>() // conversationId -> messages (asc)
    private val media = MediaService(tokens)

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

    @Serializable
    data class DecryptedMessage(
        val id: String,                 // stable LOCAL id
        val senderId: String,
        val text: String,
        val createdAt: Long,
        val isMine: Boolean,
        val media: MediaRef? = null,
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
    )

    /** The E2EE plaintext of a media message: the reference + an optional caption. */
    @Serializable
    private data class MediaEnvelope(val v: Int = 1, val media: MediaRef, val caption: String)

    // MARK: - Public API

    /** Locally-stored (already decrypted) messages for a conversation, oldest-first. */
    fun messages(conversationId: String): List<DecryptedMessage> =
        (store[conversationId] ?: emptyList()).sortedBy { it.createdAt }

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
                val session = ensureOutboundSession(conversationId, peerUserId)
                val wire = session.encrypt(p.text.encodeToByteArray())
                saveSessions(conversationId)
                val ciphertext = encodeWire(wire)
                val body = ApiClient.json.encodeToString(SendBody.serializer(), SendBody(conversationId, ciphertext, device_id = e2e.deviceId))
                val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
                markSent(p.id, conversationId, res.message_id)
                android.util.Log.i("VOIID", "✅ sent text id=${res.message_id} conv=$conversationId")
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
        // 3. The E2EE message plaintext is a media envelope (key never leaves E2E).
        val envelopeJson = ApiClient.json.encodeToString(MediaEnvelope.serializer(), MediaEnvelope(media = ref, caption = caption))
        val session = ensureOutboundSession(conversationId, peerUserId)
        val wire = session.encrypt(envelopeJson.encodeToByteArray())
        saveSessions(conversationId)
        val ciphertext = encodeWire(wire)
        // 4. Send the message, tagging it as media + the opaque ref for the server.
        val body = ApiClient.json.encodeToString(
            SendBody.serializer(),
            SendBody(conversationId, ciphertext, device_id = e2e.deviceId, content_type = "media", media_url = key, media_mime = mime))
        val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
        val echo = DecryptedMessage(res.message_id, tokens.userId ?: "me", caption, parseIso(res.created_at), true, ref)
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
        val env: MessagesResponse = api.requestAs("GET", "messages/conversation/$conversationId")
        android.util.Log.i("VOIID", "sync conv=$conversationId: server has ${env.messages.size} msgs")
        val myId = tokens.userId
        // "seen" = ALL stored ids INCLUDING tombstones. A decrypt-once Olm message that
        // failed can NEVER be re-decrypted (recovery comes from the peer RE-SENDING a new
        // message, not retrying the dead id). Retrying tombstones every sync just re-fails
        // and keeps re-triggering session_reset, which destroys the working session
        // ("no matching session" cascade). So tombstone once, never retry.
        val seen = (store[conversationId] ?: emptyList()).map { it.id }.toHashSet()
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
            val wire = decodeWire(m.ciphertext) ?: continue
            runCatching {
                val plain = decryptInbound(wire, conversationId, peerUserId, m.sender_device_id)
                android.util.Log.i("VOIID", "✅ decrypted inbound id=${m.id} senderDev=${m.sender_device_id}")
                // A media message's plaintext is a JSON MediaEnvelope; text is just
                // the string. Detect via the server's content_type hint.
                val (caption, ref) = decodeEnvelope(plain, m.content_type == "media")
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

    /** Decode a decrypted plaintext into (caption, media?). */
    private fun decodeEnvelope(plain: String, isMedia: Boolean): Pair<String, MediaRef?> {
        if (isMedia) {
            runCatching {
                val env = ApiClient.json.decodeFromString(MediaEnvelope.serializer(), plain)
                return env.caption to env.media
            }
        }
        return plain to null
    }

    /** Mark all stored inbound messages in a conversation read → server fans out a
     *  `receipt` WS event to the senders (blue ticks). */
    suspend fun markRead(conversationId: String) {
        val ids = (store[conversationId] ?: emptyList()).filter { !it.isMine }.map { it.id }
        markReceipts(ids, "read")
    }

    private suspend fun decryptInbound(wire: WireMessage, conversationId: String, peerUserId: String, senderDeviceId: String?): String {
        val list = candidateSessions(conversationId)
        // 1. Try EVERY known session (glare → multiple). A non-matching session fails
        //    cleanly; the matching one decrypts (including later PreKey msgs of an
        //    already-accepted session, so no re-accept / no extra OTK consumed).
        for (s in list) {
            val data = runCatching { s.decrypt(wire) }.getOrNull()
            if (data != null) {
                saveSessions(conversationId)
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
                saveSessions(conversationId)
                return data.decodeToString()
            }
        }
        // 3. Accept a NEW inbound session and APPEND it (do not discard the others).
        //    vodozemac decrypts before consuming the OTK, so a failed accept is safe;
        //    a successful one consumes exactly one OTK for this distinct PreKey.
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val (peerKey, devId) = peerIdentity(peerUserId, senderDeviceId)
        verifyAndPinIdentity(peerKey, peerUserId, devId)         // anti-MITM (TOFU, per device)
        val accepted = id.acceptSession(peerKey, wire)
        list.add(accepted.session)
        saveSessions(conversationId)
        e2e.persistIdentity()   // acceptSession consumed a one-time key — save it or the
                                // first message is lost on restart (resurrected stale OTK).
        return accepted.plaintext.decodeToString()
    }

    // MARK: - Session establishment

    private suspend fun ensureOutboundSession(conversationId: String, peerUserId: String): Session {
        // Reuse an existing session for outbound (stable: the first/oldest) so we don't
        // keep minting new ones; only create one when the conversation has none.
        candidateSessions(conversationId).firstOrNull()?.let { return it }
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val bundle = peerPrekeyBundle(peerUserId)
        verifyAndPinIdentity(bundle.first, peerUserId, bundle.third)   // anti-MITM (TOFU, per device)
        val s = id.startSession(bundle.first, bundle.second)
        candidateSessions(conversationId).add(s)
        saveSessions(conversationId)
        return s
    }

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

    private suspend fun peerPrekeyBundle(userId: String): Triple<String, String, String?> {
        val env: PrekeysResponse = api.requestAs("GET", "prekeys/$userId")
        // Prefer a device that actually handed out a one-time key — a stale device
        // (e.g. left over after the peer reinstalled) can return a null prekey.
        val b = env.bundles.firstOrNull { it.one_time_prekey != null }
            ?: throw ApiError.Http(409, "peer has no available prekeys")
        val otk = b.one_time_prekey!!
        return Triple(b.identity_public_key, otk.public_key, b.device_id)
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

    private val storeSerializer = MapSerializer(String.serializer(), ListSerializer(DecryptedMessage.serializer()))

    private fun loadStore() {
        val raw = prefs.getString("message_store", null)
        if (raw == null) {
            android.util.Log.w("VOIID", "📂 loadStore: EMPTY (no persisted messages — fresh or wiped)")
            return
        }
        runCatching {
            ApiClient.json.decodeFromString(storeSerializer, raw).forEach { (k, v) ->
                store[k] = v.toMutableList()
            }
        }.onSuccess {
            android.util.Log.i("VOIID", "📂 loadStore: restored ${store.values.sumOf { it.size }} msgs across ${store.size} convs")
        }.onFailure {
            android.util.Log.e("VOIID", "📂 loadStore FAILED to parse", it)
        }
    }

    private fun persist() {
        val raw = ApiClient.json.encodeToString(storeSerializer, store.mapValues { it.value.toList() })
        prefs.edit().putString("message_store", raw).apply()
    }

    // MARK: - Session persistence (pickled, encrypted at rest)

    /** True when the last sync had an inbound decrypt failure (caller may ask the
     *  sender to re-establish the session). */
    var lastSyncHadDecryptFailure = false; private set

    /** Drop the cached + persisted sessions so the NEXT outbound message starts fresh. */
    fun resetSession(conversationId: String) {
        sessions.remove(conversationId)
        prefs.edit().remove("sess_$conversationId").apply()
        android.util.Log.i("VOIID", "session reset for conv=$conversationId")
    }

    /** All candidate sessions for a conversation (loaded from disk on first access). */
    private fun candidateSessions(conversationId: String): MutableList<Session> =
        sessions.getOrPut(conversationId) { restoreSessions(conversationId) }

    /** Restore the persisted session list (newline-separated pickles; back-compatible
     *  with the old single-pickle format). */
    private fun restoreSessions(conversationId: String): MutableList<Session> {
        val raw = prefs.getString("sess_$conversationId", null) ?: return mutableListOf()
        return raw.split("\n").filter { it.isNotBlank() }
            .mapNotNull { runCatching { Session.restore(it, sessionPickleKey()) }.getOrNull() }
            .toMutableList()
    }

    /** Persist all sessions for a conversation as newline-separated pickles. */
    private fun saveSessions(conversationId: String) {
        val list = sessions[conversationId] ?: return
        runCatching {
            val blob = list.joinToString("\n") { it.toPickle(sessionPickleKey()) }
            prefs.edit().putString("sess_$conversationId", blob).apply()
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
    @Serializable private data class SendBody(
        val conversation_id: String,
        val ciphertext: String,
        val device_id: String? = null,      // which of OUR devices encrypted this
        val content_type: String? = null,
        val media_url: String? = null,
        val media_mime: String? = null,
    )
    @Serializable private data class SendResponse(val message_id: String, val created_at: String)
    @Serializable private data class MessageDTO(
        val id: String,
        val sender_id: String,
        val ciphertext: String,
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
