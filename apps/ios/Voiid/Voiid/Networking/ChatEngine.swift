//
//  ChatEngine.swift
//  Voiid
//
//  Real E2EE 1:1 messaging on top of e2e-core + the backend.
//   - Sessions are established lazily: the sender fetches the peer's prekey bundle
//     and `startSession`; the receiver `acceptSession` on the first (PreKey) message.
//   - Sessions are persisted (pickled) per conversation so they survive restarts.
//   - The server only ever sees opaque ciphertext: we pack the e2e-core
//     WireMessage (msgType + body) into one base64 "ciphertext" field.
//
//  Wire format on the server's `ciphertext`: base64( JSON {"t": msgType, "b": body} ).
//
//  Decrypt-once + local store:
//   Double-ratchet ciphertext can't be safely re-decrypted on every reload (the
//   message-key cache is bounded). So each inbound message is decrypted EXACTLY
//   ONCE and its plaintext is persisted to a local, file-protected store keyed by
//   message id. Our own sent messages are also stored (we can't decrypt our own
//   ratchet output). `messages(...)` reads the store; `sync(...)` fetches the
//   server, decrypts only message ids we haven't seen, appends, and returns all.
//

import Foundation
import Security

private extension String {
    /// Add `=` padding to a base64 string whose length isn't a multiple of 4
    /// (vodozemac/peers may emit unpadded standard base64).
    var padded64: String {
        let rem = count % 4
        return rem == 0 ? self : self + String(repeating: "=", count: 4 - rem)
    }
}

/// The media reference carried INSIDE an E2EE message. The actual bytes live in
/// R2 as ciphertext at `mediaUrl` (an opaque object key); `key`/`nonce`/`sha256`
/// are the per-message media key needed to decrypt them. Because this whole
/// struct is the plaintext of a Double-Ratchet message, the media key never
/// leaves E2E — the server only ever sees the opaque key + ciphertext bytes.
struct MediaRef: Codable, Equatable, Hashable {
    let mediaUrl: String      // R2 object key
    let mime: String          // real media type (image/jpeg, audio/m4a, …)
    let key: String           // base64 media key
    let nonce: String         // base64 nonce
    let sha256: String        // ciphertext integrity hash
}

/// A story reply's ratchet plaintext (§5.2). Sent as a normal 1:1 message with
/// content_type "story_reply"; lives in the chat and does NOT expire with the story.
///
/// MUST live in ChatEngine.swift, NOT in the app-only Models/Story.swift: this file is
/// compiled into the VoiidNSE extension target (which has no app model layer), and
/// `decodeEnvelope` below decodes this type while the NSE decrypts an inbound push. Every
/// wire type ChatEngine touches lives here for exactly that reason (cf. MediaRef, MediaEnvelope).
struct StoryReplyEnvelope: Codable {
    var v: Int = 1
    var t: String = "story_reply"
    let storyId: String
    let storyAuthorId: String
    let storyCreatedAt: Int64    // epoch ms
    var text: String = ""        // the reply body
    var reaction: String?        // a single emoji for the quick-tap rail, or nil
}

/// A decrypted message ready for the UI (and the on-disk store record).
/// For media messages `text` holds a caption (often empty) and `media` carries
/// the reference needed to fetch + decrypt the blob on demand.
struct DecryptedMessage: Codable {
    let id: String                 // stable LOCAL id (kept across send so the UI is stable)
    let senderId: String
    // Mutable: delete-for-everyone tombstones this to "" in place (see
    // applyDeleteForEveryone) rather than reconstructing the whole record.
    var text: String
    let createdAt: Date
    let isMine: Bool
    var media: MediaRef? = nil
    /// The KEY-STRIPPED location envelope JSON for a pin / live-share bubble
    /// (docs/LOCATION.md §4), or nil for a non-location message. Kept as a String (not a
    /// typed struct) so this record — which is ALSO compiled into the Notification Service
    /// Extension — needs no app-only type. The app decodes it into a `LocationRef` at render
    /// time. The shareKey is NEVER stored here; it is captured to the Keychain by `LocationWire`.
    var locationJSON: String? = nil
    /// True until the server has accepted this (offline / not-yet-sent). Persisted,
    /// so a message typed offline is visible immediately + survives restart + retried.
    var pending: Bool = false
    /// Server message id once accepted (used to match read/delivery receipts).
    var serverId: String? = nil
    /// Delivery state of OUR sent message: "sent" → "delivered" → "read". Persisted
    /// so it never regresses when the message list is rebuilt.
    var deliveryStatus: String? = nil
    /// True for a tombstone (decrypt failed). NOT counted as "seen" so it's retried
    /// on later syncs — once the session re-establishes it can finally decrypt.
    var failed: Bool = false
    /// Per-USER reactions on this message (userId -> emoji). A map, not a single field,
    /// so two people can react differently and each can change their own. Persisted.
    var reactions: [String: String]? = nil
    /// Delete-for-everyone tombstone: the original author asked all recipients to erase it.
    var deletedForEveryone: Bool? = nil
    /// Quoted-reply snapshot (server id + a short preview + who sent it), so the quote
    /// renders even if the original was since deleted.
    var quotedId: String? = nil
    var quotedPreview: String? = nil
    var quotedSender: String? = nil
    /// "Forwarded" tag.
    var forwarded: Bool? = nil
    /// A control message (reaction/delete signal): kept in the store so its id counts as
    /// "seen" and is never reprocessed, but NEVER rendered as a bubble.
    var control: Bool? = nil
}

@MainActor
final class ChatEngine {
    static let shared = ChatEngine()
    private let api = APIClient()
    private let kc = KeychainData(service: "com.voiid.sessions")
    private let sessionPickleKeyName = "session_pickle_key"
    // (peerUserId, deviceId) -> ALL candidate Olm sessions for THAT specific remote
    // device. Multi-device fan-out: E2EE gives every device its own vodozemac session,
    // so sessions MUST be keyed per remote device (not per conversation/user) — a peer's
    // 2nd device can't decrypt the 1st device's ratchet output. The "remote" is either a
    // conversation peer's device OR one of the sender's own other (linked) devices.
    // During simultaneous initiation ("glare") both peers create their own session, so a
    // single device pair legitimately has more than one. Keep them all: try each on
    // decrypt, append (never overwrite) a newly-accepted one — overwriting strands the
    // peer's early PreKey messages forever.
    private var sessions: [String: [Session]] = [:]   // key = sessionKey(userId, deviceId)
    private var store: [String: [DecryptedMessage]] = [:]   // conversationId -> messages (asc)
    /// Per-conversation async mutex. @MainActor does NOT prevent two sync() calls
    /// (4s poll + WS push) from interleaving at `await` points and BOTH acceptSession
    /// the same PreKey messages — which races the one-time key and leaves the earliest
    /// messages permanently undecryptable. lock()/unlock() serialize per conversation.
    private var syncLocked: Set<String> = []
    private var syncWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private init() { loadStore() }

    /// Drop every trace of the signed-in account from MEMORY.
    ///
    /// Log-out deletes `voiid_messages.json` and the SQLite file, but this process does not
    /// restart on sign-out — so without this, `store` still holds every decrypted message in
    /// PLAINTEXT and `sessions` still holds live Olm sessions for the account that just left.
    /// The next account to sign in on this handset would be running alongside the previous
    /// user's messages, and the first `persist()` would write them straight back to disk,
    /// silently undoing the file deletion.
    ///
    /// Must be called BEFORE the files are deleted, so nothing can flush in between.
    func wipeInMemoryState() {
        store.removeAll()
        sessions.removeAll()
        syncLocked.removeAll()
        // Resume anyone parked on a per-conversation mutex; leaking a continuation would
        // hang that task forever, and the work it was waiting to do is now meaningless.
        for (_, waiters) in syncWaiters { for w in waiters { w.resume() } }
        syncWaiters.removeAll()
    }

    /// Acquire the per-conversation lock (hand-off: a waiter is woken WITH the lock
    /// held, so a new caller can't jump the queue).
    private func lockSync(_ conv: String) async {
        if syncLocked.contains(conv) {
            await withCheckedContinuation { syncWaiters[conv, default: []].append($0) }
        } else {
            syncLocked.insert(conv)
        }
    }
    private func unlockSync(_ conv: String) {
        if var q = syncWaiters[conv], !q.isEmpty {
            let next = q.removeFirst()
            syncWaiters[conv] = q
            next.resume()                 // hand off the lock; keep syncLocked = true
        } else {
            syncLocked.remove(conv)
        }
    }

