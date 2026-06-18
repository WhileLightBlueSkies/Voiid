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

import Foundation
import Security

/// A decrypted message ready for the UI.
struct DecryptedMessage {
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
    private var sessions: [String: Session] = [:]   // conversationId -> live Session
    private init() {}

    // MARK: - Public API

    /// Encrypt + send a text message in a direct conversation with `peerUserId`.
    func sendText(_ text: String, conversationId: String, peerUserId: String) async throws {
        let session = try await ensureOutboundSession(conversationId: conversationId, peerUserId: peerUserId)
        let wire = try session.encrypt(plaintext: Array(text.utf8))
        saveSession(session, conversationId: conversationId)
        let ciphertext = encodeWire(wire)
        let _: SendResponse = try await api.request(
            "POST", "messages/send",
            body: SendBody(conversation_id: conversationId, ciphertext: ciphertext))
    }

    /// Fetch + decrypt a conversation's messages (newest-first from server; returned oldest-first).
    func loadMessages(conversationId: String, peerUserId: String) async throws -> [DecryptedMessage] {
        let env: MessagesResponse = try await api.request("GET", "messages/conversation/\(conversationId)")
        let myId = TokenStore.shared.userId
        var out: [DecryptedMessage] = []
        for m in env.messages.reversed() {   // server returns DESC; show ASC
            let mine = (m.sender_id == myId)
            if mine {
                // We can't decrypt our own ratchet messages; the UI shows our plaintext
                // from the local echo at send time. Skip server copies of our own.
                continue
            }
            guard let wire = decodeWire(m.ciphertext) else { continue }
            do {
                let plain = try await decryptInbound(wire, conversationId: conversationId, peerUserId: peerUserId)
                out.append(DecryptedMessage(id: m.id, senderId: m.sender_id,
                                            text: plain, createdAt: parseDate(m.created_at), isMine: false))
            } catch { /* undecryptable (replay/old) — skip */ }
        }
        return out
    }

    /// Decrypt a single inbound message (used by the WS receive path).
    func decryptInbound(_ wire: WireMessage, conversationId: String, peerUserId: String) async throws -> String {
        if let s = sessions[conversationId] ?? restoreSession(conversationId) {
            sessions[conversationId] = s
            let data = try s.decrypt(message: wire)
            saveSession(s, conversationId: conversationId)
            return String(decoding: data, as: UTF8.self)
        }
        // No session yet → must be a PreKey message; accept it to create the session.
        guard let id = E2EManager.shared.identity else { throw APIError.notAuthenticated }
        let peerIdentityKey = try await peerIdentityKey(peerUserId)
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
        let s = try id.startSession(theirIdentityKey: bundle.identityKey, theirOneTimeKey: bundle.oneTimeKey)
        sessions[conversationId] = s
        saveSession(s, conversationId: conversationId)
        return s
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
