//
//  ClipsEngine.swift
//  Voiid
//
//  The Clips feature's state: paging the explore grid, background uploads, and
//  optimistic-but-reconciled likes/comments/views.
//
//  Replaces the old dummy `ClipsStore` (a hardcoded array whose likes were lost on
//  relaunch). See docs/CLIPS.md.
//
//  CLIPS ARE NOT E2EE — see the note at the top of ClipService.swift.
//

import Foundation
import SwiftUI
import Combine

// MARK: - Models

/// A clip as the UI consumes it. Distinct from `ClipService.ClipRow` (the wire shape)
/// so optimistic local state (`likePending`, `uploadState`) has somewhere to live.
struct Clip: Identifiable, Hashable {
    let id: String
    var authorId: String
    var authorName: String
    var authorPhotoURL: String?
    var thumbURL: String?
    var caption: String?
    var durationMs: Int?
    var width: Int?
    var height: Int?
    var viewCount: Int
    var likeCount: Int
    var commentCount: Int
    var likedByMe: Bool
    var createdAt: Date

    /// Local-only: a clip being uploaded shows in the grid immediately with progress.
    var uploadState: ClipUploadState = .none
    /// Local-only path to the source file, so an optimistic tile has something to draw
    /// before its remote thumbnail exists.
    var localThumbPath: String?

    init(row: ClipService.ClipRow) {
        id = row.id
        authorId = row.author_id
        authorName = row.author_name ?? "Unknown"
        authorPhotoURL = row.author_photo_url
        thumbURL = row.thumb_url
        caption = row.caption
        durationMs = row.duration_ms
        width = row.width
        height = row.height
        viewCount = row.view_count
        likeCount = row.like_count
        commentCount = row.comment_count
        likedByMe = row.liked_by_me
        createdAt = ISO8601DateFormatter.voiidParse(row.created_at) ?? Date()
    }

    /// Optimistic local placeholder for a clip that is still uploading.
    init(pendingId: String, authorId: String, authorName: String, caption: String?,
         localThumbPath: String?, durationMs: Int?) {
        id = pendingId
        self.authorId = authorId
        self.authorName = authorName
        authorPhotoURL = nil
        thumbURL = nil
        self.caption = caption
        self.durationMs = durationMs
        width = nil; height = nil
        viewCount = 0; likeCount = 0; commentCount = 0
        likedByMe = false
        createdAt = Date()
        uploadState = .uploading(progress: 0)
        self.localThumbPath = localThumbPath
    }
}

enum ClipUploadState: Hashable {
    case none
    case uploading(progress: Double)
    case failed(String)
}

struct ClipComment: Identifiable, Hashable {
    let id: String
    var authorId: String
    var authorName: String
    var authorPhotoURL: String?
    var text: String
    var createdAt: Date
    /// Local-only: a comment awaiting its server row, or one that failed to send.
    var sendState: CommentSendState = .sent

    init(row: ClipService.CommentRow) {
        id = row.id
        authorId = row.author_id
        authorName = row.author_name ?? "Unknown"
        authorPhotoURL = row.author_photo_url
        text = row.text
        createdAt = ISO8601DateFormatter.voiidParse(row.created_at) ?? Date()
    }

    init(pendingId: String, authorId: String, authorName: String, text: String) {
        id = pendingId
        self.authorId = authorId
        self.authorName = authorName
        authorPhotoURL = nil
        self.text = text
        createdAt = Date()
        sendState = .sending
    }
}

enum CommentSendState: Hashable { case sending, sent, failed }

// MARK: - Engine

@MainActor
final class ClipsEngine: ObservableObject {
    static let shared = ClipsEngine()

    @Published private(set) var clips: [Clip] = []
    @Published private(set) var loading = false
    @Published private(set) var loadingMore = false
    /// Non-nil means the LOAD FAILED. The UI must render this as an error state with a
    /// retry — never as the "no clips yet" empty state, which is the single most common
    /// bug in this feature shape.
    @Published private(set) var loadError: String?
    /// True once a load has completed, so the UI can tell "empty" from "not tried yet".
    @Published private(set) var hasLoadedOnce = false

