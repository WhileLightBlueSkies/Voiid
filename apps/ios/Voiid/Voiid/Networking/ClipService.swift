//
//  ClipService.swift
//  Voiid
//
//  Thin API layer for the Clips endpoints (backend/api/src/routes/clips.ts). Pure
//  transport + DTOs.
//
//  NOTE — clips are NOT end-to-end encrypted, unlike everything StoryService touches.
//  They are public broadcast content: the media is PLAINTEXT in R2 and the server
//  attributes view/like/comment counts. That is a deliberate, scoped exception (a
//  broadcast has no fixed recipient set to encrypt to); see docs/CLIPS.md §0 and the
//  header of routes/clips.ts. Nothing here shares a code path with messages, calls,
//  locations or moments, all of which remain E2EE.
//

import Foundation

@MainActor
final class ClipService {
    static let shared = ClipService()
    private let api = APIClient()
    private init() {}

    // MARK: - Wire DTOs

    struct RenditionTarget: Decodable {
        let key: String
        let upload_url: String
    }
    struct RenditionTargets: Decodable {
        let sd: RenditionTarget
        let hd: RenditionTarget
        let fhd: RenditionTarget
    }
    struct PresignUploadResp: Decodable {
        let key: String
        let upload_url: String
        let thumb_key: String
        let thumb_upload_url: String
        /// Optional so a client talking to a pre-021 backend still uploads the baseline.
        var renditions: RenditionTargets?
    }

    struct PostClipResp: Decodable {
        let clip_id: String
        let created_at: String
    }

    /// A clip row as the feed hands it back. `thumb_url` is a short-lived presigned GET;
    /// the VIDEO url is deliberately absent (see `playback(clipId:)`).
    struct ClipRow: Decodable {
        let id: String
        let author_id: String
        let r2_key: String
        let thumb_r2_key: String
        var thumb_url: String?
        var caption: String?
        var duration_ms: Int?
        var width: Int?
        var height: Int?
        var byte_size: Int?
        let view_count: Int
        let like_count: Int
        let comment_count: Int
        let created_at: String
        var author_name: String?
        var author_photo_url: String?
        /// LEFT joined from `creator_profiles`, so null for an author with no creator
        /// profile. The tile falls back to the display name rather than blanking.
        var author_handle: String?
        var author_verified: Bool?
        let liked_by_me: Bool
        /// Which renditions exist. Defaulted so a pre-021 backend still decodes.
        var has_sd: Bool = false
        var has_hd: Bool = false
        var has_fhd: Bool = false
        var byte_size_sd: Int?
        var byte_size_hd: Int?
        var byte_size_fhd: Int?
        var cover_source: String?
    }
    struct FeedResp: Decodable {
        let clips: [ClipRow]
        var next_cursor: String?
    }

    struct PlaybackResp: Decodable {
        let playback_url: String
        /// Which rendition the server ACTUALLY served — the requested quality is a
        /// request, not a guarantee (a 480p source has no 1080p rendition).
        var quality: String?
        var byte_size: Int?
        /// Seconds this presigned URL stays valid. OPTIONAL because Swift's Codable throws
        /// `keyNotFound` on an absent key rather than applying a default — a non-optional
        /// here would hard-fail playback against any server older than this field.
        var expires_in: Int?
    }
    struct ViewResp: Decodable { let view_count: Int }
    struct LikeResp: Decodable { let liked: Bool; let like_count: Int }

    struct CommentRow: Decodable {
        let id: String
        let clip_id: String
        let author_id: String
        let text: String
        let created_at: String
        var author_name: String?
        var author_photo_url: String?
    }
    struct CommentsResp: Decodable {
        let comments: [CommentRow]
        var next_cursor: String?
    }
    struct PostCommentResp: Decodable { let comment: CommentRow }

    // MARK: - Endpoints

    /// Presigned PUTs for BOTH the video and its cover frame, in one round-trip.
    func presignUpload(mime: String = "video/mp4") async throws -> PresignUploadResp {
        struct Body: Encodable { let mime: String }
        return try await api.request("POST", "clips/presign-upload", body: Body(mime: mime))
    }

    /// Create the row. Called only AFTER both R2 PUTs succeed — the server has no
    /// 'uploading' state by design (a client that dies mid-upload must not leave a
    /// broken tile in everyone's feed).
    func postClip(clipId: String, r2Key: String, thumbKey: String, caption: String?,
                  durationMs: Int?, width: Int?, height: Int?, byteSize: Int?,
                  renditionKeys: [ClipQuality: String] = [:],
                  renditionSizes: [ClipQuality: Int] = [:],
                  coverSource: String = "frame") async throws -> PostClipResp {
        struct Body: Encodable {
            let clip_id: String; let r2_key: String; let thumb_r2_key: String
            let caption: String?; let duration_ms: Int?
            let width: Int?; let height: Int?; let byte_size: Int?
            let r2_key_sd: String?; let r2_key_hd: String?; let r2_key_fhd: String?
            let byte_size_sd: Int?; let byte_size_hd: Int?; let byte_size_fhd: Int?
            let cover_source: String
        }
        return try await api.request("POST", "clips", body: Body(
            clip_id: clipId, r2_key: r2Key, thumb_r2_key: thumbKey, caption: caption,
            duration_ms: durationMs, width: width, height: height, byte_size: byteSize,
            r2_key_sd: renditionKeys[.sd], r2_key_hd: renditionKeys[.hd],
            r2_key_fhd: renditionKeys[.fhd],
            byte_size_sd: renditionSizes[.sd], byte_size_hd: renditionSizes[.hd],
            byte_size_fhd: renditionSizes[.fhd],
            cover_source: coverSource))
    }

