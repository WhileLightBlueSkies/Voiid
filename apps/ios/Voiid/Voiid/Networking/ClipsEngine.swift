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

    /// The author's CREATOR handle, when the row that produced this clip carried one.
    /// The explore feed joins `users`, not `creator_profiles`, so it has none — which is
    /// why every affordance keyed on it (the fullscreen Follow chip) hides rather than
    /// guesses when this is nil.
    var authorHandle: String?
    var authorVerified = false

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
        // Present now that the feed left-joins creator_profiles. Still optional: an author
        // without a creator profile has no handle, and the tile falls back to authorName.
        authorHandle = row.author_handle
        authorVerified = row.author_verified ?? false
    }

    /// A row from a creator's grid or the Following feed.
    ///
    /// Those endpoints return a lighter shape than the explore feed, and the omission that
    /// matters is `liked_by_me`: their queries are not parameterised on the viewer, so there
    /// is no per-caller like state to read. The heart therefore starts unfilled and is
    /// corrected either by `ClipsEngine.knownLikeState` — when the same clip is already on a
    /// grid this engine owns — or by the server's authoritative answer on the first tap.
    ///
    /// `handle` is passed in for a creator's own grid, whose rows carry no author columns at
    /// all because every one of them belongs to the profile being viewed.
    init(creatorRow r: CreatorService.CreatorClipRow, handle: String? = nil) {
        id = r.id
        authorId = r.author_id ?? ""
        authorHandle = r.author_handle ?? handle
        authorName = r.author_display_name
            ?? authorHandle.map { "@\($0)" }
            ?? "Unknown"
        authorVerified = r.author_verified ?? false
        authorPhotoURL = nil
        thumbURL = r.thumb_url
        caption = r.caption
        durationMs = r.duration_ms
        width = r.width
        height = r.height
        viewCount = r.view_count
        likeCount = r.like_count
        commentCount = r.comment_count
        likedByMe = false
        createdAt = ISO8601DateFormatter.voiidParse(r.created_at) ?? Date()
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

    /// Set when a commit was rejected with `profile_required`. The Clips screen observes it
    /// to raise the handle picker, so an upload parked at the last step is recoverable
    /// rather than silently stuck behind a generic "failed" tile.
    @Published var needsCreatorProfile = false

    /// Uploads whose bytes reached R2 but whose row was never created, keyed by clip id.
    /// Holding the closure means the retry re-sends only the row — the presigned keys and
    /// measured sizes it closes over are still valid, so nothing is uploaded twice.
    private var pendingCommits: [String: () async throws -> Void] = [:]

    /// Everything a failed upload needs to be attempted again. Held so the retry does not
    /// re-run the export: transcoding a 90s clip into three renditions is the expensive part,
    /// and the files are already on disk.
    private struct PendingUpload {
        let ladder: ClipExporter.LadderOutput
        let caption: String?
    }
    private var pendingUploads: [String: PendingUpload] = [:]

    /// Whether a failed tile can be retried (as opposed to only dismissed).
    func canRetryUpload(_ clipId: String) -> Bool { pendingUploads[clipId] != nil }

    var hasPendingCommits: Bool { !pendingCommits.isEmpty }

    private init() {}

    /// Finish every upload parked on the profile gate. Called once a creator profile
    /// exists; safe to call when there is nothing pending.
    func retryPendingCommits() async {
        let pending = pendingCommits
        pendingCommits.removeAll()
        for (clipId, commit) in pending {
            do {
                try await commit()
                if let i = clips.firstIndex(where: { $0.id == clipId }) {
                    clips[i].uploadState = .none
                }
            } catch {
                if let i = clips.firstIndex(where: { $0.id == clipId }) {
                    clips[i].uploadState = .failed(Self.message(error))
                }
                // Keep it parked so a later attempt can still finish it.
                pendingCommits[clipId] = commit
            }
        }
        if !pending.isEmpty { await refresh() }
    }

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
    /// A minted playback URL plus the moment it stops being usable.
    private struct CachedPlayback {
        let url: URL
        let quality: ClipQuality
        let expiresAt: Date
    }

    /// PLAYBACK URL CACHE — the single largest scroll-stutter fix in this screen.
    ///
    /// Every page change used to mint a fresh presigned URL, which is a network round-trip
    /// sitting directly on the critical path of a swipe gesture. Swiping back to a clip you
    /// saw two seconds ago re-fetched it. On a slow connection the player could not even
    /// begin buffering until that round-trip returned, which is exactly the "laggy" feel.
    ///
    /// Presigned URLs are valid for an hour, so they are cacheable by construction; the only
    /// requirement is not to serve one past its expiry.
    private var playbackCache: [String: CachedPlayback] = [:]

    /// Safety margin subtracted from the server's TTL. A URL that passes the check must stay
    /// valid long enough to finish playing the clip it was minted for — clips cap at 90s, so
    /// five minutes covers a paused-and-resumed watch with room to spare.
    private static let playbackURLSafetyMargin: TimeInterval = 300

    /// Fallback TTL for a server that does not send `expires_in`. Deliberately far shorter
    /// than the real hour: guessing high risks handing the player a dead URL, and the cost of
    /// guessing low is one extra round-trip.
    private static let playbackURLFallbackTTL: TimeInterval = 600

    func playbackURL(for clipId: String) async throws -> URL {
        let quality = ClipNetworkMonitor.shared.preferredQuality

        // A cached URL is only reusable if it is still valid AND was minted for the quality
        // we now want — the network may have moved from wifi to cellular since, and serving
        // a stale 1080p URL on a metered connection is worse than re-minting.
        if let hit = playbackCache[clipId],
           hit.quality == quality,
           hit.expiresAt > Date() {
            return hit.url
        }

        let resp = try await svc.playback(clipId: clipId, quality: quality)
        guard let url = URL(string: resp.playback_url) else {
            throw APIError.http(status: 0, message: "Bad playback URL")
        }

        let ttl = resp.expires_in.map(TimeInterval.init) ?? Self.playbackURLFallbackTTL
        playbackCache[clipId] = CachedPlayback(
            url: url,
            quality: quality,
            // max(60,…) so a pathologically short server TTL still caches briefly rather
            // than producing an already-expired entry that re-fetches on every single swipe.
            expiresAt: Date().addingTimeInterval(max(60, ttl - Self.playbackURLSafetyMargin))
        )
        return url
    }

    /// Drops cache entries that can no longer be used. Called when the feed reloads; without
    /// it the dictionary grows for the lifetime of the session.
    func prunePlaybackCache() {
        let now = Date()
        playbackCache = playbackCache.filter { $0.value.expiresAt > now }
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

    /// Like/unlike a clip this engine does NOT own.
    ///
    /// The fullscreen pager also runs over a creator's grid and the Following feed, whose
    /// rows belong to `CreatorEngine`. Those callers hold their own optimistic copy, so this
    /// returns the server's authoritative answer — or nil, meaning "revert", which covers
    /// both a failed call and a tap that arrived while the previous one was still in flight.
    func setLike(_ clipId: String, liked: Bool) async -> (liked: Bool, count: Int)? {
        guard !likeInFlight.contains(clipId) else { return nil }
        likeInFlight.insert(clipId)
        defer { likeInFlight.remove(clipId) }
        do {
            let resp = liked ? try await svc.like(clipId: clipId)
                             : try await svc.unlike(clipId: clipId)
            // The same clip is very often on the explore grid too; keeping that copy in step
            // stops the like appearing to undo itself when the user scrolls back to it there.
            if let j = clips.firstIndex(where: { $0.id == clipId }) {
                clips[j].likedByMe = resp.liked
                clips[j].likeCount = resp.like_count
            }
            if let j = myClips.firstIndex(where: { $0.id == clipId }) {
                myClips[j].likedByMe = resp.liked
                myClips[j].likeCount = resp.like_count
            }
            return (resp.liked, resp.like_count)
        } catch {
            return nil
        }
    }

    /// What this engine already knows about a clip's like state, from a grid it owns.
    /// The creator endpoints carry no per-caller like state, so a pager over one of them
    /// seeds from here rather than drawing every heart as unliked.
    func knownLikeState(_ clipId: String) -> (liked: Bool, count: Int)? {
        if let c = clips.first(where: { $0.id == clipId }) { return (c.likedByMe, c.likeCount) }
        if let c = myClips.first(where: { $0.id == clipId }) { return (c.likedByMe, c.likeCount) }
        return nil
    }

    /// Call after a >=2s watch, never on tile appearance. Returns the authoritative count so
    /// a pager over a list this engine does not own can update its own copy.
    @discardableResult
    func markViewed(_ clipId: String) async -> Int? {
        guard !viewedThisSession.contains(clipId) else { return nil }
        viewedThisSession.insert(clipId)
        do {
            let count = try await svc.markViewed(clipId: clipId)
            if let i = clips.firstIndex(where: { $0.id == clipId }) { clips[i].viewCount = count }
            return count
        } catch {
            // Allow a retry later in the session if it failed.
            viewedThisSession.remove(clipId)
            return nil
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
    ///
    /// Returns whether the comment landed, so a pager over a list this engine does not own
    /// can move its own comment count without having to guess.
    @discardableResult
    func addComment(clipId: String, text: String, authorId: String,
                    authorName: String) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }

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
            return true
        } catch {
            if let j = comments[clipId]?.firstIndex(where: { $0.id == tempId }) {
                comments[clipId]?[j].sendState = .failed
            }
            if let i = clips.firstIndex(where: { $0.id == clipId }) {
                clips[i].commentCount = max(0, clips[i].commentCount - 1)
            }
            return false
        }
    }

    /// Delete one of YOUR comments.
    ///
    /// ── OPTIMISTIC, AND DELIBERATELY SO ─────────────────────────────────────────────
    /// The row goes at once and is put back if the server refuses. A delete that waits for a
    /// round trip leaves the comment sitting there while the user wonders whether the tap
    /// registered, and the failure case — someone deleting their own comment on their own
    /// device — is rare enough that optimism is the right trade.
    ///
    /// AUTHORISATION IS THE SERVER'S: `DELETE /clips/:id/comments/:commentId` checks that the
    /// caller wrote the comment (or owns the clip). The UI hides the control for everyone
    /// else, but that is a convenience, not the enforcement — never treat it as such.
    func deleteComment(clipId: String, commentId: String) async {
        guard let idx = comments[clipId]?.firstIndex(where: { $0.id == commentId }) else { return }
        let removed = comments[clipId]![idx]
        comments[clipId]?.remove(at: idx)

        // Keep the count on the clip in step, or the rail says "3" over a list of two.
        if let i = clips.firstIndex(where: { $0.id == clipId }) {
            clips[i].commentCount = max(0, clips[i].commentCount - 1)
        }

        do {
            try await svc.deleteComment(clipId: clipId, commentId: commentId)
        } catch {
            // Put it back exactly where it was, so the list does not reorder under the user.
            let i = min(idx, comments[clipId]?.count ?? 0)
            comments[clipId]?.insert(removed, at: i)
            if let c = clips.firstIndex(where: { $0.id == clipId }) { clips[c].commentCount += 1 }
        }
    }

    @discardableResult
    func retryComment(clipId: String, commentId: String, authorId: String,
                      authorName: String) async -> Bool {
        guard let idx = comments[clipId]?.firstIndex(where: { $0.id == commentId }),
              let failed = comments[clipId]?[idx], failed.sendState == .failed else { return false }
        comments[clipId]?.remove(at: idx)
        return await addComment(clipId: clipId, text: failed.text,
                                authorId: authorId, authorName: authorName)
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

        // Held so a FAILED upload can be run again from the tile, rather than offering only
        // "Dismiss" — which threw away a video the user had already waited through an export
        // for. The ladder files live in the temp directory and are only cleaned up on
        // success or explicit discard, so the retry has real bytes to send.
        pendingUploads[clipId] = PendingUpload(ladder: ladder, caption: caption)
        runUpload(clipId: clipId)
    }

    /// One attempt at the upload for an already-inserted optimistic tile.
    private func runUpload(clipId: String) {
        guard let pending = pendingUploads[clipId] else { return }
        let ladder = pending.ladder
        let caption = pending.caption

        setUploadProgress(clipId, 0)

        Task { [weak self] in
            guard let self else { return }
            // Keep the app alive briefly if the user leaves mid-upload. This is NOT a
            // background URLSession — a real one would need a delegate-based rewrite of every
            // R2 PUT — but it buys the minutes an ordinary clip needs instead of having the
            // transfer killed the moment the screen is dismissed.
            let bg = await UIApplication.shared.beginBackgroundTask(withName: "clip-upload")
            defer { Task { @MainActor in UIApplication.shared.endBackgroundTask(bg) } }

            do {
                let presign = try await svc.presignUpload()

                // The cover goes FIRST and is tiny: once it lands, a failure further down
                // still leaves the tile with a real image rather than a grey box.
                self.setUploadProgress(clipId, 0.05)
                try await Self.putToR2(presign.thumb_upload_url,
                                       body: ladder.thumbnailJPEG, contentType: "image/jpeg")

                // Baseline is REQUIRED — it is what every playback falls back to. Uploaded
                // FROM FILE so URLSession streams it off disk instead of holding the whole
                // video in memory (Android hit a hard OOM doing the byte-array equivalent).
                let baselineSize = (try? FileManager.default
                    .attributesOfItem(atPath: ladder.baseline.path)[.size] as? Int) ?? 0
                // 0.10...0.40 is the baseline's own band, advanced by BYTES SENT rather than
                // jumped at the end. The renditions take 0.40...0.95 below.
                self.setUploadProgress(clipId, 0.10)
                try await Self.putFileToR2(
                    presign.upload_url, file: ladder.baseline, contentType: "video/mp4",
                    onProgress: { fraction in
                        Task { @MainActor [weak self] in
                            self?.setUploadProgress(clipId, 0.10 + 0.30 * fraction)
                        }
                    })

                // Renditions are BEST-EFFORT. A failed rung is dropped from the row rather
                // than failing the post: the clip still plays from the baseline, and losing
                // a whole upload because the 480p copy timed out would be absurd.
                var uploadedKeys: [ClipQuality: String] = [:]
                var uploadedSizes: [ClipQuality: Int] = [:]
                if let targets = presign.renditions {
                    let plan: [(ClipQuality, ClipService.RenditionTarget)] = [
                        (.sd, targets.sd), (.hd, targets.hd), (.fhd, targets.fhd),
                    ]
                    let step = 0.55 / Double(max(1, plan.count))
                    var progress = 0.40
                    for (quality, target) in plan {
                        let base = progress
                        defer { progress += step; self.setUploadProgress(clipId, progress) }
                        guard let rendition = ladder.renditions[quality] else { continue }
                        do {
                            try await Self.putFileToR2(
                                target.upload_url, file: rendition.url,
                                contentType: "video/mp4",
                                onProgress: { fraction in
                                    Task { @MainActor [weak self] in
                                        self?.setUploadProgress(clipId, base + step * fraction)
                                    }
                                })
                            uploadedKeys[quality] = target.key
                            uploadedSizes[quality] = rendition.size
                        } catch {
                            NSLog("[VOIID] clip rendition \(quality.rawValue) upload failed — continuing")
                        }
                    }
                }

                self.setUploadProgress(clipId, 0.95)
                // Committing the row is retried on `profile_required` ALONE. The bytes are
                // already in R2 by this point, so re-running `post` would re-upload the whole
                // ladder; and the gate is normally satisfied before the composer even opens,
                // so reaching here means the profile vanished mid-flight (deleted on another
                // device, or a first post racing the check). Only the commit is repeated.
                let commit = { [weak self] in
                    guard let self else { return }
                    _ = try await self.svc.postClip(
                        clipId: clipId, r2Key: presign.key,
                        thumbKey: presign.thumb_key, caption: caption,
                        durationMs: ladder.durationMs,
                        width: ladder.width, height: ladder.height,
                        byteSize: baselineSize,
                        renditionKeys: uploadedKeys,
                        renditionSizes: uploadedSizes,
                        coverSource: ladder.coverSource.rawValue)
                }
                do {
                    try await commit()
                } catch let e as APIError where e.serverCode == "profile_required" {
                    // Park the upload rather than fail it: the video is safely in R2, and
                    // discarding it because the user has no handle yet would throw away work
                    // they can still complete. The feed surfaces the prompt; `retryCommit`
                    // finishes the job once a profile exists.
                    if let i = self.clips.firstIndex(where: { $0.id == clipId }) {
                        self.clips[i].uploadState = .failed("Choose a handle to finish posting.")
                    }
                    self.pendingCommits[clipId] = commit
                    self.needsCreatorProfile = true
                    return
                }

                // Swap the optimistic tile for the real row.
                if let i = self.clips.firstIndex(where: { $0.id == clipId }) {
                    self.clips[i].uploadState = .none
                }
                self.pendingUploads.removeValue(forKey: clipId)
                Self.cleanUp(ladder)
                await self.refresh()
            } catch {
                // The pending entry is deliberately KEPT so `retryUpload` can run this again.
                // It is dropped only on success or on an explicit discard.
                if let i = self.clips.firstIndex(where: { $0.id == clipId }) {
                    self.clips[i].uploadState = .failed(Self.message(error))
                }
            }
        }
    }

    /// Run a failed upload again from the start. The export is not repeated — the ladder is
    /// still on disk, which is the whole point of holding it.
    func retryUpload(_ clipId: String) {
        guard pendingUploads[clipId] != nil else { return }
        runUpload(clipId: clipId)
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
        // Drop any parked commit too, or a tile the user dismissed would quietly reappear
        // the next time the gate is satisfied.
        pendingCommits.removeValue(forKey: clipId)
        // Discard is the ONLY place the retained ladder is reaped on failure — it is kept
        // across a failed attempt so retry has bytes to send, so without this a dismissed
        // upload would leave three renditions of a 90s video in temp forever.
        if let pending = pendingUploads.removeValue(forKey: clipId) {
            Self.cleanUp(pending.ladder)
            // Also the baseline, which cleanUp deliberately leaves alone on the success path
            // (the upload already read it). On discard nothing else will ever reap it.
            try? FileManager.default.removeItem(at: pending.ladder.baseline)
        }
    }

    func deleteClip(_ clipId: String) async {
        let snapshot = clips
        let mineSnapshot = myClips
        clips.removeAll { $0.id == clipId }
        myClips.removeAll { $0.id == clipId }
        do { try await svc.deleteClip(clipId: clipId) }
        catch {
            // Put it back rather than lie about the delete.
            clips = snapshot
            myClips = mineSnapshot
        }
    }

    // MARK: - My Clips

    @Published private(set) var myClips: [Clip] = []
    @Published private(set) var myLoading = false
    @Published private(set) var myLoadError: String?
    @Published private(set) var myHasLoadedOnce = false
    private var myNextCursor: String?
    private var myReachedEnd = false

    func refreshMine() async {
        myLoading = true
        myLoadError = nil
        do {
            let resp = try await svc.mine()
            myClips = resp.clips.map(Clip.init(row:))
            myNextCursor = resp.next_cursor
            myReachedEnd = resp.next_cursor == nil
        } catch {
            myLoadError = Self.message(error)
        }
        myHasLoadedOnce = true
        myLoading = false
    }

    func loadMoreMineIfNeeded(currentItem: Clip) async {
        guard !myReachedEnd, !myLoading, let cursor = myNextCursor else { return }
        guard let idx = myClips.firstIndex(where: { $0.id == currentItem.id }),
              idx >= myClips.count - 6 else { return }
        do {
            let resp = try await svc.mine(cursor: cursor)
            let existing = Set(myClips.map(\.id))
            myClips.append(contentsOf: resp.clips.map(Clip.init(row:)).filter { !existing.contains($0.id) })
            myNextCursor = resp.next_cursor
            myReachedEnd = resp.next_cursor == nil
        } catch {
            myReachedEnd = true
        }
    }

    /// Edit the caption and/or cover of an existing clip. The VIDEO is never replaced —
    /// people have already watched and engaged with those bytes, so swapping them under a
    /// stable id would turn existing likes into an endorsement of something nobody saw.
    ///
    /// Returns nil on success, or a message to show.
    func updateClip(
        _ clipId: String,
        caption: String?,
        clearCaption: Bool,
        newCoverJPEG: Data? = nil
    ) async -> String? {
        do {
            var thumbKey: String?
            if let newCoverJPEG {
                let presign = try await svc.presignThumb(clipId: clipId)
                try await Self.putToR2(presign.thumb_upload_url, body: newCoverJPEG,
                                       contentType: "image/jpeg")
                thumbKey = presign.thumb_key
            }
            let row = try await svc.updateClip(
                clipId: clipId,
                caption: clearCaption ? .some(nil) : caption.map { .some($0) },
                thumbKey: thumbKey,
                coverSource: thumbKey != nil ? "upload" : nil
            )
            // Replace in BOTH lists — the same clip is on the explore grid too, and
            // leaving a stale caption there reads as "the edit didn't save".
            let updated = Clip(row: row)
            if let i = myClips.firstIndex(where: { $0.id == clipId }) { myClips[i] = updated }
            if let i = clips.firstIndex(where: { $0.id == clipId }) { clips[i] = updated }
            return nil
        } catch {
            return Self.message(error)
        }
    }

    // MARK: - Helpers

    private func setUploadProgress(_ clipId: String, _ p: Double) {
        guard let i = clips.firstIndex(where: { $0.id == clipId }) else { return }
        clips[i].uploadState = .uploading(progress: p)
    }

    /// Small in-memory payloads only — the cover JPEG. Video must use `putFileToR2`.
    private static func putToR2(_ urlString: String, body: Data, contentType: String) async throws {
        let (req, _) = try uploadRequest(urlString, contentType: contentType)
        let (_, resp) = try await URLSession.shared.upload(for: req, from: body)
        try check(resp)
    }

    /// Streams the file off disk rather than loading it. A clip is capped at 100 MB and the
    /// ladder uploads up to four of them; holding those in memory is what OOM-killed the
    /// Android process, and there is no reason for iOS to carry the same risk.
    ///
    /// `onProgress` reports BYTES ACTUALLY SENT. The upload used to advance through fixed
    /// checkpoints (0.05, 0.15, 0.95…), which on a slow connection meant the bar sat at 15%
    /// for a minute and then jumped — indistinguishable from a stall.
    private static func putFileToR2(_ urlString: String, file: URL, contentType: String,
                                    onProgress: (@Sendable (Double) -> Void)? = nil) async throws {
        let (req, _) = try uploadRequest(urlString, contentType: contentType)
        guard let onProgress else {
            let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file)
            try check(resp)
            return
        }
        let observer = UploadProgressDelegate(onProgress: onProgress)
        let (_, resp) = try await URLSession.shared.upload(for: req, fromFile: file,
                                                          delegate: observer)
        try check(resp)
    }

    private static func uploadRequest(_ urlString: String,
                                      contentType: String) throws -> (URLRequest, URL) {
        guard let url = URL(string: urlString) else {
            throw APIError.http(status: 0, message: "Bad upload URL")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        // A 100 MB clip on a slow connection needs far more than APIClient's 20s.
        req.timeoutInterval = 300
        return (req, url)
    }

    private static func check(_ resp: URLResponse) throws {
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            throw APIError.http(status: status, message: "clip upload failed (\(status))")
        }
    }

    private static func message(_ error: Error) -> String {
        if let api = error as? APIError, case .http(_, let m, _) = api { return m }
        return "Something went wrong. Try again."
    }

    /// Reports upload progress as a 0...1 fraction of the request body actually sent.
    /// URLSession retains its delegate for the life of the task, so this is handed in
    /// per-upload rather than held by the engine.
    private final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        private let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        didSendBodyData bytesSent: Int64,
                        totalBytesSent: Int64,
                        totalBytesExpectedToSend: Int64) {
            guard totalBytesExpectedToSend > 0 else { return }
            onProgress(Double(totalBytesSent) / Double(totalBytesExpectedToSend))
        }
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
