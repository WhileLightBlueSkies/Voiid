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

/// A decrypted message ready for the UI (and the on-disk store record).
struct DecryptedMessage: Codable {
    let id: String
    let senderId: String
    let text: String
    let createdAt: Date
    let isMine: Bool
}

@MainActor
final class ChatEngine {
    static let shared = ChatEngine()
    private let api = APIClient()
    private let kc = KeychainData(service: "com.voiid.sessions")
    private let sessionPickleKeyName = "session_pickle_key"
    private var sessions: [String: Session] = [:]          // conversationId -> live Session
    private var store: [String: [DecryptedMessage]] = [:]   // conversationId -> messages (asc)
    private init() { loadStore() }

    // MARK: - Public API

    /// Locally-stored (already decrypted) messages for a conversation, oldest-first.
    func messages(conversationId: String) -> [DecryptedMessage] {
        (store[conversationId] ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    /// Encrypt + send a text message in a direct conversation with `peerUserId`.
    /// Returns the stored echo (so the UI can show it immediately).
    @discardableResult
    func sendText(_ text: String, conversationId: String, peerUserId: String) async throws -> DecryptedMessage {
        let session = try await ensureOutboundSession(conversationId: conversationId, peerUserId: peerUserId)
        let wire = try session.encrypt(plaintext: Array(text.utf8))
        saveSession(session, conversationId: conversationId)
        let ciphertext = encodeWire(wire)
        let res: SendResponse = try await api.request(
            "POST", "messages/send",
            body: SendBody(conversation_id: conversationId, ciphertext: ciphertext))
        let echo = DecryptedMessage(id: res.message_id, senderId: TokenStore.shared.userId ?? "me",
                                    text: text, createdAt: parseDate(res.created_at), isMine: true)
        append(echo, to: conversationId)
        return echo
    }

    /// Fetch the server's message list, decrypt ONLY ids we haven't seen, persist,
    /// and return the full conversation (oldest-first).
    @discardableResult
    func sync(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        let env: MessagesResponse = try await api.request("GET", "messages/conversation/\(conversationId)")
        let myId = TokenStore.shared.userId
        let seen = Set((store[conversationId] ?? []).map { $0.id })
        for m in env.messages.reversed() where !seen.contains(m.id) {   // server DESC → process ASC
            if m.sender_id == myId { continue }   // our own echo is stored at send time
            guard let wire = decodeWire(m.ciphertext) else { continue }
            do {
                let plain = try await decryptInbound(wire, conversationId: conversationId, peerUserId: peerUserId)
                append(DecryptedMessage(id: m.id, senderId: m.sender_id, text: plain,
                                        createdAt: parseDate(m.created_at), isMine: false),
                       to: conversationId, persist: false)
            } catch { /* undecryptable (replay/old) — skip */ }
        }
        persist()
        return messages(conversationId: conversationId)
    }

    /// Mark all locally-stored inbound messages in a conversation as read. The
    /// server fans out a `receipt` WS event to the original senders (blue ticks).
    func markRead(conversationId: String) async {
        let ids = (store[conversationId] ?? []).filter { !$0.isMine }.map { $0.id }
        guard !ids.isEmpty else { return }
        struct Body: Encodable { let message_ids: [String]; let status = "read" }
        _ = try? await api.request("POST", "receipts/mark", body: Body(message_ids: ids)) as EmptyResponse
    }

    /// Decrypt a single inbound message and advance the session. Caller persists.
    private func decryptInbound(_ wire: WireMessage, conversationId: String, peerUserId: String) async throws -> String {
        if let s = sessions[conversationId] ?? restoreSession(conversationId) {
            sessions[conversationId] = s
            let data = try s.decrypt(message: wire)
            saveSession(s, conversationId: conversationId)
            return String(decoding: data, as: UTF8.self)
        }
        // No session yet → must be a PreKey message; accept it to create the session.
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let peerIdentityKey = try await peerIdentityKey(peerUserId)
        try verifyAndPinIdentity(peerIdentityKey, peerUserId: peerUserId)   // anti-MITM (TOFU)
        let accepted = try id.acceptSession(theirIdentityKey: peerIdentityKey, firstMessage: wire)
        sessions[conversationId] = accepted.session
        saveSession(accepted.session, conversationId: conversationId)
        return String(decoding: accepted.plaintext, as: UTF8.self)
    }

    // MARK: - Session establishment

    private func ensureOutboundSession(conversationId: String, peerUserId: String) async throws -> Session {
        if let s = sessions[conversationId] ?? restoreSession(conversationId) {
            sessions[conversationId] = s
            return s
        }
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let bundle = try await peerPrekeyBundle(peerUserId)
        try verifyAndPinIdentity(bundle.identityKey, peerUserId: peerUserId)   // anti-MITM (TOFU)
        let s = try id.startSession(theirIdentityKey: bundle.identityKey, theirOneTimeKey: bundle.oneTimeKey)
        sessions[conversationId] = s
        saveSession(s, conversationId: conversationId)
        return s
    }

    // MARK: - Identity pinning (anti-MITM / "safety numbers", trust-on-first-use)

    /// On first contact we PIN the peer's identity public key. On every later use we
    /// require it to match — a changed key means a possible server-side key-swap
    /// (MITM) and we refuse rather than silently re-keying. This is the core
    /// protection that makes the E2EE meaningful against a hostile server.
    private func verifyAndPinIdentity(_ identityKey: String, peerUserId: String) throws {
        let pinName = "idpin_\(peerUserId)"
        if let pinned = kc.string(pinName) {
            guard pinned == identityKey else {
                throw APIError.http(status: 495, message: "peer identity key changed — possible MITM; verify safety number before continuing")
            }
        } else {
            kc.set(identityKey, pinName)
        }
    }

    // MARK: - Peer key resolution

    private struct DeviceDTO: Decodable { let identity_public_key: String }
    private struct DevicesResponse: Decodable { let devices: [DeviceDTO] }
    private struct BundleDTO: Decodable {
        let identity_public_key: String
        let one_time_prekey: OTKDTO?
    }
    private struct OTKDTO: Decodable { let public_key: String }
    private struct PrekeysResponse: Decodable { let bundles: [BundleDTO] }

    /// Peer's identity public key (for acceptSession) — from their device record.
    private func peerIdentityKey(_ userId: String) async throws -> String {
        let env: DevicesResponse = try await api.request("GET", "devices/\(userId)")
        guard let d = env.devices.first else { throw APIError.http(status: 404, message: "peer has no device") }
        return d.identity_public_key
    }

    /// Peer's prekey bundle (identity + one consumed one-time key) for startSession.
    private func peerPrekeyBundle(_ userId: String) async throws -> (identityKey: String, oneTimeKey: String) {
        let env: PrekeysResponse = try await api.request("GET", "prekeys/\(userId)")
        guard let b = env.bundles.first, let otk = b.one_time_prekey else {
            throw APIError.http(status: 409, message: "peer has no available prekeys")
        }
        return (b.identity_public_key, otk.public_key)
    }

    // MARK: - Local message store (decrypt-once; plaintext at rest, file-protected)

    private func append(_ m: DecryptedMessage, to convId: String, persist doPersist: Bool = true) {
        var arr = store[convId] ?? []
        guard !arr.contains(where: { $0.id == m.id }) else { return }
        arr.append(m)
        store[convId] = arr
        if doPersist { persist() }
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

    private func restoreSession(_ conversationId: String) -> Session? {
        guard let pickle = kc.string("sess_\(conversationId)") else { return nil }
        return try? Session.restore(pickle: pickle, pickleKey: sessionPickleKey())
    }
    private func saveSession(_ s: Session, conversationId: String) {
        if let pickle = try? s.toPickle(pickleKey: sessionPickleKey()) {
            kc.set(pickle, "sess_\(conversationId)")
        }
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

    // DTOs for messages API
    private struct SendBody: Encodable { let conversation_id: String; let ciphertext: String }
    private struct SendResponse: Decodable { let message_id: String; let created_at: String }
    private struct MessageDTO: Decodable { let id: String; let sender_id: String; let ciphertext: String; let created_at: String }
    private struct MessagesResponse: Decodable { let messages: [MessageDTO] }
}
