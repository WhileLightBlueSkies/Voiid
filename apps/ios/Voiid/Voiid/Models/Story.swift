//
//  Story.swift
//  Voiid
//
//  Stories domain models: the E2EE envelopes that cross the wire (inside the Double
//  Ratchet, so the server never sees them) and the local UI models rendered from
//  StoryStore. A story is the sendMedia flow with the recipient set widened from one
//  peer to a chosen audience — see docs/STORIES_PROTOCOL.md.
//
//  MediaRef is DELIBERATELY reused verbatim from ChatEngine.swift (do not redefine it):
//  the media key rides inside the envelope exactly as it does for a media message, so
//  it never leaves E2E.
//

import Foundation

// MARK: - Wire envelopes (authenticated plaintext, encrypted per target device)

/// The story key envelope (§1.3 step 5). This whole struct is the plaintext of a
/// Double-Ratchet message, so GCM authenticates every field. There is no AAD on any
/// AEAD in e2e-core, so story_id / author_id / expiry are bound HERE and the receiver
/// MUST validate them against the feed row before showing anything (§1.5).
struct StoryEnvelope: Codable {
    var v: Int = 1
    var t: String = "story"
    let story_id: String
    let author_id: String
    let created_at: Int64        // epoch ms
    let expires_at: Int64        // author's claim; server value wins for freshness
    let media: MediaRef          // the EXISTING MediaRef shape, verbatim
    var caption: String = ""
    var durationMs: Int?         // video only; drives the segment timer
    var width: Int?
    var height: Int?
    var allowsReplies: Bool = true
}

// StoryReplyEnvelope is defined in Networking/ChatEngine.swift, NOT here: ChatEngine.swift
// is compiled into the VoiidNSE extension target (which excludes this app-only model layer),
// and ChatEngine.decodeEnvelope decodes a story reply while the NSE decrypts an inbound push.
// Every wire type ChatEngine touches lives beside it for that reason.

/// A view receipt's ratchet plaintext (§4.3). The viewer identity lives INSIDE this
/// encrypted payload — the server never gets a viewer_user_id column.
struct StoryViewEnvelope: Codable {
    var v: Int = 1
    var t: String = "story_view"
    let story_id: String
    let viewer_id: String
    let viewed_at: Int64         // epoch ms
}

// MARK: - Local UI models

/// Download lifecycle for a story's plaintext blob. Mirrors the DB `download_state`.
enum StoryDownloadState: String {
    case none, downloading, ready, failed, gone
}

/// One story as the UI renders it, decoded from a `stories` row.
struct Story: Identifiable, Equatable {
    let id: String
    let authorId: String
    let authorDeviceId: String?
    let isMine: Bool
    let createdAt: Date
    let expiresAt: Date
    let media: MediaRef
    let caption: String
    let durationMs: Int?
    let width: Int?
    let height: Int?
    let allowsReplies: Bool
    var viewedAt: Date?
    var localPath: String?
    var downloadState: StoryDownloadState

    var isExpired: Bool { expiresAt <= Date() }
    var isViewed: Bool { viewedAt != nil }

    /// Segment duration for the viewer's timer (§8.4). Static images get 5s; video
    /// plays for its natural length capped at 30s.
    var segmentDuration: TimeInterval {
        if let ms = durationMs, ms > 0 { return min(Double(ms) / 1000.0, 30.0) }
        return 5.0
    }

    static func == (l: Story, r: Story) -> Bool { l.id == r.id && l.viewedAt == r.viewedAt && l.downloadState == r.downloadState && l.localPath == r.localPath }
}

/// An author's set of unexpired stories — one row/cell in the tray, never one per story.
struct StoryContext: Identifiable, Equatable {
    let authorId: String
    var stories: [Story]        // ascending by createdAt (viewer steps through in order)

    var id: String { authorId }
    var isMine: Bool { stories.first?.isMine ?? false }
    var newest: Story? { stories.max(by: { $0.createdAt < $1.createdAt }) }
    /// A context is "unviewed" if any of its stories is unseen — drives the accent ring.
    var hasUnviewed: Bool { stories.contains { !$0.isViewed } }
    /// Index of the first unseen story so the viewer opens where the user left off.
    var firstUnviewedIndex: Int { stories.firstIndex(where: { !$0.isViewed }) ?? 0 }

    static func == (l: StoryContext, r: StoryContext) -> Bool {
        l.authorId == r.authorId && l.stories == r.stories
    }
}
