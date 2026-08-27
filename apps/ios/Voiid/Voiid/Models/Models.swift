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
    /// Remote avatar (R2 URL). Distinct from `photoName`, which is a bundled asset.
    var photoURL: String?
    /// Clips handle (@username). Fetched from the server profile.
    var username: String?
    var bio: String?
    var statusText: String?
    var isOnline: Bool = false
}

enum MessageStatus: String { case sending, sent, delivered, read, failed }
enum MessageKind: String { case text, image, voice, document, system, poll, location, call }

/// A finished call, rendered as a bubble in the transcript (WhatsApp/Signal style).
///
/// NOT a message and never sent over the wire. Both endpoints already learn the outcome from
/// the signaling they exchanged, so each side renders this from its OWN local `call_history`
/// row — exactly how Signal and WhatsApp do it. Sending a log message instead would add a
/// failure mode (caller dies mid-call → no log for anyone) and a second source of truth for
/// something both sides already know.
struct VCallLog: Hashable {
    let callId: String
    var isVideo: Bool
    var incoming: Bool
    /// answered | missed | declined | failed — the vocabulary written by CallService.
    var outcome: String
    var startedAt: Date
    var endedAt: Date?

    var answered: Bool { outcome == "answered" }
    /// Seconds of connected time; nil unless the call was actually answered.
    var durationSeconds: Int? {
        guard answered, let endedAt else { return nil }
        return max(0, Int(endedAt.timeIntervalSince(startedAt)))
    }
}

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
    /// Quoted MOMENT: a reply sent from the Stories viewer quotes the story it answers,
    /// the sibling of `replyToText` above and rendered by the same bubble in the same
    /// place. Only the identity travels — the media is looked up in StoryStore at render
    /// time, because a story is a 24h object and a snapshot of it would be a lie within a
    /// day. `storyQuoteAt` is the moment's own creation time, not the reply's.
    var storyQuoteId: String? = nil
    var storyQuoteAuthorId: String? = nil
    var storyQuoteAt: Date? = nil
    /// True when this bubble's whole body is a single emoji reaction tapped on the story
    /// rail, rather than typed prose. It is drawn large and unbubbled, the way a reaction
    /// reads everywhere else — a 30pt "❤️" set in body type looks like a typo.
    var isStoryReaction: Bool = false
    /// For media messages (.image/.voice): the E2EE reference used to fetch +
    /// decrypt the blob on demand. nil for text/local-echo messages.
    var mediaRef: MediaRef? = nil
    /// For location messages (kind == .location): the pin / live-share reference used to
    /// render the map bubble. nil for every other kind. Never holds the shareKey.
    var location: LocationRef? = nil
    /// Set when kind == .call: the finished call this bubble reports. Local-only.
    var call: VCallLog? = nil

    /// True when `s` is one to three emoji and nothing else — the shape of a tapped
    /// reaction rather than a typed sentence. Grapheme-based, not scalar-based: "👏🏽" and
    /// "❤️" are each ONE Character but several scalars, so counting scalars would reject
    /// the exact emoji the story rail sends.
    static func isSoloEmoji(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 3 else { return false }
        return t.allSatisfy { ch in
            ch.unicodeScalars.contains { $0.properties.isEmoji && $0.properties.isEmojiPresentation }
                || ch.unicodeScalars.contains { $0.properties.isEmojiModifierBase }
        }
    }

    /// Stable per-sender accent color for group sender names (WhatsApp-style).
    var senderColor: Color {
        let palette: [UInt] = [0xC0556B, 0x3E9E6E, 0x4D7EA8, 0xD8A24A, 0x8E5BA6, 0xBA6B3D, 0x2A9D8F]
        let idx = abs(senderId.hashValue) % palette.count
        return Color(hex: palette[idx])
    }
}

/// `self` is Note to Self — your own private scratchpad. One member (you), its own type so
/// it can never satisfy the "exactly two members" lookup that identifies a real 1:1.
enum ConversationType: String { case direct, group, `self` }

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
    /// For direct chats: peer's last-seen time (from presence), nil if unknown/online.
    var lastSeenAt: Date? = nil
}

// VClip / VClipComment removed — the mock shapes for the dummy Clips feed. The real
// models are `Clip` and `ClipComment` in Networking/ClipsEngine.swift, built from the
// server rows in ClipService.

// VAIMessage REMOVED — superseded by `AIMessage` in Main/AI/AIModels.swift, which carries
// an author enum, a timestamp, streaming state and a failure reason.
