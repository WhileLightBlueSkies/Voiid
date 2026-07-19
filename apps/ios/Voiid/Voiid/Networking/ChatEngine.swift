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

/// A decrypted message ready for the UI (and the on-disk store record).
/// For media messages `text` holds a caption (often empty) and `media` carries
/// the reference needed to fetch + decrypt the blob on demand.
struct DecryptedMessage: Codable {
    let id: String                 // stable LOCAL id (kept across send so the UI is stable)
    let senderId: String
    let text: String
    let createdAt: Date
    let isMine: Bool
    var media: MediaRef? = nil
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
    func messages(conversationId: String) -> [DecryptedMessage] {
        (store[conversationId] ?? []).sorted { $0.createdAt < $1.createdAt }
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

        // Resolve members for the sender's display name + the 1:1 peer (whose identity
        // key/session we decrypt with). Group conversations aren't previewed here.
        let members = (try? await fetchConversationMembers(conversationId)) ?? []
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
        let title = members.first(where: { $0.user_id == msg.senderId })?.full_name ?? "New message"
        let body: String
        if msg.media != nil {
            body = msg.text.isEmpty ? "📎 Media" : "📎 \(msg.text)"
        } else {
            body = msg.text.isEmpty ? "New message" : msg.text
        }
        return NotificationPreview(title: title, body: body, threadId: conversationId)
    }

    private struct ConvMember: Decodable { let user_id: String; let full_name: String? }
    private struct ConvDetailResponse: Decodable { let members: [ConvMember] }
    private func fetchConversationMembers(_ id: String) async throws -> [ConvMember] {
        let env: ConvDetailResponse = try await api.request("GET", "conversations/\(id)")
        return env.members
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
            guard let wire = decodeWire(m.ciphertext) else { continue }
            do {
                let plain = try await decryptInbound(wire, peerUserId: peerUserId,
                                                     senderDeviceId: m.sender_device_id)
                newlyReceived.append(m.id)
                NSLog("[VOIID] ✅ decrypted inbound id=\(m.id) senderDev=\(m.sender_device_id ?? "nil")")
                // A media message's plaintext is a JSON MediaEnvelope; a text
                // message is just the string. Detect via the server's content_type
                // hint, falling back to the decoded shape.
                let parsed = decodeEnvelope(plain, isMedia: m.content_type == "media")
                replace(id: m.id, with:
                        DecryptedMessage(id: m.id, senderId: m.sender_id, text: parsed.caption,
                                         createdAt: parseDate(m.created_at), isMine: false,
                                         media: parsed.media),
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
        // Nothing deliverable (e.g. peer hasn't published prekeys yet) — retryable, like the
        // legacy single-device path, so the 4s poll re-sends when keys appear.
        if out.isEmpty { throw APIError.http(status: 409, message: "peer has no available prekeys") }
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
        try? data.write(to: storeURL, options: [.atomic, .completeFileProtection])
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

    /// Decode a decrypted plaintext into (caption, media?). If the server flagged
    /// it as media (or it parses as a MediaEnvelope), pull out the reference;
    /// otherwise it's a plain text body.
    private func decodeEnvelope(_ plain: String, isMedia: Bool) -> (caption: String, media: MediaRef?) {
        if isMedia, let data = plain.data(using: .utf8),
           let env = try? JSONDecoder().decode(MediaEnvelope.self, from: data) {
            return (env.caption, env.media)
        }
        return (plain, nil)
    }

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
        let id: String; let sender_id: String; let ciphertext: String; let created_at: String
        var sender_device_id: String? = nil   // which of the SENDER's devices encrypted it
        var content_type: String? = nil
        var receipt_status: String? = nil      // "delivered"/"read" — recipient's state of OUR sent msg
    }
    private struct MessagesResponse: Decodable { let messages: [MessageDTO] }
}