    // MARK: - Public API

    /// Locally-stored (already decrypted) messages for a conversation, oldest-first.
    /// Control rows (reaction/delete signals) are kept in the store for dedup but never
    /// surfaced as bubbles.
    func messages(conversationId: String) -> [DecryptedMessage] {
        (store[conversationId] ?? [])
            .filter { !($0.control ?? false) }
            .sorted { $0.createdAt < $1.createdAt }
    }

    // MARK: - Group (MLS) message store bridge
    //
    // Group messages are decrypted by GroupEngine (MLS), not the 1:1 ratchet, but they
    // live in the SAME decrypted-message store so the chat UI renders them identically.
    // These two hooks let GroupEngine dedup (decrypt-once) and append into that store.

    /// Message ids GroupEngine must NOT decrypt again — everything stored except
    /// tombstones. MLS application messages are decrypt-once (the generation key is taken
    /// out of `past_secrets`), hence the ledger; but a tombstone is deliberately excluded
    /// so it IS retried. The MLS FFI collapses every failure into `DecryptionFailed`, so
    /// Swift cannot tell "this generation was already consumed" (terminal) from "I haven't
    /// applied the Commit for this epoch yet" (recoverable the moment it arrives). Retrying
    /// costs one failed local decrypt per sync and has no side effect — OpenMLS writes
    /// nothing on the error path — whereas treating a tombstone as final would hide a
    /// perfectly decryptable message forever.
    func storedMessageIds(conversationId: String) -> Set<String> {
        Set((store[conversationId] ?? []).filter { !$0.failed }.map { $0.id })
    }

    /// Append an already-decrypted group message into the shared store (dedup by id +
    /// persist). An existing TOMBSTONE for the same id is upgraded in place; a successful
    /// decrypt is never clobbered.
    ///
    /// MUST be called from inside GroupEngine's cross-process critical section. `append`
    /// rewrites the WHOLE app-group store file from this process's in-memory copy, so
    /// calling it with a stale `store` silently erases whatever the other process wrote —
    /// which is why `GroupEngine.reloadSharedState()` calls `reloadStore()` first.
    func ingestGroupMessage(_ m: DecryptedMessage, conversationId: String) {
        if let existing = (store[conversationId] ?? []).first(where: { $0.id == m.id }) {
            guard existing.failed, !m.failed else { return }
            replace(id: m.id, with: m, to: conversationId)
            persist()
            return
        }
        append(m, to: conversationId)
    }

    /// Re-read the shared decrypted-message store from the app-group container. Used by
    /// GroupEngine to make the group path obey the same read-modify-write discipline the
    /// 1:1 path gets from `reloadSharedState`.
    func reloadStore() { loadStore() }

    /// One stored message by local id or server id (the push carries the server id).
    func storedMessage(id: String, conversationId: String) -> DecryptedMessage? {
        (store[conversationId] ?? []).first { $0.id == id || $0.serverId == id }
    }

    // MARK: - Backup export / import (the plaintext payload of an encrypted backup)

    /// Serialize the entire decrypted-message store for an encrypted backup. The
    /// bytes are sealed under the backup master secret before they ever leave the
    /// device (see BackupManager), so the server only sees ciphertext.
    func exportStore() -> Data {
        (try? JSONEncoder().encode(store)) ?? Data()
    }

    /// Merge a restored message store into the current one. Messages are keyed by id
    /// per conversation; existing entries win (never clobber a locally-decrypted
    /// message with a restored copy), restored-only messages are appended. Persists.
    func importStore(_ data: Data) {
        guard let decoded = try? JSONDecoder().decode([String: [DecryptedMessage]].self, from: data) else { return }
        for (conv, msgs) in decoded {
            var arr = store[conv] ?? []
            let existing = Set(arr.map { $0.id })
            for m in msgs where !existing.contains(m.id) { arr.append(m) }
            store[conv] = arr
        }
        persist()
    }

    /// Queue a text message for sending. Stores it locally as PENDING immediately
    /// (so it shows instantly + offline + survives restart) WITHOUT touching the
    /// network. Call `flushPending` to actually send. Returns the stored echo.
    @discardableResult
    func enqueueText(_ text: String, conversationId: String) -> DecryptedMessage {
        let msg = DecryptedMessage(id: UUID().uuidString, senderId: TokenStore.shared.userId ?? "me",
                                   text: text, createdAt: Date(), isMine: true, pending: true)
        append(msg, to: conversationId)
        return msg
    }

    /// Try to send every PENDING text message in a conversation (offline retry).
    /// Network failures are swallowed — the message stays pending and is retried
    /// on the next flush (open / sync / reconnect).
    func flushPending(conversationId: String, peerUserId: String) async {
        // Take the cross-process lock + reload shared state so an outbound send never
        // races the NSE's inbound decrypt over the same session keychain item.
        await CrossProcessLock.withLock {
            reloadSharedState()
            await flushPendingLocked(conversationId: conversationId, peerUserId: peerUserId)
        }
    }

    /// Body of `flushPending`, assuming the caller already holds the cross-process lock
    /// and has reloaded shared state (called directly from `runSyncLocked`, which is
    /// itself already under the lock — flock is NOT reentrant, so we must not re-acquire).
    private func flushPendingLocked(conversationId: String, peerUserId: String) async {
        let pendings = (store[conversationId] ?? []).filter { $0.isMine && $0.pending && $0.media == nil }
        for p in pendings {
            do {
                // Fan-out: encrypt ONCE PER TARGET DEVICE (peer's devices + our own other
                // devices), build the per-device bundle, and POST it in one send.
                let messages = try await encryptFanout(Data(p.text.utf8), peerUserId: peerUserId)
                let res: SendResponse = try await api.request(
                    "POST", "messages/send",
                    body: SendBundleBody(conversation_id: conversationId,
                                         sender_device_id: E2EManager.shared.deviceId,
                                         messages: messages, content_type: "text"))
                markSent(localId: p.id, conversationId: conversationId, serverId: res.message_id)
                NSLog("[VOIID] ✅ sent text id=\(res.message_id) conv=\(conversationId) devices=\(messages.count)")
            } catch {
                // "peer has no available prekeys" means the recipient hasn't published keys
                // yet (not registered / logged out / momentary race). Olm REQUIRES a
                // one-time key to start a session, so we genuinely can't send yet — keep the
                // message PENDING (clock, not red "failed") so the 4s poll retries and it
                // delivers the moment the peer publishes keys. Only surface a hard failure
                // for unexpected errors.
                let retryable: Bool
                switch error {
                case APIError.http(let status, _): retryable = (status == 409 || status == 404)
                case APIError.transport: retryable = true
                default: retryable = false
                }
                if retryable {
                    NSLog("[VOIID] ⏳ send pending (peer not ready) conv=\(conversationId): \(error)")
                } else {
                    markFailed(localId: p.id, conversationId: conversationId)
                    NSLog("[VOIID] ❌ sendText FAILED conv=\(conversationId): \(error)")
                }
            }
        }
    }

    /// Flag a still-pending message as failed so the UI can show an error + retry.
    private func markFailed(localId: String, conversationId: String) {
        guard var arr = store[conversationId],
              let i = arr.firstIndex(where: { $0.id == localId }), !arr[i].failed else { return }
        arr[i].failed = true
        store[conversationId] = arr
        persist()
    }

    /// Backwards-compatible one-shot send (enqueue + flush).
    @discardableResult
    func sendText(_ text: String, conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        let msg = enqueueText(text, conversationId: conversationId)
        await flushPending(conversationId: conversationId, peerUserId: peerUserId)
        return msg
    }

    private func markSent(localId: String, conversationId: String, serverId: String) {
        guard var arr = store[conversationId], let i = arr.firstIndex(where: { $0.id == localId }) else { return }
        arr[i].pending = false
        arr[i].failed = false
        arr[i].serverId = serverId
        store[conversationId] = arr
        persist()
    }

