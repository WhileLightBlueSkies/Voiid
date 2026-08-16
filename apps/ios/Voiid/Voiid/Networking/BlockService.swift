//
//  BlockService.swift
//  Voiid
//
//  The client half of user blocking (043_user_blocks.sql, backend/api/src/routes/blocks.ts).
//
//  Until this file existed the Block button raised "Blocking isn't available yet" beneath a
//  dialog promising "They won't be able to message or call you." The backend now enforces
//  that promise across messages, calls, profile, presence, conversation creation, group
//  invitations, stories and typing indicators; this is what lets a person actually press it.
//
//  BLOCKING IS SYMMETRIC ON THE SERVER, AND THAT MATTERS HERE
//  ----------------------------------------------------------
//  A block stops traffic in BOTH directions — the person who blocked can no longer message
//  the person they blocked either. The UI has to say so, because a user who expects Block
//  to be a one-way mute will read their own failed sends as a bug. See the footer copy in
//  BlockedContactsView and the confirmation dialog in ContactProfileView.
//
//  WHAT THIS DELIBERATELY CANNOT ANSWER
//  ------------------------------------
//  "Has someone blocked ME." There is no route for it and there must never be: the whole
//  point of blocking silently is that the blocked party cannot distinguish a block from a
//  dead phone. `isBlocked(_:)` answers only about the CALLER's own outgoing blocks, which
//  is what the Block/Unblock button needs to render itself.
//
//  WHY THE LIST IS CACHED
//  ----------------------
//  ContactProfileView needs to know, on open, whether to draw "Block" or "Unblock". Asking
//  the server on every profile open would put a spinner on a button that is usually "Block",
//  so the list is fetched once and kept. It is refreshed after every mutation, and on
//  demand by the settings screen.
//

import Foundation
import Combine

// MARK: - Wire model

/// One blocked user, as GET /blocks returns them.
///
/// Every field except `id` is optional. A blocked account may have no username, no display
/// name and no photo, and Swift's Codable throws `keyNotFound` on an absent key rather than
/// yielding nil — so a stricter model would fail the whole decode and leave the settings
/// screen empty for a user who has blocked exactly one person with no avatar.
struct BlockedUser: Decodable, Identifiable, Hashable {
    let id: String
    let username: String?
    let full_name: String?
    let photo_url: String?
    let blocked_at: String?

    /// What to show in a row. Falls back through the fields the server may not have.
    var displayName: String {
        if let n = full_name, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
        if let u = username, !u.isEmpty { return "@\(u)" }
        return "Unknown user"
    }
}

private struct BlockedListEnvelope: Decodable { let blocked: [BlockedUser]? }

// MARK: - Service

@MainActor
final class BlockService: ObservableObject {

    static let shared = BlockService()
    private let api = APIClient()
    private init() {}

    /// The caller's own outgoing blocks, newest first. Empty until first fetch.
    @Published private(set) var blocked: [BlockedUser] = []

    /// True once a fetch has completed, so the UI can tell "no blocks" from "not loaded".
    /// Without this an empty list renders the same either way, and the settings screen
    /// would claim "You haven't blocked anyone" while the request was still in flight.
    @Published private(set) var didLoad = false

    /// Ids being mutated right now, so a row can disable its own button without freezing
    /// the whole list. Keyed by user id because two rows can be in flight at once.
    @Published private(set) var pending: Set<String> = []

    // MARK: Queries

    /// Has the CALLER blocked this user? Answers from cache — see the header note on why
    /// this cannot and must not answer the reverse question.
    func isBlocked(_ userId: String) -> Bool {
        blocked.contains { $0.id == userId }
    }

    /// Refresh the list. Never throws: a failed refresh must not break a settings screen or
    /// a profile view, and the previously-known list stays on screen rather than blanking.
    func refresh() async {
        guard TokenStore.shared.jwt != nil else {
            blocked = []
            didLoad = false
            return
        }
        do {
            let env: BlockedListEnvelope = try await api.request("GET", "blocks")
            blocked = env.blocked ?? []
            didLoad = true
        } catch {
            // Keep whatever we had. Rendering "you have blocked nobody" because the network
            // hiccuped would invite someone to re-block a person who is already blocked.
        }
    }

    /// Load once per session unless a refresh is explicitly asked for.
    func loadIfNeeded() async {
        guard !didLoad else { return }
        await refresh()
    }

    // MARK: Mutations

    /// Block a user. Idempotent on the server, so pressing twice is harmless.
    ///
    /// Optimistic: the row is inserted locally before the request lands, because the
    /// confirmation dialog has already closed and a button that stays "Block" for a second
    /// afterwards reads as a failure. Rolled back if the request fails.
    @discardableResult
    func block(userId: String, displayName: String? = nil, username: String? = nil,
               photoURL: String? = nil) async -> Bool {
        guard !pending.contains(userId) else { return false }
        pending.insert(userId)
        defer { pending.remove(userId) }

        let optimistic = BlockedUser(id: userId, username: username, full_name: displayName,
                                     photo_url: photoURL, blocked_at: nil)
        let hadIt = isBlocked(userId)
        if !hadIt { blocked.insert(optimistic, at: 0) }

        do {
            struct Body: Encodable { let user_id: String }
            _ = try await api.request("POST", "blocks", body: Body(user_id: userId)) as EmptyResponse
            // Re-fetch so the row carries the server's blocked_at and canonical profile
            // fields rather than the placeholder above.
            await refresh()
            return true
        } catch {
            if !hadIt { blocked.removeAll { $0.id == userId } }
            return false
        }
    }

    /// Unblock a user. Also idempotent server-side.
    @discardableResult
    func unblock(userId: String) async -> Bool {
        guard !pending.contains(userId) else { return false }
        pending.insert(userId)
        defer { pending.remove(userId) }

        let removed = blocked.first { $0.id == userId }
        blocked.removeAll { $0.id == userId }

        do {
            _ = try await api.request("DELETE", "blocks/\(userId)") as EmptyResponse
            return true
        } catch {
            // Put it back — showing someone as unblocked when the server still blocks them
            // is the more dangerous of the two wrong answers.
            if let removed, !isBlocked(userId) { blocked.insert(removed, at: 0) }
            return false
        }
    }

    /// Clear on sign-out. The next account must not inherit this one's blocked list.
    func reset() {
        blocked = []
        didLoad = false
        pending = []
    }
}
