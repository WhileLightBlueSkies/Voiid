//
//  CreatorService.swift
//  Voiid
//
//  Thin API layer for the creator-profile + follow endpoints
//  (backend/api/src/routes/creators.ts). Pure transport + DTOs.
//
//  ============================ NOT END-TO-END ENCRYPTED ============================
//  A creator profile is BROADCAST IDENTITY: the handle, display name, bio, avatar and
//  follower counts are shown to strangers and counted by the server. None of that is
//  expressible under E2EE, and this file shares no code path with messages, calls,
//  locations or moments — all of which remain E2EE. See the header of routes/creators.ts.
//  =================================================================================
//
//  ── A FOLLOW IS NOT A MESSAGING RIGHT ────────────────────────────────────────────
//  Nothing here may ever be used to authorise a conversation. Following someone lets you
//  watch their public clips and nothing else; the three paths in 020_reachability.sql
//  (mutual contact / one-way contact / @username + PIN) remain the only ways to open a
//  chat. If you find yourself reading a follow state to unlock messaging, that is a bug.
//

import Foundation

@MainActor
final class CreatorService {
    static let shared = CreatorService()
    private let api = APIClient()
    private init() {}

    // MARK: - Wire DTOs

    /// The server's public profile shape. Note there is deliberately NO user_id: a profile
    /// is public and a user_id is the key other endpoints authorise against, so the API
    /// never hands it out. Follow/unfollow are keyed on the HANDLE for that reason.
    struct Profile: Decodable, Equatable, Identifiable {
        let handle: String
        var display_name: String?
        var bio: String?
        var link_url: String?
        /// Short-lived presigned GET, or null when R2 is unconfigured / the fetch failed.
        var avatar_url: String?
        var follower_count: Int
        var following_count: Int
        var clip_count: Int
        var is_verified: Bool
        var is_self: Bool
        var following: Bool

        /// The handle is unique server-side, so it is a stable identity for SwiftUI.
        var id: String { handle }
    }

    /// `profile: null` is a 200, not a 404 — having no creator profile is the normal state
    /// for the vast majority of users (they are here to message). Modelled as an optional
    /// rather than an error so no Clips screen has to open by handling a failure.
    struct MeResp: Decodable { var profile: Profile? }
    struct ProfileResp: Decodable { let profile: Profile }

    struct AvailabilityResp: Decodable {
        let available: Bool
        /// "format" | "taken" | nil
        var reason: String?
    }

    struct FollowResp: Decodable {
        let following: Bool
        let follower_count: Int
    }

    /// A creator's grid row. Lighter than ClipService.ClipRow — the grid endpoints return
    /// only what a tile draws, with no r2_key or playback URL (see ClipService.playback).
    struct CreatorClipRow: Decodable, Identifiable {
        let id: String
        var thumb_r2_key: String?
        var thumb_url: String?
        var caption: String?
        var duration_ms: Int?
        var width: Int?
        var height: Int?
        var view_count: Int
        var like_count: Int
        var comment_count: Int
        let created_at: String
        // Present only on the following feed, which joins the author's profile.
        var author_id: String?
        var author_handle: String?
        var author_display_name: String?
        var author_verified: Bool?
    }
    struct ClipsResp: Decodable {
        let clips: [CreatorClipRow]
        var next_cursor: String?
    }

    /// GET /creators/:handle answers 301 `{ moved_to }` when a creator has renamed, so
    /// links shared before the change still resolve. Followed transparently in `profile`.
    private struct MovedBody: Decodable { let moved_to: String }

    // MARK: - Profile

    /// Your own profile, or nil if you have none yet (the pre-gate state).
    func me() async throws -> Profile? {
        let resp: MeResp = try await api.request("GET", "creators/me")
        return resp.profile
    }

    /// Advisory availability check for the composer, so "taken" shows as you type rather
    /// than at submit. ADVISORY ONLY — `create` re-checks under the real unique constraint,
    /// because between this call and the insert someone else can take the name and only
    /// the database can settle that race.
    func handleAvailable(_ handle: String) async throws -> AvailabilityResp {
        let esc = handle.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return try await api.request("GET", "creators/handle-available?handle=\(esc)")
    }

    /// THE GATE. Creates the profile required before a first clip can be posted.
    /// Throws `APIError.http(409)` when the handle is taken, `400` when malformed.
    func create(handle: String, displayName: String?, bio: String?,
                linkURL: String?) async throws -> Profile {
        struct Body: Encodable {
            let handle: String
            let display_name: String?
            let bio: String?
            let link_url: String?
        }
        let resp: ProfileResp = try await api.request(
            "POST", "creators",
            body: Body(handle: handle, display_name: displayName,
                       bio: bio, link_url: linkURL))
        return resp.profile
    }

