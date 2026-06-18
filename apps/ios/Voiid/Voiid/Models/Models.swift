//
//  Models.swift
//  Voiid
//
//  App models. For the dummy frontend phase these are populated with sample data
//  (DummyData.swift). Later they're hydrated from the backend via APIClient + decrypted
//  locally via the crypto seam. UI always reads these models, never the network directly
//  (local-first, Master Spec Section 11).
//

import Foundation
import SwiftUI

struct VUser: Identifiable, Hashable {
    let id: String
    var fullName: String
    var phoneNumber: String
    var email: String?
    var photoName: String?       // local asset name for dummy phase
    var bio: String?
    var statusText: String?
    var isOnline: Bool = false
}

enum MessageStatus: String { case sending, sent, delivered, read, failed }
enum MessageKind: String { case text, image, voice, document, system, poll }

struct VMessage: Identifiable, Hashable {
    let id: String
    var conversationId: String
    var senderId: String
    var senderName: String = ""      // shown above incoming group bubbles
    var kind: MessageKind = .text
    /// Decrypted text for display. On the wire this is opaque ciphertext (crypto seam).
    var text: String
    var createdAt: Date
    var status: MessageStatus = .sent
    var isMine: Bool = false
    var poll: VPoll? = nil          // set when kind == .poll
    var reaction: String? = nil     // single emoji reaction on this message
    var deliveredAt: Date? = nil    // for Message Info
    var readAt: Date? = nil         // for Message Info
    var forwarded: Bool = false     // "Forwarded" tag
    var deletedForEveryone: Bool = false  // tombstone: "This message was deleted"
    // Quoted reply: snapshot of the replied-to message
    var replyToSender: String? = nil
    var replyToText: String? = nil

    /// Stable per-sender accent color for group sender names (WhatsApp-style).
    var senderColor: Color {
        let palette: [UInt] = [0xC0556B, 0x3E9E6E, 0x4D7EA8, 0xD8A24A, 0x8E5BA6, 0xBA6B3D, 0x2A9D8F]
        let idx = abs(senderId.hashValue) % palette.count
        return Color(hex: palette[idx])
    }
}

enum ConversationType: String { case direct, group }

struct VConversation: Identifiable, Hashable {
    let id: String
    var type: ConversationType
    var title: String
    var photoName: String?
    var lastMessagePreview: String?
    var lastMessageAt: Date?
    var unreadCount: Int = 0
    var memberCount: Int = 2
    var isOnline: Bool = false
    /// For direct chats: the peer's user_id. Needed to establish the E2E session.
    /// Resolved lazily from /conversations/:id members (nil until resolved).
    var peerUserId: String? = nil
    /// For direct chats: avatar URL of the peer (from members), used by the UI.
    var photoURL: String? = nil
}

struct VClip: Identifiable, Hashable {
    let id: String
    var authorName: String
    var authorPhoto: String?
    var heading: String
    var caption: String
    var likes: Int
    var comments: Int
    var thumbnailName: String?
}

struct VClipComment: Identifiable, Hashable {
    let id: String
    var authorName: String
    var authorPhoto: String?
    var text: String
}

struct VAIMessage: Identifiable, Hashable {
    let id: String
    var text: String
    var isUser: Bool
}