    @Published private(set) var comments: [String: [ClipComment]] = [:]
    @Published private(set) var commentsLoading: Set<String> = []

    private var nextCursor: String?
    private var reachedEnd = false
    private let svc = ClipService.shared

    /// Clips whose like request is in flight — a rapid double-tap must not fire two
    /// mutations and permanently desync the displayed count.
    private var likeInFlight: Set<String> = []
    /// Clips already counted as viewed this session; the server dedupes too, but this
    /// saves a pointless round-trip per rewatch.
    private var viewedThisSession: Set<String> = []

    private init() {}

    // MARK: - Feed paging

    func refresh() async {
        loading = true
        loadError = nil
        do {
            let resp = try await svc.feed()
            // Keep any still-uploading local tiles pinned at the top; the server has no
            // row for them yet, so a naive replace would make the user's post vanish
            // mid-upload.
            let pending = clips.filter { if case .none = $0.uploadState { return false } else { return true } }
            clips = pending + resp.clips.map(Clip.init(row:))
            nextCursor = resp.next_cursor
            reachedEnd = resp.next_cursor == nil
            hasLoadedOnce = true
        } catch {
            loadError = Self.message(error)
            hasLoadedOnce = true
        }
        loading = false
    }

    func loadMoreIfNeeded(currentItem: Clip) async {
        guard !reachedEnd, !loadingMore, !loading, let cursor = nextCursor else { return }
        // Trigger when the user reaches the last ~6 tiles (two grid rows).
        guard let idx = clips.firstIndex(where: { $0.id == currentItem.id }),
              idx >= clips.count - 6 else { return }

        loadingMore = true
        do {
            let resp = try await svc.feed(cursor: cursor)
            let existing = Set(clips.map(\.id))
            clips.append(contentsOf: resp.clips.map(Clip.init(row:)).filter { !existing.contains($0.id) })
            nextCursor = resp.next_cursor
            reachedEnd = resp.next_cursor == nil
        } catch {
            // A failed page-append must not wipe the grid the user is already reading.
            // Silently stop paging; pull-to-refresh is the recovery.
            reachedEnd = true
        }
        loadingMore = false
    }

    // MARK: - Playback

    /// Resolve a playback URL at the quality this connection warrants. The server may
    /// serve a DIFFERENT rung than requested (a 480p source has no 1080p rendition), so
    /// it reports back what it actually served.
    func playbackURL(for clipId: String) async throws -> URL {
        let quality = ClipNetworkMonitor.shared.preferredQuality
        let resp = try await svc.playback(clipId: clipId, quality: quality)
        guard let url = URL(string: resp.playback_url) else {
            throw APIError.http(status: 0, message: "Bad playback URL")
        }
        return url
    }

    // MARK: - Interactions

    /// Optimistic flip, then OVERWRITE with the server's authoritative count. Optimistic
    /// UI must never become the source of truth.
    func toggleLike(_ clipId: String) async {
        guard !likeInFlight.contains(clipId) else { return }
        guard let i = clips.firstIndex(where: { $0.id == clipId }) else { return }

        let wasLiked = clips[i].likedByMe
        let previousCount = clips[i].likeCount
        likeInFlight.insert(clipId)
        clips[i].likedByMe = !wasLiked
        clips[i].likeCount = max(0, previousCount + (wasLiked ? -1 : 1))

        do {
            let resp = wasLiked ? try await svc.unlike(clipId: clipId)
                                : try await svc.like(clipId: clipId)
            if let j = clips.firstIndex(where: { $0.id == clipId }) {
                clips[j].likedByMe = resp.liked
                clips[j].likeCount = resp.like_count
            }
        } catch {
            // Revert — a like that silently failed is a lie the user acts on.
            if let j = clips.firstIndex(where: { $0.id == clipId }) {
                clips[j].likedByMe = wasLiked
                clips[j].likeCount = previousCount
            }
        }
        likeInFlight.remove(clipId)
    }

