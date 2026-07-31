//
//  ContactPinService.swift
//  Voiid
//
//  The CONTACT PIN — how someone who found you by @username is allowed to message you
//  (see 020_reachability.sql and routes/reachability.ts).
//
//  Address-book discovery used to BE the gate: the only way to learn someone's user id was to
//  have their number. Username search removes that, so a 6-digit PIN takes its place — you
//  give it out of band ("my Voiid is @nehal, PIN 418302") and it lets that person open a
//  REQUEST, which you still have to accept.
//
//  IT IS NOT A PASSWORD and must never gate account access. Knowing it does exactly one thing:
//  permits a request. Two independent gates, so a leaked PIN alone is not enough.
//
//  THE PIN IS VIEWABLE. It is stored encrypted at rest (migration 026) rather than hashed,
//  so the owner can look it up whenever they need to share it. That is a deliberate trade:
//  a PIN you cannot re-read is one you must write down, and forgetting it forces a rotation
//  that locks out everyone already holding the old one.
//
//  It is NOT end-to-end encrypted — the server holds the key and can read it. What that
//  buys is that a stolen database dump alone yields ciphertext. Messages, calls and media
//  are E2E and unaffected.
//

import Foundation

@MainActor
// Not ObservableObject: nothing here is @Published. Callers own their own state and
// await these calls, so conformance would be inert weight.
final class ContactPinService {
    static let shared = ContactPinService()
    private init() {}

    private let api = APIClient()

    /// The caller's own PIN.
    struct PinState: Decodable {
        let has_pin: Bool
        /// The digits, in the clear. Nil with `has_pin` true means a PIN minted before
        /// migration 026, stored only as an unreversible hash — it still WORKS, it just
        /// can't be shown. Rotating replaces it with a viewable one.
        let pin: String?
        let set_at: String?
        /// False when the SERVER has no secretbox key, so no PIN can be stored viewably.
        /// Distinguishes "your PIN predates the feature" (rotating fixes it) from "this
        /// deployment can't store PINs readably" (rotating cannot).
        let storage_configured: Bool?
    }

    private struct RotateResponse: Decodable {
        let pin: String
        /// False when the server has no secretbox key, so this PIN won't be re-fetchable.
        /// The UI must then say "write it down" rather than promising it stays available.
        let viewable: Bool?
    }

    /// Fetch the current PIN. Owner-only server-side: the id comes from the auth token, so
    /// there is no parameter that could be pointed at someone else.
    func state() async throws -> PinState {
        try await api.request("GET", "reachability/contact-pin")
    }

    /// Mint a NEW PIN, replacing any existing one.
    ///
    /// This is a REVOCATION, not a way to recover a forgotten PIN — `state()` already
    /// returns the current one. It invalidates the old PIN immediately for everyone who had
    /// it, and clears the server's failed-attempt ledger so a sender previously locked out
    /// by throttling gets a fresh start against the NEW secret.
    ///
    /// Returns the PIN and whether it will be viewable afterwards.
    @discardableResult
    func rotate() async throws -> (pin: String, viewable: Bool) {
        let res: RotateResponse = try await api.request("POST", "reachability/contact-pin/rotate")
        return (res.pin, res.viewable ?? true)
    }

    // MARK: - Reaching someone by username

    /// A public profile resolved from a handle. Deliberately carries NO phone number: this
    /// endpoint is the boundary between Voiid's private and public identity planes, and a
    /// stranger who knows @nehal must not be able to reach a number.
    struct PublicProfile: Decodable {
        let user_id: String
        let username: String?
        let full_name: String?
        let photo_url: String?
        let bio: String?
        let is_mutual_contact: Bool
        /// True when a PIN is needed to message them. False for mutual contacts, who have
        /// already proved acquaintance by both having saved each other.
        let requires_pin: Bool
        /// False when the person has never set a PIN — they cannot be reached by handle at
        /// all, and the UI should say so rather than failing at send time.
        let reachable_by_username: Bool
    }

    private struct RequestResponse: Decodable {
        let conversation_id: String
        let existed: Bool
        let pending: Bool
    }

    func lookup(username: String) async throws -> PublicProfile {
        let encoded = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        return try await api.request("GET", "reachability/by-username?username=\(encoded)")
    }

    /// Open a chat by handle. `pin` may be nil for a mutual contact.
    ///
    /// Returns the conversation id and whether the recipient's side is still PENDING — the
    /// caller uses that to show "waiting to be accepted" rather than a normal chat.
    func requestChat(username: String, pin: String?) async throws -> (conversationId: String, pending: Bool) {
        struct Body: Encodable { let username: String; let pin: String? }
        let res: RequestResponse = try await api.request(
            "POST", "reachability/request", body: Body(username: username, pin: pin))
        return (res.conversation_id, res.pending)
    }

    // MARK: - Inbound requests

    struct PendingRequest: Decodable, Identifiable {
        let conversation_id: String
        let opened_via: String?
        let sender_id: String
        let username: String?
        let full_name: String?
        let photo_url: String?
        var id: String { conversation_id }
    }

    private struct PendingResponse: Decodable { let requests: [PendingRequest] }

    func pending() async throws -> [PendingRequest] {
        let res: PendingResponse = try await api.request("GET", "reachability/pending")
        return res.requests
    }

    func accept(conversationId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await api.request("POST", "reachability/\(conversationId)/accept")
    }

    /// Decline. The sender is NEVER told — if "declined" were distinguishable from "not opened
    /// yet", a request would become a presence oracle telling a stranger whether an account is
    /// live and attended.
    func decline(conversationId: String) async throws {
        struct Empty: Decodable {}
        let _: Empty = try await api.request("POST", "reachability/\(conversationId)/decline")
    }
}