    /// Encrypt + send a MEDIA message in a direct conversation. The blob is
    /// encrypted on-device, the ciphertext is uploaded to R2, and the media
    /// reference (object key + media key) is packed into the E2EE message
    /// plaintext as a JSON envelope — so the key stays end-to-end. `caption` is
    /// optional text shown alongside the media.
    @discardableResult
    func sendMedia(_ data: Data, mime: String, caption: String = "",
                   conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        // 1. Encrypt the blob (e2e-core) → ciphertext + media key.
        let enc = try encryptMedia(plaintext: data)
        // 2. Upload the CIPHERTEXT to R2; get back the opaque object key.
        let key = try await MediaService.shared.upload(ciphertext: enc.ciphertext, mime: mime)
        let ref = MediaRef(mediaUrl: key, mime: mime,
                           key: enc.mediaKey.key, nonce: enc.mediaKey.nonce,
                           sha256: enc.mediaKey.ciphertextSha256)
        // 3. The E2EE message plaintext is a media envelope (key never leaves E2E). The
        //    SAME envelope is encrypted per target device (fan-out); every device's copy
        //    references the one shared R2 blob via `key`, so the media key stays E2E.
        let envelope = MediaEnvelope(media: ref, caption: caption)
        let envelopeData = try JSONEncoder().encode(envelope)
        // Ratchet-mutating section under the cross-process lock (the slow R2 upload
        // above ran OUTSIDE the lock so we don't stall the NSE on a large upload).
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(envelopeData, peerUserId: peerUserId)
            // 4. Send the per-device bundle, tagging it as media + the opaque ref for the server.
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages, content_type: "media",
                                     media_url: key, media_mime: mime))
            let echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                        text: caption, createdAt: res.created_at.map(parseDate) ?? Date(),
                                        isMine: true, media: ref)
            append(echo, to: conversationId)
            return echo
        }
    }

    // MARK: - Message actions (reaction / delete-for-everyone / reply / forward)
    //
    // Each rides the EXACT same per-device E2EE fan-out as any message; the server sees
    // only opaque ciphertext + a content_type routing hint. Receivers apply them in
    // decryptInboundLocked by probing the plaintext `"t"` discriminator.

    /// Send (or clear) a reaction to `targetServerId`. `emoji == nil` clears ours.
    /// No visible bubble — it decorates the target on both ends.
    func sendReaction(targetServerId: String, emoji: String?,
                      conversationId: String, peerUserId: String) async throws {
        let data = try JSONEncoder().encode(
            MessageReactionEnvelope(target: targetServerId, emoji: emoji))
        try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(data, peerUserId: peerUserId)
            _ = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages,
                                     content_type: MessageActionContentType.reaction)) as SendResponse
            // Apply our own reaction locally (keyed by OUR user id) and persist.
            applyReaction(target: targetServerId, from: TokenStore.shared.userId ?? "me",
                          emoji: emoji, in: conversationId)
        }
    }

    /// Ask every recipient to tombstone `targetServerId`. Only meaningful from the
    /// message's author — receivers enforce that.
    func sendDeleteForEveryone(targetServerId: String,
                               conversationId: String, peerUserId: String) async throws {
        let data = try JSONEncoder().encode(MessageDeleteEnvelope(target: targetServerId))
        try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(data, peerUserId: peerUserId)
            _ = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages,
                                     content_type: MessageActionContentType.delete)) as SendResponse
            applyDeleteForEveryone(target: targetServerId, in: conversationId)
        }
    }

    /// Send a text reply quoting another message. Renders as a normal bubble with a quote.
    @discardableResult
    func sendReply(text: String, quotedId: String, quotedPreview: String, quotedSender: String,
                   conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        let env = MessageReplyEnvelope(text: text, quotedId: quotedId,
                                       quotedPreview: quotedPreview, quotedSender: quotedSender)
        let data = try JSONEncoder().encode(env)
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(data, peerUserId: peerUserId)
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages,
                                     content_type: MessageActionContentType.reply))
            var echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                        text: text, createdAt: res.created_at.map(parseDate) ?? Date(),
                                        isMine: true)
            echo.quotedId = quotedId; echo.quotedPreview = quotedPreview; echo.quotedSender = quotedSender
            append(echo, to: conversationId)
            return echo
        }
    }

    /// Forward an EXISTING media message without re-uploading — the ciphertext already
    /// lives in R2, so we just re-send its MediaRef (the key stays E2E as always).
    @discardableResult
    func forwardMedia(_ ref: MediaRef, caption: String,
                      conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        let env = ForwardedMediaEnvelope(media: ref, caption: caption)
        let data = try JSONEncoder().encode(env)
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(data, peerUserId: peerUserId)
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages, content_type: MessageActionContentType.media,
                                     media_url: ref.mediaUrl, media_mime: ref.mime))
            var echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                        text: caption, createdAt: res.created_at.map(parseDate) ?? Date(),
                                        isMine: true, media: ref)
            echo.forwarded = true
            append(echo, to: conversationId)
            return echo
        }
    }

    // Local appliers — shared by the senders (our own action) and inbound (a peer's).

    /// Set or clear `userId`'s reaction on the message whose serverId (or local id) matches.
    func applyReaction(target: String, from userId: String, emoji: String?, in convId: String) {
        guard var arr = store[convId],
              let i = arr.firstIndex(where: { $0.serverId == target || $0.id == target }) else { return }
        var map = arr[i].reactions ?? [:]
        if let emoji { map[userId] = emoji } else { map.removeValue(forKey: userId) }
        arr[i].reactions = map.isEmpty ? nil : map
        store[convId] = arr
        persist()
    }

    /// Tombstone the target message (delete-for-everyone).
    func applyDeleteForEveryone(target: String, in convId: String) {
        guard var arr = store[convId],
              let i = arr.firstIndex(where: { $0.serverId == target || $0.id == target }) else { return }
        arr[i].deletedForEveryone = true
        arr[i].text = ""
        arr[i].media = nil
        arr[i].reactions = nil
        store[convId] = arr
        persist()
    }

    /// Send a location envelope (pin or live-share CONTROL) in a direct chat over the
    /// durable message path (docs/LOCATION.md §1–2). `plaintextJSON` is the full envelope
    /// (it may carry the shareKey, which stays end-to-end — the server only ever sees
    /// `content_type: "location"` + opaque ciphertext). A visible local echo is appended
    /// only when `rendersBubble` is true; its persisted JSON has the key stripped.
    func sendLocation(plaintextJSON: String, conversationId: String, peerUserId: String,
                      displayText: String, rendersBubble: Bool) async throws {
        let plaintext = Data(plaintextJSON.utf8)
        try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(plaintext, peerUserId: peerUserId)
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages, content_type: "location"))
            if rendersBubble {
                let echo = DecryptedMessage(id: res.message_id,
                                            senderId: TokenStore.shared.userId ?? "me",
                                            text: displayText,
                                            createdAt: res.created_at.map(parseDate) ?? Date(),
                                            isMine: true,
                                            locationJSON: LocationWire.strip(plaintextJSON),
                                            deliveryStatus: "sent")
                append(echo, to: conversationId)
            }
        }
    }

    /// Fetch + decrypt a media blob referenced by a (received) message. Returns the
    /// PLAINTEXT bytes (the caller renders them); decryption uses the per-message
    /// media key carried in the E2EE envelope.
    func fetchMedia(_ ref: MediaRef) async throws -> Data {
        let ciphertext = try await MediaService.shared.download(key: ref.mediaUrl)
        let mediaKey = MediaKey(key: ref.key, nonce: ref.nonce, ciphertextSha256: ref.sha256)
        return try decryptMedia(mediaKey: mediaKey, ciphertext: ciphertext)
    }

    /// Fetch the server's message list, decrypt ONLY ids we haven't seen, persist,
    /// and return the full conversation (oldest-first). Serialized per conversation so
    /// concurrent syncs can't double-acceptSession the same PreKey messages.
    @discardableResult
    func sync(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        await lockSync(conversationId)
        defer { unlockSync(conversationId) }
        // CROSS-PROCESS single-writer: the NSE decrypts in a separate process. Hold the
        // app-group lock across the whole fetch→decrypt→persist span and re-read shared
        // state first, so the app and the NSE can never advance the same ratchet at once.
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            return try await runSyncLocked(conversationId: conversationId, peerUserId: peerUserId)
        }
    }

    /// Drop this process's in-memory caches and re-read the authoritative shared state
    /// (session pickles from the shared keychain, the decrypted-message store from the
    /// app-group file, the identity to pick up one-time-key consumption). MUST be called
    /// at the top of every cross-process-locked critical section — otherwise a stale
    /// cached session/store from before the OTHER process's write would double-decrypt.
    private func reloadSharedState() {
        sessions.removeAll()                    // force candidateSessions to re-read keychain
        loadStore()                             // pick up messages the NSE/app decrypted
        E2EManager.shared.reloadIdentity()      // pick up one-time-key consumption
    }

    // MARK: - Notification Service Extension entry point

    /// A decrypted preview for the NSE to display, or nil to fall back to the generic
    /// "New message" placeholder.
    struct NotificationPreview { let title: String; let body: String; let threadId: String }

    /// Decrypt an incoming message IN THE EXTENSION and return the preview to display.
    ///
    /// This runs the EXACT same cross-process-locked decrypt-once path as the app's
    /// `sync`, so a message decrypted here is marked seen in the shared store and the
    /// app will NOT re-decrypt it (and vice-versa) — no ratchet desync. Restores the
    /// identity from the shared keychain WITHOUT any device registration (that stays the
    /// app's job). Returns nil on any failure so the NSE shows the safe placeholder.
    func notificationDecrypt(messageId: String, conversationId: String) async -> NotificationPreview? {
        guard E2EManager.shared.loadForExtension() else { return nil }
        guard let myId = TokenStore.shared.userId else { return nil }

        // Resolve the conversation for its kind + the sender's display name + the 1:1 peer
        // (whose identity key/session we decrypt with).
        let detail = try? await fetchConversationDetail(conversationId)
        let members = detail?.members ?? []
        // Groups use MLS, not the 1:1 ratchet — a completely separate engine, its own
        // cross-process critical section. Branch BEFORE taking any lock here: flock is not
        // reentrant, so acquiring it around GroupEngine's own acquisition would deadlock
        // the extension against itself and deliver nothing.
        if detail?.conversation?.type == "group" {
            return await groupNotificationPreview(messageId: messageId, conversationId: conversationId,
                                                  members: members, groupName: detail?.conversation?.name)
        }
        let others = members.filter { $0.user_id != myId }
        guard others.count == 1, let peerUserId = others.first?.user_id else { return nil }

        await lockSync(conversationId)
        defer { unlockSync(conversationId) }
        let decrypted: [DecryptedMessage]
        do {
            decrypted = try await CrossProcessLock.withLock {
                reloadSharedState()
                // Inbound-only: the NSE must NEVER send, so it skips flushPending.
                return try await decryptInboundLocked(conversationId: conversationId, peerUserId: peerUserId)
            }
        } catch {
            NSLog("[VOIID] NSE decrypt failed conv=\(conversationId): \(error)")
            return nil
        }

        guard let msg = decrypted.first(where: { $0.id == messageId || $0.serverId == messageId }),
              !msg.isMine, !msg.failed else { return nil }
        // The peer's saved address-book name wins over the name they signed up with —
        // same precedence the in-app UI uses, resolved from the shared local database.
        let title = senderName(msg.senderId, members: members)
        let body: String
        if msg.media != nil {
            body = msg.text.isEmpty ? "📎 Media" : "📎 \(msg.text)"
        } else {
            body = msg.text.isEmpty ? "New message" : msg.text
        }
        return NotificationPreview(title: title, body: body, threadId: conversationId)
    }

    /// Preview for an MLS GROUP message: "<group name>" / "<sender>: <text>".
    ///
    /// Decryption is delegated wholesale to GroupEngine, which takes the cross-process lock
    /// and reloads MLS state itself — so this must be called with NO lock held. nil on any
    /// failure (not joined yet, epoch we haven't committed, timeout) so the extension shows
    /// the generic placeholder; a preview-less notification is bad, a missing one is worse.
    ///
    /// TRUST NOTE: the sender attribution is the server-asserted `messages.sender_id`, the
    /// same basis the in-app group UI uses. MLS's cryptographically authenticated sender
    /// leaf index is not exposed through the FFI, so a hostile server could mislabel WHO
    /// sent a message it cannot read. The content itself stays end-to-end encrypted.
    private func groupNotificationPreview(messageId: String, conversationId: String,
                                          members: [ConvMember], groupName: String?) async -> NotificationPreview? {
        guard let msg = await GroupEngine.shared.notificationDecrypt(
                conversationId: conversationId, messageId: messageId),
              !msg.isMine, !msg.failed else { return nil }
        let sender = senderName(msg.senderId, members: members)
        // Group title: the server's name, else the locally-cached conversation title, else a
        // neutral word — never the conversation UUID.
        let title = [groupName, SharedDirectory.conversationTitle(conversationId)]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Group"
        let text: String
        if msg.media != nil {
            text = msg.text.isEmpty ? "📎 Media" : "📎 \(msg.text)"
        } else {
            text = msg.text.isEmpty ? "New message" : msg.text
        }
        return NotificationPreview(title: title, body: "\(sender): \(text)", threadId: conversationId)
    }

    /// A human name for a sender, never a raw id: this device's address book first (via the
    /// shared local directory), then the profile name the server returned with the
    /// conversation, then "Unknown".
    private func senderName(_ senderId: String, members: [ConvMember]) -> String {
        let serverName = members.first { $0.user_id == senderId }?.full_name
        return SharedDirectory.displayName(senderId, fallback: serverName)
    }

    private struct ConvMember: Decodable { let user_id: String; let full_name: String? }
    /// `type` is "direct" | "group"; `name` is the group's server-side title (null for direct).
    private struct ConvSummary: Decodable { let type: String?; let name: String? }
    private struct ConvDetailResponse: Decodable {
        var conversation: ConvSummary? = nil
        let members: [ConvMember]
    }
    private func fetchConversationDetail(_ id: String) async throws -> ConvDetailResponse {
        try await api.request("GET", "conversations/\(id)")
    }

    @discardableResult
    private func runSyncLocked(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        await flushPendingLocked(conversationId: conversationId, peerUserId: peerUserId)   // push any queued sends first (lock already held)
        return try await decryptInboundLocked(conversationId: conversationId, peerUserId: peerUserId)
    }

    /// Fetch the conversation, decrypt-once every unseen INBOUND message, persist, and
    /// return the full conversation. Assumes the cross-process lock is held and shared
    /// state was reloaded. Shared by the app's `sync` and the NSE's notification decrypt
    /// (the NSE runs THIS directly — it must never send, so it skips `flushPendingLocked`).
    @discardableResult
    private func decryptInboundLocked(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        lastSyncHadDecryptFailure = false
        // Pass our own device_id so the server hands back only THIS device's per-device
        // ciphertext (each device has its own session, hence its own ciphertext).
        let devParam = E2EManager.shared.deviceId.map { "?device_id=\($0)" } ?? ""
        let env: MessagesResponse = try await api.request("GET", "messages/conversation/\(conversationId)\(devParam)")
        NSLog("[VOIID] sync conv=\(conversationId): server has \(env.messages.count) msgs")
        let myId = TokenStore.shared.userId
        // "seen" = ALL stored ids INCLUDING tombstones. A decrypt-once Olm message that
        // failed can NEVER be re-decrypted (recovery comes from the peer RE-SENDING a new
        // message, not retrying the dead id). Retrying tombstones every sync just re-fails
        // and keeps re-triggering session_reset, which destroys the working session
        // ("no matching session" cascade). So tombstone once, never retry.
        let seen = Set((store[conversationId] ?? []).map { $0.id })
        var newlyReceived: [String] = []
        for m in env.messages.reversed() {   // server DESC → process ASC
            // Our OWN sent message: we can't decrypt our ratchet output, but the server
            // tells us the recipient's receipt state — advance Sent→Delivered→Seen even
            // if the live WS receipt push was missed (WS-independent status).
            if m.sender_id == myId {
                let applied = m.receipt_status.flatMap { applyReceipt(messageId: m.id, status: $0) } != nil
                NSLog("[VOIID] 🟦 own msg \(m.id) receipt_status=\(m.receipt_status ?? "nil")\(applied ? " → applied" : "")")
                continue
            }
            if seen.contains(m.id) { continue }
            // A null ciphertext means the server had no per-device blob for us yet (e.g. our
            // device_id wasn't resolved when this row's fan-out was written, or delivery to
            // this device is still pending) — skip for now, it'll show up once available.
            guard let ciphertext = m.ciphertext, let wire = decodeWire(ciphertext) else {
                NSLog("[VOIID] ⚠️ skipping inbound id=\(m.id): no ciphertext for this device")
                continue
            }
            do {
                let plain = try await decryptInbound(wire, peerUserId: peerUserId,
                                                     senderDeviceId: m.sender_device_id)
                newlyReceived.append(m.id)
                NSLog("[VOIID] ✅ decrypted inbound id=\(m.id) senderDev=\(m.sender_device_id ?? "nil")")
                // ACTION envelopes decorate an EXISTING message rather than adding a bubble.
                // Probe the discriminator; if it's one, apply it and move on (it's now "seen",
                // so it won't be reprocessed).
                if let action = MessageActionInbound.parse(plain) {
                    switch action {
                    case .reaction(let target, let emoji):
                        applyReaction(target: target, from: m.sender_id, emoji: emoji, in: conversationId)
                    case .delete(let target):
                        // Only the ORIGINAL AUTHOR may delete: honour it only if the target
                        // was sent by this same peer (i.e. an inbound message from them).
                        let arr: [DecryptedMessage] = store[conversationId] ?? []
                        let targetMessage: DecryptedMessage? =
                            arr.first(where: { $0.serverId == target || $0.id == target })
                        if targetMessage?.senderId == m.sender_id {
                            applyDeleteForEveryone(target: target, in: conversationId)
                        }
                    }
                    // Keep this control id in the store (seen) but hidden from the UI.
                    append(DecryptedMessage(id: m.id, senderId: m.sender_id, text: "",
                                            createdAt: parseDate(m.created_at), isMine: false,
                                            control: true), to: conversationId)
                    continue
                }
                // A reply is a real bubble that also carries a quote.
                if let reply = MessageActionInbound.parseReply(plain) {
                    replace(id: m.id, with:
                            DecryptedMessage(id: m.id, senderId: m.sender_id, text: reply.text,
                                             createdAt: parseDate(m.created_at), isMine: false,
                                             quotedId: reply.quotedId, quotedPreview: reply.quotedPreview,
                                             quotedSender: reply.quotedSender),
                           to: conversationId)
                    continue
                }
                // A media message's plaintext is a JSON MediaEnvelope; a text
                // message is just the string. Detect via the server's content_type
                // hint, falling back to the decoded shape.
                let parsed = decodeEnvelope(plain, contentType: m.content_type)
                // A location envelope (pin / live control). LocationWire captures/erases the
                // shareKey in the Keychain (safe in the NSE too), strips it from the persisted
                // JSON, and yields a clean display string so no raw JSON — and NO coordinate —
                // ever reaches a notification body.
                let loc = LocationWire.decode(plain)
                replace(id: m.id, with:
                        DecryptedMessage(id: m.id, senderId: m.sender_id,
                                         text: loc?.text ?? parsed.caption,
                                         createdAt: parseDate(m.created_at), isMine: false,
                                         media: parsed.media, locationJSON: loc?.json),
                       to: conversationId)
            } catch {
                NSLog("[VOIID] ❌ inbound decrypt FAILED id=\(m.id) senderDev=\(m.sender_device_id ?? "nil"): \(error)")
                // Tombstone it (failed==true) so the chat shows a placeholder, asks the
                // sender to re-establish the session, and RETRIES on the next sync.
                if E2EManager.shared.identity != nil {
                    lastSyncHadDecryptFailure = true
                    replace(id: m.id, with:
                            DecryptedMessage(id: m.id, senderId: m.sender_id,
                                             text: "🔒 Message couldn’t be decrypted",
                                             createdAt: parseDate(m.created_at), isMine: false,
                                             failed: true),
                           to: conversationId)
                }
            }
        }
        persist()
        // Mark just-received messages DELIVERED (double-grey tick on the sender) —
        // even if the chat isn't open. Read is marked separately when it's opened.
        if !newlyReceived.isEmpty { await markReceipts(newlyReceived, status: "delivered") }
        return messages(conversationId: conversationId)
    }

    /// Apply a delivery/read receipt to one of OUR sent messages (persisted, never
    /// downgraded). Returns the conversation id so the UI can refresh just that chat.
    @discardableResult
    func applyReceipt(messageId: String, status: String) -> String? {
        let rank = ["sent": 0, "delivered": 1, "read": 2]
        for (cid, var arr) in store {
            if let i = arr.firstIndex(where: { $0.isMine && ($0.serverId == messageId || $0.id == messageId) }) {
                let cur = arr[i].deliveryStatus ?? "sent"
                if (rank[status] ?? 0) > (rank[cur] ?? 0) {
                    arr[i].deliveryStatus = status
                    store[cid] = arr
                    persist()
                }
                return cid
            }
        }
        return nil
    }

    private func markReceipts(_ ids: [String], status: String) async {
        guard !ids.isEmpty else { return }
        NSLog("[VOIID] 📤 receipt \(status) x\(ids.count)")
        struct Body: Encodable { let message_ids: [String]; let status: String }
        _ = try? await api.request("POST", "receipts/mark", body: Body(message_ids: ids, status: status)) as EmptyResponse
    }

    /// Mark all locally-stored inbound messages in a conversation as read. The
    /// server fans out a `receipt` WS event to the original senders (blue ticks).
    func markRead(conversationId: String) async {
        let ids = (store[conversationId] ?? []).filter { !$0.isMine }.map { $0.id }
        await markReceipts(ids, status: "read")
    }

    /// Decrypt a single inbound message and advance the session. Caller persists.
    /// `senderDeviceId` (from the message) selects the SENDER's device whose identity
    /// key we accept with — a multi-device sender may have encrypted with a device
    /// that isn't their "first", so resolving by it is what makes decrypt succeed.
    private func decryptInbound(_ wire: WireMessage,
                               peerUserId: String, senderDeviceId: String?) async throws -> String {
        // Decrypt with the session for the SPECIFIC (peer, sending device) that produced
        // this ciphertext — the server already handed us only our device's copy, and the
        // message names which of the sender's devices encrypted it.
        let devId = senderDeviceId ?? "default"
        // 1. Try EVERY known session for that device pair (glare → multiple). A non-matching
        //    session fails cleanly; the matching one decrypts (including later PreKey msgs of
        //    an already-accepted session — no re-accept, no extra OTK consumed).
        let list = candidateSessions(peerUserId, devId)
        for s in list {
            if let data = try? s.decrypt(message: wire) {
                saveSessions(peerUserId, devId)
                return String(decoding: data, as: UTF8.self)
            }
        }
        // 2. No existing session matched. Only a PreKey message can establish one.
        guard wire.msgType == 0 else {
            throw APIError.http(status: 422, message: "no matching session for message")
        }
        // 2b. DEDUP (libsignal promote_matching_session equivalent): if we ALREADY hold
        //     the session this PreKey would establish (same session id), it's a replay /
        //     out-of-order PreKey for a known session — never re-accept (that would burn
        //     another one-time key). Decrypt with the matching session instead.
        if let incomingId = prekeySessionId(message: wire),
           let s = list.first(where: { $0.sessionId() == incomingId }) {
            let data = try s.decrypt(message: wire)   // throws if genuinely undecryptable
            saveSessions(peerUserId, devId)
            return String(decoding: data, as: UTF8.self)
        }
        // 3. Accept a NEW inbound session and APPEND it (don't discard the others).
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let peer = try await peerIdentity(peerUserId, deviceId: senderDeviceId)
        try verifyAndPinIdentity(peer.key, peerUserId: peerUserId, deviceId: peer.deviceId)   // anti-MITM (TOFU, per device)
        let accepted = try id.acceptSession(theirIdentityKey: peer.key, firstMessage: wire)
        sessions[sessionKey(peerUserId, devId), default: []].append(accepted.session)
        saveSessions(peerUserId, devId)
        E2EManager.shared.persistIdentity()   // acceptSession consumed a one-time key —
                                              // save it or the first message is lost on restart.
        return String(decoding: accepted.plaintext, as: UTF8.self)
    }

    // MARK: - Multi-device fan-out (encrypt once per target device)

    /// A remote device we must deliver to: a conversation peer's device, or one of our
    /// own OTHER (linked) devices. `userId` owns `deviceId`.
    private struct TargetDevice { let userId: String; let deviceId: String }

    /// One target device's ciphertext in a fan-out bundle.
    private struct DeviceCiphertext: Encodable { let recipient_device_id: String; let ciphertext: String }

    /// Encrypt `plaintext` ONCE PER TARGET DEVICE and return the per-device bundle
    /// (`[{recipient_device_id, ciphertext}]`). Targets = every active device of the
    /// conversation peer PLUS our own OTHER devices, EXCLUDING this sending device.
    /// Devices we can't build a session for (no published prekey) are skipped + logged so
    /// the rest still deliver; if NOTHING is deliverable we throw a retryable (409) error
    /// so the message stays pending and re-sends once prekeys appear.
    private func encryptFanout(_ plaintext: Data, peerUserId: String) async throws -> [DeviceCiphertext] {
        let targets = try await resolveTargets(peerUserId)
        if targets.isEmpty { throw APIError.http(status: 409, message: "no target devices for peer") }
        let out = try await fanOut(plaintext, targets: targets)
        // Nothing deliverable (e.g. peer hasn't published prekeys yet) — retryable, like the
        // legacy single-device path, so the 4s poll re-sends when keys appear.
        if out.isEmpty { throw APIError.http(status: 409, message: "peer has no available prekeys") }
        return out
    }

    /// The core fan-out: encrypt `plaintext` once per TARGET device, reusing the hard-won
    /// per-device session keying (glare candidates, append-never-overwrite, one bundle
    /// fetch per user). Both the 1:1 path (`encryptFanout`) and the Stories path
    /// (`encryptStoryKeys`) route through here so the correctness lives in ONE place.
    /// Devices with no bundle / no available one-time prekey are skipped + logged.
    private func fanOut(_ plaintext: Data, targets: [TargetDevice]) async throws -> [DeviceCiphertext] {
        var out: [DeviceCiphertext] = []
        // Group by owning user so we fetch each user's prekey bundles at most once per send
        // (each GET consumes a one-time key per device — don't call it per device).
        let byUser = Dictionary(grouping: targets, by: { $0.userId })
        for (userId, devs) in byUser {
            let needBundles = devs.contains { candidateSessions(userId, $0.deviceId).isEmpty }
            let bundles = needBundles ? ((try? await fetchBundles(userId)) ?? [:]) : [:]
            for t in devs {
                guard let session = try outboundSessionFor(t, bundles: bundles) else {
                    NSLog("[VOIID] ⏭️ fan-out skip device=\(t.deviceId) user=\(t.userId) (no session/prekey)")
                    continue
                }
                let wire = try session.encrypt(plaintext: plaintext)
                saveSessions(t.userId, t.deviceId)
                out.append(DeviceCiphertext(recipient_device_id: t.deviceId, ciphertext: encodeWire(wire)))
            }
        }
        return out
    }

    /// All target devices for a send: peer's active devices + our OWN other devices,
    /// minus this sending device.
    private func resolveTargets(_ peerUserId: String) async throws -> [TargetDevice] {
        var targets: [TargetDevice] = []
        let peerDevs: DevicesResponse = try await api.request("GET", "devices/\(peerUserId)")
        peerDevs.devices.forEach { targets.append(TargetDevice(userId: peerUserId, deviceId: $0.id)) }
        // Our own OTHER devices (linked-device sync of sent messages), excluding this one.
        let myDev = E2EManager.shared.deviceId
        if let myId = TokenStore.shared.userId {
            let mine: DevicesResponse = try await api.request("GET", "devices/\(myId)")
            mine.devices.filter { $0.id != myDev }.forEach { targets.append(TargetDevice(userId: myId, deviceId: $0.id)) }
        }
        return targets
    }

    /// Get (reuse) or establish the outbound session for one target device. Returns nil
    /// — skip this device — when it has no bundle / no available one-time prekey.
    private func outboundSessionFor(_ t: TargetDevice, bundles: [String: BundleDTO]) throws -> Session? {
        // Reuse the stable (first/oldest) existing session so we don't keep minting new ones.
        if let s = candidateSessions(t.userId, t.deviceId).first { return s }
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        guard let b = bundles[t.deviceId] else { return nil }        // no bundle for this device
        guard let otk = b.one_time_prekey else { return nil }        // no available prekey → skip
        try verifyAndPinIdentity(b.identity_public_key, peerUserId: t.userId, deviceId: t.deviceId)  // anti-MITM (TOFU, per device)
        let s = try id.startSession(theirIdentityKey: b.identity_public_key, theirOneTimeKey: otk.public_key)
        sessions[sessionKey(t.userId, t.deviceId), default: []].append(s)
        saveSessions(t.userId, t.deviceId)
        return s
    }

    /// Fetch a user's prekey bundles, keyed by device id (one bundle per device; each
    /// consumes one of that device's one-time prekeys).
    private func fetchBundles(_ userId: String) async throws -> [String: BundleDTO] {
        let env: PrekeysResponse = try await api.request("GET", "prekeys/\(userId)")
        var out: [String: BundleDTO] = [:]
        for b in env.bundles { if let dev = b.device_id { out[dev] = b } }
        return out
    }

    // MARK: - Identity pinning (anti-MITM / "safety numbers", trust-on-first-use)

    /// On first contact we PIN the peer's identity public key. On every later use we
    /// require it to match — a changed key means a possible server-side key-swap
    /// (MITM) and we refuse rather than silently re-keying. This is the core
    /// protection that makes the E2EE meaningful against a hostile server.
    /// Pinned PER (peer, device): a multi-device peer legitimately has a different
    /// identity key per device, so keying the pin by device avoids a false MITM
    /// rejection while still catching a real key-swap on a given device.
    private func verifyAndPinIdentity(_ identityKey: String, peerUserId: String, deviceId: String?) throws {
        let pinName = "idpin_\(peerUserId)_\(deviceId ?? "default")"
        if let pinned = kc.string(pinName) {
            guard pinned == identityKey else {
                throw APIError.http(status: 495, message: "peer identity key changed — possible MITM; verify safety number before continuing")
            }
        } else {
            kc.set(identityKey, pinName)
        }
    }

    // MARK: - Peer key resolution

    private struct DeviceDTO: Decodable { let id: String; let identity_public_key: String }
    private struct DevicesResponse: Decodable { let devices: [DeviceDTO] }
    private struct BundleDTO: Decodable {
        let device_id: String?
        let identity_public_key: String
        let one_time_prekey: OTKDTO?
    }
    private struct OTKDTO: Decodable { let public_key: String }
    private struct PrekeysResponse: Decodable { let bundles: [BundleDTO] }

    /// Peer's identity public key + device id (for acceptSession). Resolves the
    /// SPECIFIC device that sent the message (`deviceId`) so a multi-device sender
    /// decrypts correctly; falls back to the first device if unknown/missing.
    private func peerIdentity(_ userId: String, deviceId: String?) async throws -> (key: String, deviceId: String) {
        let env: DevicesResponse = try await api.request("GET", "devices/\(userId)")
        let d = (deviceId.flatMap { id in env.devices.first { $0.id == id } }) ?? env.devices.first
        guard let dev = d else { throw APIError.http(status: 404, message: "peer has no device") }
        return (dev.identity_public_key, dev.id)
    }

    // MARK: - Local message store (decrypt-once; plaintext at rest, file-protected)

    private func append(_ m: DecryptedMessage, to convId: String, persist doPersist: Bool = true) {
        var arr = store[convId] ?? []
        guard !arr.contains(where: { $0.id == m.id }) else { return }
        arr.append(m)
        store[convId] = arr
        if doPersist { persist() }
    }

    /// Insert `m`, or REPLACE an existing entry with the same id in place (keeps order).
    /// Used by sync so a tombstone that later decrypts is upgraded to the real message.
    private func replace(id: String, with m: DecryptedMessage, to convId: String) {
        var arr = store[convId] ?? []
        if let i = arr.firstIndex(where: { $0.id == id }) { arr[i] = m } else { arr.append(m) }
        store[convId] = arr
    }

    /// The decrypted-message store lives in the APP-GROUP container so the NSE (a
    /// separate process) reads/appends the SAME store — this is what makes decrypt-once
    /// work across processes. Falls back to the app-private Application Support dir only
    /// if the app-group container is somehow unavailable (mis-provisioned build).
    private var storeURL: URL {
        if let shared = AppGroup.messageStoreURL { return shared }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiid_messages.json")
    }

    /// Legacy app-private store path (pre-app-group). Migrated into the shared
    /// container once so existing installs keep their history.
    private var legacyStoreURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent("voiid_messages.json")
    }

    private func loadStore() {
        // One-time migration: seed the shared store from the legacy app-private file.
        if let shared = AppGroup.messageStoreURL,
           !FileManager.default.fileExists(atPath: shared.path),
           FileManager.default.fileExists(atPath: legacyStoreURL.path) {
            try? FileManager.default.copyItem(at: legacyStoreURL, to: shared)
        }
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([String: [DecryptedMessage]].self, from: data) else { return }
        store = decoded
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(store) else { return }
        // Protection class MUST match the keychain items this store is kept in step with.
        // The identity/session/MLS pickles are `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`
        // (E2EManager), so the NSE can reach them on a locked device — but with
        // `.completeFileProtection` this file was unreadable in exactly that state. The NSE
        // would then advance the ratchet in the keychain while failing to record the message
        // here, and a failed LOAD is the dangerous half: `store` reads back empty and the next
        // write persists that empty store over real history.
        //
        // `.completeFileProtectionUntilFirstUserAuthentication` keeps the file encrypted at
        // rest until the first unlock after boot, which is the strongest class that still
        // lets a background extension do its job. Same class as the SQLite database.
        try? data.write(to: storeURL,
                        options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    // MARK: - Session persistence (pickled in Keychain)

    /// Set true by `sync` when any inbound message failed to decrypt this run, so the
    /// caller can ask the sender (over WS) to re-establish the session.
    private(set) var lastSyncHadDecryptFailure = false

    /// In-memory + on-disk key for a remote device's session list.
    private func sessionKey(_ userId: String, _ deviceId: String) -> String { "\(userId)::\(deviceId)" }
    /// Keychain account for a remote device's persisted session list.
    private func sessionKCKey(_ userId: String, _ deviceId: String) -> String { "sess_\(userId)::\(deviceId)" }

    /// Drop ALL cached + persisted sessions with `peerUserId` (across every one of that
    /// peer's devices) so the NEXT outbound message re-establishes fresh sessions.
    func resetSession(_ peerUserId: String) {
        let memPrefix = "\(peerUserId)::"
        // Keychain has no prefix-scan, so delete the on-disk pickle for each device we
        // currently hold in memory, then drop the in-memory cache.
        for k in sessions.keys where k.hasPrefix(memPrefix) {
            kc.delete("sess_\(k)")   // sess_\(userId)::\(deviceId)  == sessionKCKey(...)
            sessions[k] = nil
        }
        NSLog("[VOIID] session reset for peer=\(peerUserId) (all cached devices)")
    }

    /// All candidate sessions for one (peer, device) pair (loaded from the Keychain on first access).
    private func candidateSessions(_ userId: String, _ deviceId: String) -> [Session] {
        let key = sessionKey(userId, deviceId)
        if let s = sessions[key] { return s }
        let restored = restoreSessions(userId, deviceId)
        sessions[key] = restored
        return restored
    }

    /// Restore a device's persisted session list (newline-separated pickles).
    private func restoreSessions(_ userId: String, _ deviceId: String) -> [Session] {
        guard let blob = kc.string(sessionKCKey(userId, deviceId)) else { return [] }
        return blob.split(separator: "\n").compactMap {
            try? Session.restore(pickle: String($0), pickleKey: sessionPickleKey())
        }
    }

    /// Persist a device's sessions as newline-separated pickles.
    private func saveSessions(_ userId: String, _ deviceId: String) {
        guard let list = sessions[sessionKey(userId, deviceId)] else { return }
        let blob = list.compactMap { try? $0.toPickle(pickleKey: sessionPickleKey()) }.joined(separator: "\n")
        kc.set(blob, sessionKCKey(userId, deviceId))
    }
    private func sessionPickleKey() -> Data {
        if let k = kc.data(sessionPickleKeyName), k.count == 32 { return k }
        var b = [UInt8](repeating: 0, count: 32); _ = SecRandomCopyBytes(kSecRandomDefault, 32, &b)
        let d = Data(b); kc.setData(d, sessionPickleKeyName); return d
    }

    // MARK: - Wire (de)serialization

    private struct WirePayload: Codable { let t: UInt64; let b: String }
    private func encodeWire(_ w: WireMessage) -> String {
        let json = try! JSONEncoder().encode(WirePayload(t: w.msgType, b: w.body))
        return json.base64EncodedString()
    }
    private func decodeWire(_ ciphertext: String) -> WireMessage? {
        // Be lenient: Data(base64Encoded:) is STRICT (rejects unpadded / whitespace).
        // Try strict, then padded, then ignore-unknown-chars — so a peer/server that
        // emits unpadded standard base64 never causes a silent drop.
        let data = Data(base64Encoded: ciphertext)
            ?? Data(base64Encoded: ciphertext.padded64)
            ?? Data(base64Encoded: ciphertext, options: .ignoreUnknownCharacters)
            ?? Data(base64Encoded: ciphertext.padded64, options: .ignoreUnknownCharacters)
        guard let data, let p = try? JSONDecoder().decode(WirePayload.self, from: data) else {
            NSLog("[VOIID] ⚠️ decodeWire FAILED (len=\(ciphertext.count)) — dropping inbound")
            return nil
        }
        return WireMessage(msgType: p.t, body: p.b)
    }

    private func parseDate(_ s: String) -> Date { ISO8601DateFormatter().date(from: s) ?? Date() }

    // MARK: - Media envelope (the E2EE plaintext of a media message)

    /// The plaintext we encrypt for a media message: the media reference + an
    /// optional caption. A marker field disambiguates it from a plain text body.
    private struct MediaEnvelope: Codable {
        let v: Int                // envelope version
        let media: MediaRef
        let caption: String
        init(media: MediaRef, caption: String) { self.v = 1; self.media = media; self.caption = caption }
    }

    /// Decode a decrypted plaintext into (caption, media?). Media envelopes are keyed on
    /// `content_type == "media"` as before. Story replies (content_type "story_reply") are
    /// decoded ADDITIVELY here so their JSON body is never rendered as raw text (§5.3) —
    /// plus a defensive fallback: any plaintext that parses as a JSON object carrying a
    /// recognised `"t"` is decoded, not shown verbatim.
    private func decodeEnvelope(_ plain: String, contentType: String?) -> (caption: String, media: MediaRef?) {
        let data = plain.data(using: .utf8)
        if contentType == "media", let data,
           let env = try? JSONDecoder().decode(MediaEnvelope.self, from: data) {
            return (env.caption, env.media)
        }
        // A story reply carries a typed envelope; render its body (reaction or text), and
        // NEVER leave the raw JSON in a bubble. The `"t"` probe also catches the case where
        // an older content_type hint is missing but the payload is a recognised envelope.
        if let data, let probe = try? JSONDecoder().decode(EnvelopeProbe.self, from: data),
           probe.t == "story_reply",
           let reply = try? JSONDecoder().decode(StoryReplyEnvelope.self, from: data) {
            let body = reply.reaction ?? reply.text
            return (body, nil)
        }
        return (plain, nil)
    }

    /// Peeks only at an envelope's discriminator so we can decode the right concrete type.
    private struct EnvelopeProbe: Decodable { let t: String? }

    // DTOs for messages API

    /// Multi-device fan-out send: one ciphertext per TARGET device.
    private struct SendBundleBody: Encodable {
        let conversation_id: String
        var sender_device_id: String? = nil   // which of OUR devices encrypted these
        let messages: [DeviceCiphertext]       // one entry per target device
        var content_type: String? = nil
        var media_url: String? = nil
        var media_mime: String? = nil
    }
    private struct SendResponse: Decodable {
        let message_id: String
        var created_at: String? = nil
        var delivered_devices: Int = 0
    }
    private struct MessageDTO: Decodable {
        let id: String; let sender_id: String; let ciphertext: String?; let created_at: String
        var sender_device_id: String? = nil   // which of the SENDER's devices encrypted it
        var content_type: String? = nil
        var receipt_status: String? = nil      // "delivered"/"read" — recipient's state of OUR sent msg
    }
    private struct MessagesResponse: Decodable { let messages: [MessageDTO] }

    // MARK: - Stories
    //
    // Stories reuse this engine's crypto wholesale: a story blob is encrypted with the
    // SAME `encryptMedia` primitive as a media message, and the per-device key envelope
    // is an ORDINARY ratchet message fanned out through the SAME session machinery. All of
    // it lives here (not in StoryEngine) so the crypto stays in one place and StoryEngine
    // never touches a Session, an Identity, or a media key. See docs/STORIES_PROTOCOL.md.

    /// Encrypt a story blob once with a fresh random AES-256-GCM key (§1.3 step 2). Returns
    /// the ciphertext (PUT straight to R2) and the media key parts that go INTO the envelope
    /// — the key never leaves E2E.
    func encryptStoryBlob(_ data: Data) throws -> (ciphertext: Data, key: String, nonce: String, sha256: String) {
        let enc = try encryptMedia(plaintext: data)
        return (enc.ciphertext, enc.mediaKey.key, enc.mediaKey.nonce, enc.mediaKey.ciphertextSha256)
    }

    /// Fetch-verify-decrypt a story blob given its media key (from the decrypted envelope).
    /// `decryptMedia` verifies the ciphertext SHA-256 before decrypting, so a mismatch
    /// throws rather than returning a blank frame (§1.5.7).
    func decryptStoryBlob(ciphertext: Data, key: String, nonce: String, sha256: String) throws -> Data {
        try decryptMedia(mediaKey: MediaKey(key: key, nonce: nonce, ciphertextSha256: sha256),
                         ciphertext: ciphertext)
    }

    /// Fan out a story key `envelope` to every active device of `audienceUserIds`, plus
    /// (when `includeOwnDevices`) our own OTHER devices, minus this posting device. Each
    /// device's copy is `Session.encrypt(envelope)` over the existing 1:1 ratchet, so a
    /// story key is exactly one ordinary ratchet message per device (§1.3 step 7). Devices
    /// with no available prekey are skipped + logged — partial delivery is the norm on this
    /// transport and `POST /stories/:id/keys` retries the rest. Ratchet-mutating, so it runs
    /// under the cross-process lock like every other fan-out.
    func encryptStoryKeys(_ envelope: Data, audienceUserIds: [String],
                          includeOwnDevices: Bool) async throws -> [(deviceId: String, ciphertext: String)] {
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            let targets = try await resolveStoryTargets(audienceUserIds, includeOwnDevices: includeOwnDevices)
            let out = try await fanOut(envelope, targets: targets)
            return out.map { ($0.recipient_device_id, $0.ciphertext) }
        }
    }

    /// Target devices for a story: every audience user's active devices, plus optionally
    /// our own other devices, minus this device. Deduped by device id (the audience may
    /// overlap with ourselves, or a user may appear twice).
    private func resolveStoryTargets(_ userIds: [String], includeOwnDevices: Bool) async throws -> [TargetDevice] {
        var targets: [TargetDevice] = []
        var seen = Set<String>()
        let myDev = E2EManager.shared.deviceId
        let myId = TokenStore.shared.userId
        for uid in userIds {
            let devs: DevicesResponse = (try? await api.request("GET", "devices/\(uid)")) ?? DevicesResponse(devices: [])
            for d in devs.devices where d.id != myDev && seen.insert(d.id).inserted {
                targets.append(TargetDevice(userId: uid, deviceId: d.id))
            }
        }
        if includeOwnDevices, let myId {
            let mine: DevicesResponse = (try? await api.request("GET", "devices/\(myId)")) ?? DevicesResponse(devices: [])
            for d in mine.devices where d.id != myDev && seen.insert(d.id).inserted {
                targets.append(TargetDevice(userId: myId, deviceId: d.id))
            }
        }
        return targets
    }

    /// Decrypt a story key envelope THIS device received from the feed. `authorDeviceId`
    /// selects the author device whose session produced it. Returns nil to DROP (the caller
    /// surfaces "This story couldn't be loaded", never a blank frame).
    func decryptStoryEnvelope(ciphertextB64: String, authorUserId: String,
                              authorDeviceId: String?) async -> Data? {
        guard let wire = decodeWire(ciphertextB64) else { return nil }
        return await CrossProcessLock.withLock {
            reloadSharedState()
            do {
                let plain = try await decryptInbound(wire, peerUserId: authorUserId, senderDeviceId: authorDeviceId)
                return Data(plain.utf8)
            } catch {
                NSLog("[VOIID] story envelope decrypt failed author=\(authorUserId): \(error)")
                return nil
            }
        }
    }

    /// Decrypt a view receipt on the AUTHOR side. The API deliberately does not tell us who
    /// posted it (the viewer id lives inside the encrypted payload), so we try the story's
    /// KNOWN AUDIENCE devices — the author already holds a session with each, established
    /// when the story key was fanned out to them. Returns nil to drop.
    func decryptStoryReceipt(ciphertextB64: String, audienceUserIds: [String]) async -> Data? {
        guard let wire = decodeWire(ciphertextB64) else { return nil }
        return await CrossProcessLock.withLock {
            reloadSharedState()
            for uid in audienceUserIds {
                guard let devs: DevicesResponse = try? await api.request("GET", "devices/\(uid)") else { continue }
                for d in devs.devices {
                    if let plain = try? await decryptInbound(wire, peerUserId: uid, senderDeviceId: d.id) {
                        return Data(plain.utf8)
                    }
                }
            }
            return nil
        }
    }

    /// Send a story reply as an ordinary 1:1 message (content_type "story_reply", §5). It
    /// lands in the chat with the author and does NOT expire with the story. Reuses the
    /// exact fan-out used for a text message.
    @discardableResult
    func sendStoryReply(_ envelope: StoryReplyEnvelope,
                        conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        let data = try JSONEncoder().encode(envelope)
        return try await CrossProcessLock.withLock {
            reloadSharedState()
            let messages = try await encryptFanout(data, peerUserId: peerUserId)
            let res: SendResponse = try await api.request(
                "POST", "messages/send",
                body: SendBundleBody(conversation_id: conversationId,
                                     sender_device_id: E2EManager.shared.deviceId,
                                     messages: messages, content_type: "story_reply"))
            let body = envelope.reaction ?? envelope.text
            let echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                        text: body, createdAt: res.created_at.map(parseDate) ?? Date(),
                                        isMine: true)
            append(echo, to: conversationId)
            return echo
        }
    }
}

