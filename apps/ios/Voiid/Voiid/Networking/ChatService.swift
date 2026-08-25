//
//  ChatService.swift
//  Voiid
//
//  Real conversation data from the backend (replaces DummyData for the chat
//  list). Message *content* is E2EE — the server only stores ciphertext, so the
//  last-message preview is shown as "Encrypted" until the message layer (which
//  decrypts via e2e-core) is wired. Direct-chat titles need contact resolution,
//  which arrives with the contacts feature; until then we fall back gracefully.
//

import Foundation

private struct ConversationsEnvelope: Decodable { let conversations: [ConvDTO] }
private struct ConvDTO: Decodable {
    let id: String
    let type: String
    let name: String?
    let photo_url: String?
    let last_message_at: String?
    let last_ciphertext: String?
    let unread_count: Int?
}

// /conversations/:id detail (members) — used to resolve the peer of a direct chat
// and to populate group info (member list + roles).
private struct ConvDetailEnvelope: Decodable { let conversation: ConvDetailDTO; let members: [MemberDTO] }
private struct ConvDetailDTO: Decodable { let id: String; let type: String; let name: String? }
private struct MemberDTO: Decodable {
    let user_id: String
    let full_name: String?
    let photo_url: String?
    let role: String?
}

// /conversations/create response — the backend returns a FLAT body:
//   direct: { conversation_id, existed }   group: { conversation_id }
private struct CreateConvEnvelope: Decodable { let conversation_id: String; let existed: Bool? }

/// A resolved member of a (group) conversation.
struct ConvMember {
    let userId: String
    let name: String?
    let photoURL: String?
    /// The real role, not a boolean. `isAdmin` could not express an owner, so the owner badge
    /// had nothing to render from and ownership transfer had no state to read.
    let role: MemberRole
    var isAdmin: Bool { role == .admin || role == .owner }
}

/// A user's public profile (no phone number — not exposed by the backend).
struct UserProfile {
    let name: String?
    let photoURL: String?
    let about: String?
    /// The one-line status, DISTINCT from `about`. These were being collapsed into a single
    /// field (`bio ?? status_text`), so whichever the user had set showed up as their About
    /// and the other was silently discarded — a user with a status but no bio appeared to
    /// have written a bio, and one with both lost the status entirely.
    let statusText: String?
    let username: String?
    /// Only ever populated for the OWN profile (the server returns it only to the owner).
    let phoneNumber: String?
}

@MainActor
final class ChatService {
    static let shared = ChatService()
    private let api = APIClient()
    private init() {}

    /// Fetch the user's real conversations. Empty for a brand-new account —
    /// that empty state is the signal that the list is reading the live backend.
    /// Direct chats are then enriched (peer user_id + name + photo) concurrently
    /// from /conversations/:id so the list shows the contact, not "Direct chat".
    func fetchConversations() async throws -> [VConversation] {
        let env: ConversationsEnvelope = try await api.request("GET", "conversations")
        let iso = ISO8601DateFormatter()
        var convs = env.conversations.map { c in
            VConversation(
                id: c.id,
                // Explicit mapping. `?? .direct` would silently turn a self-chat into a
                // direct one, and the peer-resolution pass below would then hunt for a
                // second member that does not exist.
                type: ConversationType(rawValue: c.type) ?? .direct,
                title: c.type == "self" ? "Note to Self" : (c.name ?? "Direct chat"),
                photoName: nil,
                lastMessagePreview: c.last_ciphertext == nil ? nil : "Encrypted message",
                lastMessageAt: c.last_message_at.flatMap { iso.date(from: $0) },
                unreadCount: c.unread_count ?? 0
            )
        }
        // Resolve peers for direct chats concurrently.
        await withTaskGroup(of: (Int, (peerUserId: String?, title: String?, photoURL: String?)).self) { group in
            for (i, c) in convs.enumerated() where c.type == .direct {
                group.addTask { [weak self] in
                    guard let self, let peer = try? await self.resolvePeer(conversationId: c.id) else {
                        return (i, (nil, nil, nil))
                    }
                    return (i, peer)
                }
            }
            for await (i, peer) in group {
                guard convs.indices.contains(i) else { continue }
                convs[i].peerUserId = peer.peerUserId
                convs[i].photoURL = peer.photoURL
                if let t = peer.title, !t.isEmpty { convs[i].title = t }
            }
        }
        return convs
    }

    /// Resolve a direct conversation's peer (the other member) → user_id + name + photo.
    func resolvePeer(conversationId: String) async throws -> (peerUserId: String?, title: String?, photoURL: String?) {
        let env: ConvDetailEnvelope = try await api.request("GET", "conversations/\(conversationId)")
        let myId = TokenStore.shared.userId
        guard let peer = env.members.first(where: { $0.user_id != myId }) else {
            return (nil, env.conversation.name, nil)
        }
        return (peer.user_id, peer.full_name ?? env.conversation.name, peer.photo_url)
    }

    /// Create (or fetch existing) a 1:1 conversation with `memberId` (peer user_id).
    /// Returns the conversation id.
    func createDirect(memberId: String) async throws -> String {
        struct Body: Encodable { let type = "direct"; let member_id: String }
        let env: CreateConvEnvelope = try await api.request("POST", "conversations/create", body: Body(member_id: memberId))
        return env.conversation_id
    }

