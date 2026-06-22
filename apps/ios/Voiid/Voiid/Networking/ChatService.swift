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
    let isAdmin: Bool
}

/// A user's public profile (no phone number — not exposed by the backend).
struct UserProfile {
    let name: String?
    let photoURL: String?
    let about: String?
    let username: String?
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
                type: c.type == "group" ? .group : .direct,
                title: c.name ?? "Direct chat",
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
                       photoURL: $0.photo_url, isAdmin: ($0.role ?? "member") == "admin")
        }
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
        }
        let env: Envelope = try await api.request("GET", "users/\(userId)")
        return UserProfile(name: env.user.full_name, photoURL: env.user.photo_url,
                           about: env.user.bio ?? env.user.status_text, username: env.user.username)
    }

    /// Peer presence (online + last_seen epoch millis) from Redis-backed status.
    func status(userId: String) async throws -> (online: Bool, lastSeen: Date?) {
        struct StatusDTO: Decodable { let online: Bool; let last_seen: Double? }
        let env: StatusDTO = try await api.request("GET", "users/status/\(userId)")
        let last = env.last_seen.map { Date(timeIntervalSince1970: $0 / 1000) }
        return (env.online, last)
    }
}