// MARK: - Location wire (docs/LOCATION.md §4)

/// Decodes a location envelope from a decrypted plaintext, WITHOUT depending on any
/// app-only type — pure Foundation + `KeychainData` — so it compiles in BOTH the app and
/// the Notification Service Extension (which share ChatEngine/GroupEngine but not the app's
/// model layer). It has three jobs:
///   1. Recognise a `_vloc == 1` envelope and produce a clean DISPLAY string, so no raw
///      JSON — and critically NO coordinate — ever reaches a notification body.
///   2. Capture (live_start/rekey) or erase (live_stop) the shareKey in the Keychain. The
///      key MUST be captured wherever the message is first decrypted, including the NSE,
///      or a share received while the app is closed can never be decrypted afterwards.
///   3. STRIP the key from the JSON that gets persisted in the plaintext message store —
///      keys live in the secure store, never in SQLite (docs/LOCATION.md §6).
enum LocationWire {
    // Same Keychain service + naming as LocationKeyStore (the app-side accessor), so a key
    // captured here in the NSE is the exact one the app later reads.
    private static let vault = KeychainData(service: "com.voiid.location.keys")
    private static func keyName(_ shareId: String) -> String { "sharekey_\(shareId)" }

    /// Rendered kinds get a bubble; everything else is silent control.
    static func displayText(kind: String, label: String?) -> String {
        switch kind {
        case "pin":        return (label?.isEmpty == false ? label! : "Location")
        case "live_start": return "Live location"
        case "live_stop":  return "Live location ended"
        default:           return ""
        }
    }