    /// Explore grid, newest-first. `cursor` is the opaque keyset cursor from the
    /// previous page — never an offset (an offset-paged infinite grid duplicates and
    /// skips tiles whenever somebody posts mid-scroll).
    func feed(cursor: String? = nil, limit: Int = 30) async throws -> FeedResp {
        var path = "clips/feed?limit=\(limit)"
        if let cursor, let esc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&cursor=\(esc)"
        }
        return try await api.request("GET", path)
    }

    /// The signed-in user's own grid.
    func mine(cursor: String? = nil, limit: Int = 30) async throws -> FeedResp {
        var path = "clips/mine?limit=\(limit)"
        if let cursor, let esc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&cursor=\(esc)"
        }
        return try await api.request("GET", path)
    }

    /// Short-lived playback URL, minted on demand. Deliberately not returned by the
    /// feed: a 30-tile page would mint 30 video URLs that mostly go unused.
    func playback(clipId: String, quality: ClipQuality = .hd) async throws -> PlaybackResp {
        try await api.request("GET", "clips/\(clipId)/playback?quality=\(quality.rawValue)")
    }

    /// Idempotent per (clip, user), server-side. Call after a >=2s watch — NOT on tile
    /// appearance, or scroll-past impressions inflate every count in the grid.
    @discardableResult
    func markViewed(clipId: String) async throws -> Int {
        let resp: ViewResp = try await api.request("POST", "clips/\(clipId)/view",
                                                   body: EmptyBody())
        return resp.view_count
    }

    /// Returns the AUTHORITATIVE count — the caller overwrites its optimistic number.
    func like(clipId: String) async throws -> LikeResp {
        try await api.request("POST", "clips/\(clipId)/like", body: EmptyBody())
    }

    func unlike(clipId: String) async throws -> LikeResp {
        try await api.request("DELETE", "clips/\(clipId)/like")
    }

    func comments(clipId: String, cursor: String? = nil, limit: Int = 50) async throws -> CommentsResp {
        var path = "clips/\(clipId)/comments?limit=\(limit)"
        if let cursor, let esc = cursor.addingPercentEncoding(withAllowedCharacters: .alphanumerics) {
            path += "&cursor=\(esc)"
        }
        return try await api.request("GET", path)
    }

    func addComment(clipId: String, text: String) async throws -> CommentRow {
        struct Body: Encodable { let text: String }
        let resp: PostCommentResp = try await api.request("POST", "clips/\(clipId)/comments",
                                                          body: Body(text: text))
        return resp.comment
    }

    func deleteComment(clipId: String, commentId: String) async throws {
        _ = try await api.request("DELETE", "clips/\(clipId)/comments/\(commentId)",
                                  as: EmptyResponse.self)
    }

    func deleteClip(clipId: String) async throws {
        _ = try await api.request("DELETE", "clips/\(clipId)", as: EmptyResponse.self)
    }

    // MARK: - Editing (caption + cover only; the video itself is immutable)

    struct PresignThumbResp: Decodable {
        let thumb_key: String
        let thumb_upload_url: String
    }

    /// A fresh cover key for an existing clip. The server mints a NEW uuid rather than
    /// reusing the old one so caches holding the previous cover are actually invalidated.
    func presignThumb(clipId: String) async throws -> PresignThumbResp {
        try await api.request("POST", "clips/\(clipId)/presign-thumb", body: EmptyBody())
    }

    /// Caption and/or cover. Both optional and independently applied, so changing the
    /// caption never re-sends a cover the user did not touch.
    ///
    /// `caption` is doubly optional on purpose: `.some(nil)` clears it, `nil` leaves it
    /// alone. Collapsing those would make "clear my caption" impossible to express.
    func updateClip(
        clipId: String,
        caption: String?? = nil,
        thumbKey: String? = nil,
        coverSource: String? = nil
    ) async throws -> ClipRow {
        struct Body: Encodable {
            var caption: String??
            var thumb_r2_key: String?
            var cover_source: String?

            // Swift's synthesized encoder omits a `.some(nil)` double optional entirely,
            // which would silently drop exactly the "clear the caption" case. Encode it
            // explicitly as JSON null.
            func encode(to encoder: Encoder) throws {
                var c = encoder.container(keyedBy: CodingKeys.self)
                if let caption { try c.encode(caption, forKey: .caption) }
                try c.encodeIfPresent(thumb_r2_key, forKey: .thumb_r2_key)
                try c.encodeIfPresent(cover_source, forKey: .cover_source)
            }
            enum CodingKeys: String, CodingKey { case caption, thumb_r2_key, cover_source }
        }
        struct Resp: Decodable { let clip: ClipRow }
        let resp: Resp = try await api.request(
            "PATCH", "clips/\(clipId)",
            body: Body(caption: caption, thumb_r2_key: thumbKey, cover_source: coverSource)
        )
        return resp.clip
    }

    /// Bodyless POST/DELETE still needs a JSON body for the shared client.
    private struct EmptyBody: Encodable {}
}
