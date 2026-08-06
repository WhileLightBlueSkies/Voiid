//
//  CommunityHostThread.swift
//  Voiid
//
//  The member → HOST private line. THE ONE SCOPED EXCEPTION TO 020_reachability.sql.
//  Mirrors Android `net/CommunityHostThreads.kt`; the two must agree, because the same
//  community has members on both platforms.
//
//  ── WHAT THIS CLIENT MAY ASK FOR, AND NOTHING ELSE ───────────────────────────────
//
//  020_reachability.sql defines exactly three ways to open a conversation: mutual contacts,
//  a one-way contact (as a request), and @username + the 6-digit PIN (as a request). This
//  adds a fourth, and it is member → COMMUNITY OWNER only.
//
//  Joining a space is consent to be ASKED QUESTIONS BY ITS MEMBERS. It is not consent to be
//  messaged by every other member. A 5,000-member community must never become 5,000 mutual
//  messaging rights; that is a spam amplifier with a friendly name.
//
//  ── MEMBER → MEMBER IS IMPOSSIBLE HERE, NOT MERELY UNIMPLEMENTED ─────────────────
//
//  Read `open(communityId:)`. Its only argument is a COMMUNITY ID. The peer is not a
//  parameter, because the peer is not the caller's to choose: the server reads it from
//  `communities.owner_id`, which 030_communities.sql makes the single authority on who the
//  host is, precisely so the lookup cannot return two rows or be pointed somewhere else.
//  Adding a `targetUserId` to this file would be the bug, and it would appear in the diff as
//  a new argument — which is why this surface is kept this small.
//
//  IF YOU EVER FIND CODE — HERE, IN A VIEW, OR ON THE SERVER — THAT READS COMMUNITY
//  MEMBERSHIP TO AUTHORISE A MESSAGE BETWEEN TWO ORDINARY MEMBERS, THAT IS A BUG. It is the
//  same rule CreatorService.swift states for follows: membership is a SOCIAL graph, and a
//  social graph quietly becoming a MESSAGING graph is the exact failure mode these gates
//  exist to prevent. Fix the caller; do not widen this.
//
//  ── ENCRYPTION: ZERO NEW CRYPTOGRAPHY ────────────────────────────────────────────
//
//  What the server returns is an ordinary `type='direct'` conversation on the Double Ratchet
//  ChatEngine already implements. Nothing in this file encrypts, decrypts or carries a
//  message; it only obtains the conversation id to send into. The server holds opaque
//  ciphertext here exactly as it does for every other 1:1.
//
//  ── DECODING (repair-plan item 3.24) ─────────────────────────────────────────────
//
//  EVERY FIELD ON EVERY RESPONSE TYPE BELOW IS OPTIONAL. Swift's Codable throws
//  `keyNotFound` on an ABSENT key — not nil, a thrown error that fails the whole decode — so
//  a build that ships ahead of the backend (this one does; see the mount note in
//  routes/communityHostThreads.ts) would turn a working screen into "unexpected server
//  response" over a field nobody reads. This is the mirror image of the Android hazard, where
//  kotlinx silently OMITS a default-valued field on the way out.
//

import Foundation

@MainActor
final class CommunityHostThreadService {
    static let shared = CommunityHostThreadService()
    private let api = APIClient()
    private init() {}

    // MARK: - Wire DTOs

    /// The result of opening (or re-opening) a line to a host.
    ///
    /// `opened_via` is `"community"` for a thread created by this exception and nil when the
    /// server handed back a 1:1 that already existed between these two people for ordinary
    /// reasons. Preserve that distinction in the UI: a personal chat that happens to be with a
    /// host is not a host thread, and re-labelling it would drag someone's private conversation
    /// into a Community inbox section and lie about how it started.
    struct HostThread: Decodable {
        var conversation_id: String?
        var host_user_id: String?
        /// false for a thread this call created, true when an existing one was returned.
        var existed: Bool?
        var opened_via: String?

        var isCommunityThread: Bool { opened_via == "community" }
    }

    /// One row of "my host threads, from both ends".
    ///
    /// IDS AND COMMUNITY CARD FIELDS ONLY. No last message, no preview, no member name: the
    /// messages are end-to-end encrypted and the server could not describe them if it wanted
    /// to. Everything else a chat row shows comes from the local decrypted store.
    struct HostThreadSummary: Decodable, Identifiable {
        var conversation_id: String?
        var community_id: String?
        var community_handle: String?
        var community_name: String?
        var community_avatar_r2_key: String?
        /// "host" when the caller owns the community, "member" when they opened the thread.
        var role: String?
        var member_user_id: String?
        var created_at: String?

