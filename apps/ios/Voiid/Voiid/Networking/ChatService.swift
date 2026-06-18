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

@MainActor
final class ChatService {
    static let shared = ChatService()
    private let api = APIClient()
    private init() {}

    /// Fetch the user's real conversations. Empty for a brand-new account —
    /// that empty state is the signal that the list is reading the live backend.
    func fetchConversations() async throws -> [VConversation] {
        let env: ConversationsEnvelope = try await api.request("GET", "conversations")
        let iso = ISO8601DateFormatter()
        return env.conversations.map { c in
            VConversation(
                id: c.id,
                type: c.type == "group" ? .group : .direct,
                title: c.name ?? "Direct chat",   // TODO: resolve from contact (contacts feature)
                photoName: nil,
                lastMessagePreview: c.last_ciphertext == nil ? nil : "Encrypted message",
                lastMessageAt: c.last_message_at.flatMap { iso.date(from: $0) },
                unreadCount: c.unread_count ?? 0
            )
        }
    }
}