    /// Call after a >=2s watch, never on tile appearance.
    func markViewed(_ clipId: String) async {
        guard !viewedThisSession.contains(clipId) else { return }
        viewedThisSession.insert(clipId)
        do {
            let count = try await svc.markViewed(clipId: clipId)
            if let i = clips.firstIndex(where: { $0.id == clipId }) { clips[i].viewCount = count }
        } catch {
            // Allow a retry later in the session if it failed.
            viewedThisSession.remove(clipId)
        }
    }

    // MARK: - Comments

    func loadComments(for clipId: String) async {
        commentsLoading.insert(clipId)
        do {
            let resp = try await svc.comments(clipId: clipId)
            comments[clipId] = resp.comments.map(ClipComment.init(row:))
        } catch {
            // Leave whatever is cached; the panel shows its own error affordance.
            if comments[clipId] == nil { comments[clipId] = [] }
        }
        commentsLoading.remove(clipId)
    }

    /// Inserts a `.sending` row immediately, then swaps in the server row. On failure the
    /// row is marked `.failed` and kept — never silently dropped.
    func addComment(clipId: String, text: String, authorId: String, authorName: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let tempId = "pending-\(UUID().uuidString)"
        let pending = ClipComment(pendingId: tempId, authorId: authorId,
                                  authorName: authorName, text: trimmed)
        comments[clipId, default: []].append(pending)
        if let i = clips.firstIndex(where: { $0.id == clipId }) { clips[i].commentCount += 1 }

        do {
            let row = try await svc.addComment(clipId: clipId, text: trimmed)
            if let j = comments[clipId]?.firstIndex(where: { $0.id == tempId }) {
                comments[clipId]?[j] = ClipComment(row: row)
            }
        } catch {
            if let j = comments[clipId]?.firstIndex(where: { $0.id == tempId }) {
                comments[clipId]?[j].sendState = .failed
            }
            if let i = clips.firstIndex(where: { $0.id == clipId }) {
                clips[i].commentCount = max(0, clips[i].commentCount - 1)
            }
        }
    }

    func retryComment(clipId: String, commentId: String, authorId: String, authorName: String) async {
        guard let idx = comments[clipId]?.firstIndex(where: { $0.id == commentId }),
              let failed = comments[clipId]?[idx], failed.sendState == .failed else { return }
        comments[clipId]?.remove(at: idx)
        await addComment(clipId: clipId, text: failed.text, authorId: authorId, authorName: authorName)
    }

    // MARK: - Posting

