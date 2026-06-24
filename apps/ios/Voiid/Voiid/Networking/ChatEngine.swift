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
    // conversationId -> ALL candidate Olm sessions. During simultaneous initiation
    // ("glare") both peers create their own session, so a conversation legitimately has
    // more than one. Keep them all: try each on decrypt, append (never overwrite) a
    // newly-accepted one — overwriting strands the peer's early PreKey messages forever.
    private var sessions: [String: [Session]] = [:]
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
        let pendings = (store[conversationId] ?? []).filter { $0.isMine && $0.pending && $0.media == nil }
        for p in pendings {
            do {
                let session = try await ensureOutboundSession(conversationId: conversationId, peerUserId: peerUserId)
                let wire = try session.encrypt(plaintext: Data(p.text.utf8))
                saveSessions(conversationId)
                let ciphertext = encodeWire(wire)
                let res: SendResponse = try await api.request(
                    "POST", "messages/send",
                    body: SendBody(conversation_id: conversationId, ciphertext: ciphertext,
                                   device_id: E2EManager.shared.deviceId))
                markSent(localId: p.id, conversationId: conversationId, serverId: res.message_id)
                NSLog("[VOIID] ✅ sent text id=\(res.message_id) conv=\(conversationId)")
            } catch {
                NSLog("[VOIID] ❌ sendText FAILED conv=\(conversationId): \(error)")
                // stays pending → retried later
            }
        }
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
        // 3. The E2EE message plaintext is a media envelope (key never leaves E2E).
        let envelope = MediaEnvelope(media: ref, caption: caption)
        let session = try await ensureOutboundSession(conversationId: conversationId, peerUserId: peerUserId)
        let wire = try session.encrypt(plaintext: try JSONEncoder().encode(envelope))
        saveSessions(conversationId)
        let ciphertext = encodeWire(wire)
        // 4. Send the message, tagging it as media + the opaque ref for the server.
        let res: SendResponse = try await api.request(
            "POST", "messages/send",
            body: SendBody(conversation_id: conversationId, ciphertext: ciphertext,
                           device_id: E2EManager.shared.deviceId,
                           content_type: "media", media_url: key, media_mime: mime))
        let echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                    text: caption, createdAt: parseDate(res.created_at),
                                    isMine: true, media: ref)
        append(echo, to: conversationId)
        return echo
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
        return try await runSyncLocked(conversationId: conversationId, peerUserId: peerUserId)
    }

    @discardableResult
    private func runSyncLocked(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        await flushPending(conversationId: conversationId, peerUserId: peerUserId)   // push any queued sends first
        lastSyncHadDecryptFailure = false
        let env: MessagesResponse = try await api.request("GET", "messages/conversation/\(conversationId)")
        NSLog("[VOIID] sync conv=\(conversationId): server has \(env.messages.count) msgs")
        let myId = TokenStore.shared.userId
        // "seen" = successfully-decrypted ids only. Tombstones (failed==true) are NOT
        // seen, so they're retried every sync — once the session heals they decrypt.
        let seen = Set((store[conversationId] ?? []).filter { !$0.failed }.map { $0.id })
        var newlyReceived: [String] = []
        for m in env.messages.reversed() where !seen.contains(m.id) {   // server DESC → process ASC
            if m.sender_id == myId { continue }   // our own echo is stored at send time
            guard let wire = decodeWire(m.ciphertext) else { continue }
            do {
                let plain = try await decryptInbound(wire, conversationId: conversationId,
                                                     peerUserId: peerUserId, senderDeviceId: m.sender_device_id)
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
    private func decryptInbound(_ wire: WireMessage, conversationId: String,
                               peerUserId: String, senderDeviceId: String?) async throws -> String {
        // 1. Try EVERY known session (glare → multiple). A non-matching session fails
        //    cleanly; the matching one decrypts (including later PreKey msgs of an
        //    already-accepted session — no re-accept, no extra OTK consumed).
        let list = candidateSessions(conversationId)
        for s in list {
            if let data = try? s.decrypt(message: wire) {
                saveSessions(conversationId)
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
            saveSessions(conversationId)
            return String(decoding: data, as: UTF8.self)
        }
        // 3. Accept a NEW inbound session and APPEND it (don't discard the others).
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let peer = try await peerIdentity(peerUserId, deviceId: senderDeviceId)
        try verifyAndPinIdentity(peer.key, peerUserId: peerUserId, deviceId: peer.deviceId)   // anti-MITM (TOFU, per device)
        let accepted = try id.acceptSession(theirIdentityKey: peer.key, firstMessage: wire)
        sessions[conversationId, default: []].append(accepted.session)
        saveSessions(conversationId)
        E2EManager.shared.persistIdentity()   // acceptSession consumed a one-time key —
                                              // save it or the first message is lost on restart.
        return String(decoding: accepted.plaintext, as: UTF8.self)
    }

    // MARK: - Session establishment

    private func ensureOutboundSession(conversationId: String, peerUserId: String) async throws -> Session {
        // Reuse a stable existing session for outbound; only create one if none exist.
        if let s = candidateSessions(conversationId).first { return s }
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let bundle = try await peerPrekeyBundle(peerUserId)
        try verifyAndPinIdentity(bundle.identityKey, peerUserId: peerUserId, deviceId: bundle.deviceId)   // anti-MITM (TOFU, per device)
        let s = try id.startSession(theirIdentityKey: bundle.identityKey, theirOneTimeKey: bundle.oneTimeKey)
        sessions[conversationId, default: []].append(s)
        saveSessions(conversationId)
        return s
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

    /// Peer's prekey bundle (identity + one consumed one-time key + device id) for startSession.
    private func peerPrekeyBundle(_ userId: String) async throws -> (identityKey: String, oneTimeKey: String, deviceId: String?) {
        let env: PrekeysResponse = try await api.request("GET", "prekeys/\(userId)")
        guard let b = env.bundles.first, let otk = b.one_time_prekey else {
            throw APIError.http(status: 409, message: "peer has no available prekeys")
        }
        return (b.identity_public_key, otk.public_key, b.device_id)
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

    private var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiid_messages.json")
    }

    private func loadStore() {
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

    /// Drop the cached + persisted session for a conversation so the NEXT outbound
    /// message starts a fresh one (peer asked us to reset / our session went stale).
    func resetSession(_ conversationId: String) {
        sessions[conversationId] = nil
        kc.delete("sess_\(conversationId)")
        NSLog("[VOIID] session reset for conv=\(conversationId)")
    }

    /// All candidate sessions for a conversation (loaded from the Keychain on first access).
    private func candidateSessions(_ conversationId: String) -> [Session] {
        if let s = sessions[conversationId] { return s }
        let restored = restoreSessions(conversationId)
        sessions[conversationId] = restored
        return restored
    }

    /// Restore the persisted session list (newline-separated pickles; back-compatible
    /// with the old single-pickle format).
    private func restoreSessions(_ conversationId: String) -> [Session] {
        guard let blob = kc.string("sess_\(conversationId)") else { return [] }
        return blob.split(separator: "\n").compactMap {
            try? Session.restore(pickle: String($0), pickleKey: sessionPickleKey())
        }
    }

    /// Persist all sessions for a conversation as newline-separated pickles.
    private func saveSessions(_ conversationId: String) {
        guard let list = sessions[conversationId] else { return }
        let blob = list.compactMap { try? $0.toPickle(pickleKey: sessionPickleKey()) }.joined(separator: "\n")
        kc.set(blob, "sess_\(conversationId)")
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
        guard let data = Data(base64Encoded: ciphertext),
              let p = try? JSONDecoder().decode(WirePayload.self, from: data) else { return nil }
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
    private struct SendBody: Encodable {
        let conversation_id: String
        let ciphertext: String
        var device_id: String? = nil      // which of OUR devices encrypted this
        var content_type: String? = nil
        var media_url: String? = nil
        var media_mime: String? = nil
    }
    private struct SendResponse: Decodable { let message_id: String; let created_at: String }
    private struct MessageDTO: Decodable {
        let id: String; let sender_id: String; let ciphertext: String; let created_at: String
        var sender_device_id: String? = nil   // which of the SENDER's devices encrypted it
        var content_type: String? = nil
    }
    private struct MessagesResponse: Decodable { let messages: [MessageDTO] }
}