    /// Strip the shareKey from an envelope JSON, returning the safe-to-persist string.
    static func strip(_ plaintextJSON: String) -> String {
        guard let data = plaintextJSON.data(using: .utf8),
              var obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["_vloc"] as? Int) == 1 else { return plaintextJSON }
        obj["key"] = nil
        return (try? JSONSerialization.data(withJSONObject: obj))
            .flatMap { String(data: $0, encoding: .utf8) } ?? plaintextJSON
    }

    /// Full decode: capture/erase the key, and return (clean display text, key-stripped
    /// JSON). nil when the plaintext is not a location envelope.
    static func decode(_ plaintext: String) -> (text: String, json: String)? {
        guard let data = plaintext.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (obj["_vloc"] as? Int) == 1,
              let kind = obj["k"] as? String else { return nil }

        if let shareId = obj["s"] as? String {
            switch kind {
            case "live_start", "live_rekey", "map_key":
                if let key = obj["key"] as? String { vault.set(key, keyName(shareId)) }
            case "live_stop", "map_off":
                vault.delete(keyName(shareId))
            default: break
            }
            // Wake the app to reconcile inbound-share state (harmless in the NSE — no
            // observers there). String name avoids a cross-file Notification.Name dependency.
            NotificationCenter.default.post(name: Notification.Name("voiidLocationInboxChanged"),
                                            object: shareId)
        }

        var stripped = obj; stripped["key"] = nil
        let json = (try? JSONSerialization.data(withJSONObject: stripped))
            .flatMap { String(data: $0, encoding: .utf8) } ?? plaintext
        return (displayText(kind: kind, label: obj["label"] as? String), json)
    }
}