        /// SwiftUI identity. The conversation id is unique server-side (it is the host-thread
        /// table's own unique key); the empty fallback only exists so a malformed row cannot
        /// crash a list, and such rows are filtered out before they get there.
        var id: String { conversation_id ?? "" }
        var amHost: Bool { role == "host" }
    }

    private struct ThreadsResp: Decodable { var threads: [HostThreadSummary]? }

    // MARK: - Calls

    /// Open the caller's private line to this community's host, or return the existing one.
    ///
    /// IDEMPOTENT, and safe to call from a button handler every time: the server reuses the
    /// recorded thread when one exists and throttles CREATIONS only, so re-entering a
    /// conversation you already have is free forever. A rate limit that locked you out of your
    /// own chat would be a self-inflicted outage, not a defence.
    ///
    /// Fails with 403 unless the caller is an ACTIVE member — pending applicants included,
    /// because letting an applicant message the owner would make an approval queue a
    /// formality. The 403 message is deliberately identical for "never joined", "pending",
    /// "left" and "banned": the server refuses to be an oracle for moderation state, so do not
    /// try to infer one from it.
    @discardableResult
    func open(communityId: String) async throws -> (conversationId: String, hostUserId: String, existed: Bool) {
        let res: HostThread = try await api.request("POST", "communities/\(communityId)/host-thread")
        guard let conversationId = res.conversation_id, !conversationId.isEmpty,
              let hostUserId = res.host_user_id, !hostUserId.isEmpty else {
            throw APIError.http(status: 502, message: "The server did not return a host conversation.")
        }
        return (conversationId, hostUserId, res.existed ?? false)
    }

    /// Does a line to this host already exist? Lets the info card show "Open chat" instead of
    /// "Message host" WITHOUT creating anything.
    ///
    /// A GET on purpose. A card that minted a conversation just by being LOOKED AT would make
    /// every impression an act of contact, and would hand the host a chat list full of people
    /// who only ever browsed. A nil `conversation_id` is the normal state, not an error.
    func existing(communityId: String) async throws -> HostThread {
        try await api.request("GET", "communities/\(communityId)/host-thread")
    }

    /// Every host thread the caller is on, from BOTH ends — the ones they opened as a member
    /// and the ones opened with them as the host.
    ///
    /// This is what lets the chat list group these into a Community section: `GET
    /// /conversations` does not return `opened_via`, so the grouping is keyed on
    /// conversation_id, which a chat row already has. Fetch once per list load and build a
    /// map; do not call this per row.
    func all() async throws -> [HostThreadSummary] {
        let res: ThreadsResp = try await api.request("GET", "community-host-threads")
        return (res.threads ?? []).filter { !($0.conversation_id ?? "").isEmpty }
    }

    /// "Ask host about this" — send a question about an announcement into the host thread.
    ///
    /// THE ENVELOPE IS THE EXISTING `MessageReplyEnvelope`. Nothing new is defined, nothing new
    /// has to be added to ChatEngine's `"t"` discriminator probe, and builds already in the
    /// field render it: a quoted text message is a shape both platforms have shipped since the
    /// message-actions work.
    ///
    /// WHY THE QUOTE STILL MAKES SENSE ACROSS TWO CONVERSATIONS. `quotedServerId` is the SERVER
    /// message id of the announcement, which lives in the community's announcement channel — a
    /// different conversation from the host thread this send lands in. It resolves for the host
    /// because both people are members of that channel, and it renders even when the original
    /// is gone, because `quotedPreview` travels inside the envelope. That preview is a snippet
    /// of the DECRYPTED announcement taken from the local store; the server never sees it in
    /// the clear, not in this send and not in the original.
    ///
    /// - Returns: the conversation id the question landed in, so the caller can navigate to it.
    @discardableResult
    func askHost(communityId: String,
                 text: String,
                 quotedServerId: String,
                 quotedPreview: String,
                 quotedSender: String) async throws -> String {
        let thread = try await open(communityId: communityId)
        _ = try await ChatEngine.shared.sendReply(text: text,
                                                  quotedId: quotedServerId,
                                                  quotedPreview: quotedPreview,
                                                  quotedSender: quotedSender,
                                                  conversationId: thread.conversationId,
                                                  peerUserId: thread.hostUserId)
        return thread.conversationId
    }
}