    /// Edit. Every field is independently optional so changing a bio never re-sends a
    /// handle the user did not touch — which matters because a handle change burns the
    /// 30-day rename window (the server answers 429 if one was used recently).
    func update(handle: String? = nil, displayName: String? = nil,
                bio: String? = nil, linkURL: String? = nil) async throws -> Profile {
        struct Body: Encodable {
            var handle: String?
            var display_name: String?
            var bio: String?
            var link_url: String?
        }
        let resp: ProfileResp = try await api.request(
            "PATCH", "creators/me",
            body: Body(handle: handle, display_name: displayName,
                       bio: bio, link_url: linkURL))
        return resp.profile
    }

    // MARK: - Avatar

    struct AvatarPresignResp: Decodable {
        let avatar_r2_key: String
        let upload_url: String
    }

    func avatarPresign(contentType: String = "image/jpeg") async throws -> AvatarPresignResp {
        struct Body: Encodable { let content_type: String }
        return try await api.request("POST", "creators/me/avatar-presign",
                                     body: Body(content_type: contentType))
    }

    /// Attach an avatar that has already been PUT to R2. Split from the presign so a
    /// failed upload never points the profile at a key holding nothing.
    func attachAvatar(key: String) async throws -> Profile {
        struct Body: Encodable { let avatar_r2_key: String }
        let resp: ProfileResp = try await api.request("POST", "creators/me/avatar",
                                                      body: Body(avatar_r2_key: key))
        return resp.profile
    }

    /// The avatar is PLAINTEXT in R2 — it is a public profile picture, not message media,
    /// so it deliberately skips the encryption MediaService applies.
    func uploadAvatar(jpeg: Data) async throws -> Profile {
        let presign = try await avatarPresign()
        guard let url = URL(string: presign.upload_url) else {
            throw APIError.http(status: 0, message: "Bad avatar upload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        let (_, resp) = try await URLSession.shared.upload(for: req, from: jpeg)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "Avatar upload failed (\(status)).")
        }
        return try await attachAvatar(key: presign.avatar_r2_key)
    }

    // MARK: - Public profiles

    /// Public profile by handle, following ONE rename hop so links shared before a handle
    /// change still resolve.
    ///
    /// The 301 here carries `{ moved_to }` as a JSON body rather than a Location header, so
    /// URLSession's own redirect handling never sees it. It is resolved with a raw request
    /// (the shared client would collapse the body into a message string and lose the new
    /// handle). Exactly one hop is followed: history can chain a→b→c, and looping until it
    /// resolves would let a rename cycle hang the screen.
    func profile(handle: String) async throws -> Profile {
        do {
            let resp: ProfileResp = try await api.request("GET", "creators/\(path(handle))")
            return resp.profile
        } catch let e as APIError {
            guard case .http(let status, _, _) = e, status == 301,
                  let moved = try? await movedTo(handle: handle) else { throw e }
            let resp: ProfileResp = try await api.request("GET", "creators/\(path(moved))")
            return resp.profile
        }
    }

    /// Reads `moved_to` off the 301 body. Separate from the shared client because that
    /// client throws away everything but `error` on a non-2xx.
    private func movedTo(handle: String) async throws -> String? {
        let base = APIConfig.baseURL.absoluteString
        let full = (base.hasSuffix("/") ? base : base + "/")
            + "\(APIConfig.apiVersion)/creators/\(path(handle))"
        guard let url = URL(string: full), let token = TokenStore.shared.jwt else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: req)
        return (try? JSONDecoder().decode(MovedBody.self, from: data))?.moved_to
    }