    /// Optimistic post: the tile appears in the grid immediately and the upload runs in
    /// the background, so Share never blocks on a 100 MB PUT. Mirrors StoryEngine's
    /// reasoning for the same decision.
    func post(ladder: ClipExporter.LadderOutput, caption: String?,
              authorId: String, authorName: String) {
        let clipId = UUID().uuidString.lowercased()

        // Persist the cover so the optimistic tile has something to draw.
        let thumbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_thumb_\(clipId).jpg")
        try? ladder.thumbnailJPEG.write(to: thumbPath)

        var placeholder = Clip(pendingId: clipId, authorId: authorId, authorName: authorName,
                               caption: caption, localThumbPath: thumbPath.path,
                               durationMs: ladder.durationMs)
        placeholder.width = ladder.width
        placeholder.height = ladder.height
        clips.insert(placeholder, at: 0)

        Task { [weak self] in
            guard let self else { return }
            do {
                let presign = try await svc.presignUpload()

                // The cover goes FIRST and is tiny: once it lands, a failure further down
                // still leaves the tile with a real image rather than a grey box.
                self.setUploadProgress(clipId, 0.05)
                try await Self.putToR2(presign.thumb_upload_url,
                                       body: ladder.thumbnailJPEG, contentType: "image/jpeg")

                // Baseline is REQUIRED — it is what every playback falls back to.
                let baselineData = try Data(contentsOf: ladder.baseline)
                self.setUploadProgress(clipId, 0.15)
                try await Self.putToR2(presign.upload_url, body: baselineData, contentType: "video/mp4")

                // Renditions are BEST-EFFORT. A failed rung is dropped from the row rather
                // than failing the post: the clip still plays from the baseline, and losing
                // a whole upload because the 480p copy timed out would be absurd.
                var uploadedKeys: [ClipQuality: String] = [:]
                var uploadedSizes: [ClipQuality: Int] = [:]
                if let targets = presign.renditions {
                    let plan: [(ClipQuality, ClipService.RenditionTarget)] = [
                        (.sd, targets.sd), (.hd, targets.hd), (.fhd, targets.fhd),
                    ]
                    let step = 0.75 / Double(max(1, plan.count))
                    var progress = 0.2
                    for (quality, target) in plan {
                        defer { progress += step; self.setUploadProgress(clipId, progress) }
                        guard let rendition = ladder.renditions[quality] else { continue }
                        do {
                            let data = try Data(contentsOf: rendition.url)
                            try await Self.putToR2(target.upload_url, body: data, contentType: "video/mp4")
                            uploadedKeys[quality] = target.key
                            uploadedSizes[quality] = rendition.size
                        } catch {
                            NSLog("[VOIID] clip rendition \(quality.rawValue) upload failed — continuing")
                        }
                    }
                }

                self.setUploadProgress(clipId, 0.95)
                _ = try await svc.postClip(clipId: clipId, r2Key: presign.key,
                                           thumbKey: presign.thumb_key, caption: caption,
                                           durationMs: ladder.durationMs,
                                           width: ladder.width, height: ladder.height,
                                           byteSize: baselineData.count,
                                           renditionKeys: uploadedKeys,
                                           renditionSizes: uploadedSizes,
                                           coverSource: ladder.coverSource.rawValue)

                // Swap the optimistic tile for the real row.
                if let i = self.clips.firstIndex(where: { $0.id == clipId }) {
                    self.clips[i].uploadState = .none
                }
                Self.cleanUp(ladder)
                await self.refresh()
            } catch {
                if let i = self.clips.firstIndex(where: { $0.id == clipId }) {
                    self.clips[i].uploadState = .failed(Self.message(error))
                }
            }
        }
    }

    /// Three renditions of a 90s clip is a lot of temp storage to leave lying around.
    private static func cleanUp(_ ladder: ClipExporter.LadderOutput) {
        for (_, rendition) in ladder.renditions {
            try? FileManager.default.removeItem(at: rendition.url)
        }
    }

    /// Drop a failed optimistic tile (the user tapped dismiss on the retry affordance).
    func discardFailedUpload(_ clipId: String) {
        clips.removeAll { $0.id == clipId && $0.uploadState != .none }
    }

    func deleteClip(_ clipId: String) async {
        let snapshot = clips
        clips.removeAll { $0.id == clipId }
        do { try await svc.deleteClip(clipId: clipId) }
        catch { clips = snapshot }   // put it back rather than lie about the delete
    }

    // MARK: - Helpers

    private func setUploadProgress(_ clipId: String, _ p: Double) {
        guard let i = clips.firstIndex(where: { $0.id == clipId }) else { return }
        clips[i].uploadState = .uploading(progress: p)
    }

    private static func putToR2(_ urlString: String, body: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else {
            throw APIError.http(status: 0, message: "Bad upload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // A 100 MB clip on a slow connection needs far more than APIClient's 20s.
        req.timeoutInterval = 300
        let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "clip upload failed (\(status))")
        }
    }

    private static func message(_ error: Error) -> String {
        if let api = error as? APIError, case .http(_, let m) = api { return m }
        return "Something went wrong. Try again."
    }
}

// MARK: - Date parsing

extension ISO8601DateFormatter {
    /// Postgres `timestamptz` comes back with fractional seconds; the default
    /// ISO8601DateFormatter rejects those, which would silently date every clip to now.
    static func voiidParse(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }
}