    /// Create (or fetch) the caller's Note to Self. Idempotent server-side — there is
    /// exactly one per user, ever — so this is safe to call on every launch.
    func createSelfChat() async throws -> String {
        struct Body: Encodable { let type = "self" }
        let env: CreateConvEnvelope = try await api.request("POST", "conversations/create", body: Body())
        return env.conversation_id
    }

    /// Create a group conversation with `name` and the given member user_ids
    /// (the creator is added + made admin server-side). Returns the conversation id.
    func createGroup(name: String, memberIds: [String]) async throws -> String {
        struct Body: Encodable { let type = "group"; let name: String; let member_ids: [String] }
        let env: CreateConvEnvelope = try await api.request(
            "POST", "conversations/create", body: Body(name: name, member_ids: memberIds))
        return env.conversation_id
    }

    /// Active members of a conversation (used by group info). Caller must be a member.
    func members(conversationId: String) async throws -> [ConvMember] {
        let env: ConvDetailEnvelope = try await api.request("GET", "conversations/\(conversationId)")
        return env.members.map {
            ConvMember(userId: $0.user_id, name: $0.full_name,
                       photoURL: $0.photo_url, role: MemberRole.from($0.role))
        }
    }

    /// Promote a member to admin, or demote one back.
    ///
    /// The server owns the policy — an admin may promote, but only the OWNER may dismiss an
    /// admin — so a refusal comes back as an error with a readable message rather than this
    /// method trying to second-guess who is allowed to do what.
    func setMemberRole(conversationId: String, userId: String, role: String) async throws {
        struct Body: Encodable { let role: String }
        _ = try await api.request("PATCH",
            "conversations/\(conversationId)/members/\(userId)/role",
            body: Body(role: role)) as EmptyResponse
    }

    /// Hand the group to someone else. Owner-only; the server demotes and promotes in one
    /// transaction so the group is never briefly ownerless.
    func transferOwnership(conversationId: String, userId: String) async throws {
        struct Body: Encodable { let user_id: String }
        _ = try await api.request("POST",
            "conversations/\(conversationId)/transfer-ownership",
            body: Body(user_id: userId)) as EmptyResponse
    }

    /// Public profile for a user (name, photo, bio/about). The backend does NOT
    /// expose phone numbers here by design (privacy), so the profile screen shows
    /// name + about, not a number.
    func userProfile(userId: String) async throws -> UserProfile {
        struct Envelope: Decodable { let user: ProfileDTO }
        struct ProfileDTO: Decodable {
            let full_name: String?
            let photo_url: String?
            let bio: String?
            let status_text: String?
            let username: String?
            let phone_number: String?
        }
        let env: Envelope = try await api.request("GET", "users/\(userId)")
        return UserProfile(name: env.user.full_name, photoURL: env.user.photo_url,
                           about: env.user.bio, statusText: env.user.status_text,
                           username: env.user.username,
                           phoneNumber: env.user.phone_number)
    }

    /// Peer presence (online + last_seen epoch millis) from Redis-backed status.
    func status(userId: String) async throws -> (online: Bool, lastSeen: Date?) {
        struct StatusDTO: Decodable { let online: Bool; let last_seen: Double? }
        let env: StatusDTO = try await api.request("GET", "users/status/\(userId)")
        let last = env.last_seen.map { Date(timeIntervalSince1970: $0 / 1000) }
        return (env.online, last)
    }

    /// Presence for MANY users in ONE round trip — POST /users/presence.
    ///
    /// WHY NOT JUST LOOP `status(userId:)`: a screen that wants presence for everyone in a
    /// roster would open one connection per person, on a mobile link, on a repeating poll.
    /// The batch route answers the whole set at once and applies the IDENTICAL privacy gate
    /// per user — a person whose `last_seen_privacy` hides them comes back `online: false`
    /// here exactly as they do from the single route, so this is a cheaper way to ask the
    /// same question and never a way to learn more.
    ///
    /// The server caps the list (currently 64) and REJECTS an over-long one rather than
    /// truncating it, so callers chunk rather than hope. Returns a map keyed by user id;
    /// an id the server did not answer for is simply absent, and absent is NOT "offline" —
    /// the caller must not conflate the two.
    func presence(userIds: [String]) async throws -> [String: (online: Bool, lastSeen: Date?)] {
        struct Envelope: Decodable { let presence: [Row] }
        struct Row: Decodable { let user_id: String; let online: Bool; let last_seen: Double? }
        guard !userIds.isEmpty else { return [:] }
        var out: [String: (online: Bool, lastSeen: Date?)] = [:]
        // Chunked to the server's cap. A roster larger than one chunk is rare, but a rejected
        // request would blank the whole section, and that is a worse failure than two calls.
        for chunk in stride(from: 0, to: userIds.count, by: 64).map({
            Array(userIds[$0..<min($0 + 64, userIds.count)])
        }) {
            let env: Envelope = try await api.request("POST", "users/presence",
                                                      body: ["user_ids": chunk])
            for row in env.presence {
                out[row.user_id] = (row.online, row.last_seen.map { Date(timeIntervalSince1970: $0 / 1000) })
            }
        }
        return out
    }
}