    func clips(handle: String, cursor: String? = nil, limit: Int = 30) async throws -> ClipsResp {
        var p = "creators/\(path(handle))/clips?limit=\(limit)"
        if let cursor, let esc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            p += "&cursor=\(esc)"
        }
        return try await api.request("GET", p)
    }

    // MARK: - Follow graph

    /// Idempotent server-side (`on conflict do nothing`), so a double-tap or a retry after a
    /// dropped response neither errors nor double-counts. Returns the AUTHORITATIVE count —
    /// the caller overwrites its optimistic number with it.
    func follow(handle: String) async throws -> FollowResp {
        try await api.request("POST", "creators/\(path(handle))/follow", body: EmptyBody())
    }

    func unfollow(handle: String) async throws -> FollowResp {
        try await api.request("DELETE", "creators/\(path(handle))/follow")
    }

    /// Clips from creators you follow. Exposes only your OWN following set, which you
    /// already know, so it leaks nothing about anyone else's graph.
    func followingFeed(cursor: String? = nil, limit: Int = 30) async throws -> ClipsResp {
        var p = "creators/feed/following?limit=\(limit)"
        if let cursor, let esc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            p += "&cursor=\(esc)"
        }
        return try await api.request("GET", p)
    }

    // MARK: - Story highlights (048_creator_highlights.sql)
    //
    // A highlight is a curated shelf of the creator's own CLIPS on their public page — server-
    // readable broadcast identity, exactly like the avatar beside it. Stories (017) are not
    // reused and share nothing but a name in other products: a story is ephemeral, audience-
    // scoped and E2EE; a highlight is permanent, public and server-readable.
    //
    // CLIPS ONLY. `creator_highlight_items` references clips(id) and nothing else — a shelf
    // cannot hold a message, a moment or a story, because putting audience-scoped E2EE content
    // on a public page would be a disclosure, not a feature. There is no client-side path here
    // that could name anything but a clip.
    //
    // EVERY FIELD OPTIONAL OR DEFAULTED, for the reason CommunityService states at length: an
    // absent key throws `keyNotFound` and drops the whole payload, not just the field.

    /// One clip on a shelf. Lighter than `CreatorClipRow` — a rail draws a thumbnail and
    /// nothing else.
    struct HighlightItem: Decodable, Identifiable, Hashable {
        let clip_id: String
        /// Short-lived presigned GET, or nil when R2 is unconfigured or the presign failed.
        var thumb_url: String?
        var caption: String?
        var duration_ms: Int?
        var width: Int?
        var height: Int?
        var view_count: Int?
        var like_count: Int?
        var position: Int?

        var id: String { clip_id }
    }

    /// One shelf on the rail.
    ///
    /// `cover_url` nil is the MAJORITY case, not a defect: 048 says an explicit cover is the
    /// exception and the client falls back to the first item's thumbnail. `firstThumb` is that
    /// fallback, resolved here so no view has to re-derive it.
    struct Highlight: Decodable, Identifiable, Hashable {
        let id: String
        var title: String?
        var cover_url: String?
        var position: Int?
        var item_count: Int?
        var items: [HighlightItem]?
        var created_at: String?

        var name: String { title ?? "" }
        var clips: [HighlightItem] { items ?? [] }
        var count: Int { item_count ?? items?.count ?? 0 }
        /// The cover the rail actually draws: the explicit one, else the first clip's thumb,
        /// else nil — and a nil here is a real state the view renders, not an error.
        var coverImage: String? { cover_url ?? items?.first?.thumb_url }
    }

    struct HighlightsResp: Decodable {
        var highlights: [Highlight]?
        /// Whether the viewer owns this profile. Answered by the server rather than compared
        /// client-side, because 029 deliberately keeps `user_id` out of the public profile
        /// shape — there is nothing local to compare against.
        var is_self: Bool?

        var rows: [Highlight] { highlights ?? [] }
        var isSelf: Bool { is_self ?? false }
    }

    /// A creator's rail. PUBLIC — no follow, no contact, no relationship required.
    func highlights(handle: String) async throws -> HighlightsResp {
        try await api.request("GET", "creators/\(path(handle))/highlights")
    }

    /// Create a shelf. Owner only, implicitly: the server keys it on the AUTHENTICATED caller
    /// and there is deliberately no user id in the body to supply.
    func createHighlight(title: String, coverUrl: String? = nil) async throws -> Highlight {
        struct Body: Encodable { let title: String; let cover_url: String? }
        struct Envelope: Decodable { let highlight: Highlight }
        let env: Envelope = try await api.request(
            "POST", "highlights", body: Body(title: title, cover_url: coverUrl))
        return env.highlight
    }

    /// Rename, re-cover or reorder. One shelf per request — 048 gave `position` its own column
    /// precisely so a creator can reorder without the whole rail being rewritten.
    func updateHighlight(id: String, title: String? = nil,
                         position: Int? = nil) async throws -> Highlight {
        struct Body: Encodable { let title: String?; let position: Int? }
        struct Envelope: Decodable { let highlight: Highlight }
        let env: Envelope = try await api.request(
            "PATCH", "highlights/\(id)", body: Body(title: title, position: position))
        return env.highlight
    }

    /// Delete a shelf. The clips are untouched — removing a shelf destroys no content, every
    /// clip it pointed at is still on the grid.
    @discardableResult
    func deleteHighlight(id: String) async throws -> Bool {
        struct Envelope: Decodable { var deleted: Bool? }
        let env: Envelope = try await api.request("DELETE", "highlights/\(id)")
        return env.deleted ?? true
    }

    /// Put one of YOUR OWN clips on the shelf. The server checks both — that you own the shelf
    /// and that you authored the clip — so a shelf cannot be built from someone else's work.
    @discardableResult
    func addHighlightItem(highlightId: String, clipId: String) async throws -> Bool {
        struct Body: Encodable { let clip_id: String }
        struct Envelope: Decodable { var added: Bool? }
        let env: Envelope = try await api.request(
            "POST", "highlights/\(highlightId)/items", body: Body(clip_id: clipId))
        // `false` means it was already on the shelf — a success, not a failure.
        return env.added ?? true
    }

    /// Take a clip off the shelf. Removes the join row ONLY; the clip itself is untouched.
    @discardableResult
    func removeHighlightItem(highlightId: String, clipId: String) async throws -> Bool {
        struct Envelope: Decodable { var removed: Bool? }
        let env: Envelope = try await api.request(
            "DELETE", "highlights/\(highlightId)/items/\(clipId)")
        return env.removed ?? true
    }

    // MARK: - Helpers

    /// Handles are `[a-z][a-z0-9_]{2,19}` so they need no escaping in practice, but a
    /// hand-typed or pasted value reaches here before the server validates it.
    private func path(_ handle: String) -> String {
        handle.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? handle
    }

    private struct EmptyBody: Encodable {}
}
