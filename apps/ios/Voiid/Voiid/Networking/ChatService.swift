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

// /conversations/:id detail (members) — used to resolve the peer of a direct chat.
private struct ConvDetailEnvelope: Decodable { let conversation: ConvDetailDTO; let members: [MemberDTO] }
private struct ConvDetailDTO: Decodable { let id: String; let type: String; let name: String? }
private struct MemberDTO: Decodable { let user_id: String; let full_name: String?; let photo_url: String? }

// /conversations/create response.
private struct CreateConvEnvelope: Decodable { let conversation: CreatedConvDTO }
private struct CreatedConvDTO: Decodable { let id: String; let type: String; let name: String? }

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
        return env.conversation.id
    }

    /// Peer presence (online + last_seen epoch millis) from Redis-backed status.
    func status(userId: String) async throws -> (online: Bool, lastSeen: Date?) {
        struct StatusDTO: Decodable { let online: Bool; let last_seen: Double? }
        let env: StatusDTO = try await api.request("GET", "users/status/\(userId)")
        let last = env.last_seen.map { Date(timeIntervalSince1970: $0 / 1000) }
        return (env.online, last)
    }
}
