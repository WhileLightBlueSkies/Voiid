package com.voiid.app.net

import android.content.Context
import android.util.Base64
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
    private val tokens = TokenStore.get(context)
    private val api = ApiClient(tokens)
    private val e2e = E2EManager.get(context)

    private val prefs = SecurePrefs.open(appContext, "voiid_chat")

    private val sessions = HashMap<String, Session>()                 // conversationId -> live Session
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
                saveSession(session, conversationId)
                val ciphertext = encodeWire(wire)
                val body = ApiClient.json.encodeToString(SendBody.serializer(), SendBody(conversationId, ciphertext))
                val res: SendResponse = api.requestAs("POST", "messages/send", jsonBody = body)
                markSent(p.id, conversationId, res.message_id)
                android.util.Log.i("VOIID", "✅ sent text id=${res.message_id} conv=$conversationId")
            } catch (e: Exception) {
                markFailed(p.id, conversationId)
                android.util.Log.e("VOIID", "❌ sendText FAILED conv=$conversationId", e)
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
        saveSession(session, conversationId)
        val ciphertext = encodeWire(wire)
        // 4. Send the message, tagging it as media + the opaque ref for the server.
        val body = ApiClient.json.encodeToString(
            SendBody.serializer(),
            SendBody(conversationId, ciphertext, content_type = "media", media_url = key, media_mime = mime))
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
    suspend fun sync(conversationId: String, peerUserId: String): List<DecryptedMessage> {
        flushPending(conversationId, peerUserId)   // push any queued sends first
        val env: MessagesResponse = api.requestAs("GET", "messages/conversation/$conversationId")
        val myId = tokens.userId
        val seen = (store[conversationId] ?: emptyList()).map { it.id }.toHashSet()
        for (m in env.messages.asReversed()) {        // server DESC -> process ASC
            if (seen.contains(m.id)) continue
            if (m.sender_id == myId) continue          // our echo is stored at send time
            val wire = decodeWire(m.ciphertext) ?: continue
            runCatching {
                val plain = decryptInbound(wire, conversationId, peerUserId)
                // A media message's plaintext is a JSON MediaEnvelope; text is just
                // the string. Detect via the server's content_type hint.
                val (caption, ref) = decodeEnvelope(plain, m.content_type == "media")
                append(conversationId, DecryptedMessage(m.id, m.sender_id, caption, parseIso(m.created_at), false, ref), persist = false)
            }
        }
        persist()
        return messages(conversationId)
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
        if (ids.isEmpty()) return
        val body = ApiClient.json.encodeToString(MarkReadBody.serializer(), MarkReadBody(ids))
        runCatching { api.request("POST", "receipts/mark", jsonBody = body) }
    }

    private suspend fun decryptInbound(wire: WireMessage, conversationId: String, peerUserId: String): String {
        val live = sessions[conversationId] ?: restoreSession(conversationId)
        if (live != null) {
            sessions[conversationId] = live
            val data = live.decrypt(wire)
            saveSession(live, conversationId)
            return data.decodeToString()
        }
        // No session yet -> first (PreKey) message; accept it to create the session.
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val peerIdentityKey = peerIdentityKey(peerUserId)
        verifyAndPinIdentity(peerIdentityKey, peerUserId)         // anti-MITM (TOFU)
        val accepted = id.acceptSession(peerIdentityKey, wire)
        sessions[conversationId] = accepted.session
        saveSession(accepted.session, conversationId)
        return accepted.plaintext.decodeToString()
    }

    // MARK: - Session establishment

    private suspend fun ensureOutboundSession(conversationId: String, peerUserId: String): Session {
        (sessions[conversationId] ?: restoreSession(conversationId))?.let {
            sessions[conversationId] = it
            return it
        }
        val id = e2e.identity ?: throw ApiError.NotAuthenticated
        val bundle = peerPrekeyBundle(peerUserId)
        verifyAndPinIdentity(bundle.first, peerUserId)            // anti-MITM (TOFU)
        val s = id.startSession(bundle.first, bundle.second)
        sessions[conversationId] = s
        saveSession(s, conversationId)
        return s
    }

    // MARK: - Identity pinning (anti-MITM / "safety numbers", trust-on-first-use)

    private fun verifyAndPinIdentity(identityKey: String, peerUserId: String) {
        val pinName = "idpin_$peerUserId"
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

    private suspend fun peerIdentityKey(userId: String): String {
        val env: DevicesResponse = api.requestAs("GET", "devices/$userId")
        return env.devices.firstOrNull()?.identity_public_key
            ?: throw ApiError.Http(404, "peer has no device")
    }

    private suspend fun peerPrekeyBundle(userId: String): Pair<String, String> {
        val env: PrekeysResponse = api.requestAs("GET", "prekeys/$userId")
        // Prefer a device that actually handed out a one-time key — a stale device
        // (e.g. left over after the peer reinstalled) can return a null prekey.
        val b = env.bundles.firstOrNull { it.one_time_prekey != null }
            ?: throw ApiError.Http(409, "peer has no available prekeys")
        val otk = b.one_time_prekey!!
        return Pair(b.identity_public_key, otk.public_key)
    }

    // MARK: - Local message store (decrypt-once; encrypted at rest)

    private fun append(convId: String, m: DecryptedMessage, persist: Boolean = true) {
        val arr = store.getOrPut(convId) { mutableListOf() }
        if (arr.any { it.id == m.id }) return
        arr.add(m)
        if (persist) persist()
    }

    private val storeSerializer = MapSerializer(String.serializer(), ListSerializer(DecryptedMessage.serializer()))

    private fun loadStore() {
        val raw = prefs.getString("message_store", null) ?: return
        runCatching {
            ApiClient.json.decodeFromString(storeSerializer, raw).forEach { (k, v) ->
                store[k] = v.toMutableList()
            }
        }
    }

    private fun persist() {
        val raw = ApiClient.json.encodeToString(storeSerializer, store.mapValues { it.value.toList() })
        prefs.edit().putString("message_store", raw).apply()
    }

    // MARK: - Session persistence (pickled, encrypted at rest)

    private fun restoreSession(conversationId: String): Session? {
        val pickle = prefs.getString("sess_$conversationId", null) ?: return null
        return runCatching { Session.restore(pickle, sessionPickleKey()) }.getOrNull()
    }

    private fun saveSession(s: Session, conversationId: String) {
        runCatching { prefs.edit().putString("sess_$conversationId", s.toPickle(sessionPickleKey())).apply() }
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
        val content_type: String? = null,
    )
    @Serializable private data class MessagesResponse(val messages: List<MessageDTO>)
    @Serializable private data class DeviceDTO(val identity_public_key: String)
    @Serializable private data class DevicesResponse(val devices: List<DeviceDTO>)
    @Serializable private data class OtkDTO(val public_key: String)
    @Serializable private data class BundleDTO(val identity_public_key: String, val one_time_prekey: OtkDTO? = null)
    @Serializable private data class PrekeysResponse(val bundles: List<BundleDTO>)
}
