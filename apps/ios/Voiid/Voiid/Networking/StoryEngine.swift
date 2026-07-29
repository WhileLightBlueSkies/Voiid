//
//  StoryEngine.swift
//  Voiid
//
//  Orchestrates Stories: posting, feed sync, downloads, view receipts and the local expiry
//  sweep. It is deliberately CRYPTO-FREE — every Session/Identity/media-key operation is
//  delegated to ChatEngine (encryptStoryBlob / encryptStoryKeys / decryptStoryEnvelope /
//  decryptStoryReceipt / sendStoryReply). This engine only moves ciphertext, opaque object
//  keys and routing ids around, exactly like the server sees. See docs/STORIES_PROTOCOL.md.
//
//  Local-first: the UI renders from StoryStore; this engine syncs in the background and
//  writes back. A failed fetch leaves the tray unchanged.
//

import Combine
import Foundation
import SwiftUI

/// Posted by WebSocketClient for the `story` / `story_receipt` / `story_deleted` routing
/// signals. The frame carries NO ciphertext — StoryEngine reacts by pulling its own blobs.
extension Notification.Name { static let voiidStorySignal = Notification.Name("voiidStorySignal") }

@MainActor
final class StoryEngine: ObservableObject {
    static let shared = StoryEngine()

    private let svc = StoryService.shared
    private let chat = ChatEngine.shared

    /// Live contexts (others' stories), rebuilt from StoryStore after every sync.
    @Published private(set) var contexts: [StoryContext] = []
    /// My own live stories (the "Your story" cell).
    @Published private(set) var myStories: [Story] = []
    /// True while a post's upload/fan-out is in flight; drives the pending spinner.
    @Published private(set) var posting: Set<String> = []
    /// Stories whose post failed (upload or fan-out) — drives the Retry affordance.
    @Published private(set) var failedPosts: Set<String> = []
    /// Any unexpired unviewed story exists → the tab shows its unread dot.
    @Published private(set) var hasUnviewed: Bool = false

    private init() {
        reloadFromStore()
        // React to live routing signals. `story_deleted` removes the row so a live viewer
        // drops it; the others pull the durable feed/receipts. Frames are fire-and-forget —
        // the durable path is GET /stories/feed on foreground, this just makes it timely.
        NotificationCenter.default.addObserver(forName: .voiidStorySignal, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?["type"] as? String) ?? ""
            let storyId = (note.userInfo?["story_id"] as? String) ?? ""
            Task { @MainActor in
                guard let self else { return }
                if type == "story_deleted", !storyId.isEmpty {
                    StoryStore.delete(storyId); self.reloadFromStore()
                } else {
                    await self.refresh()
                }
            }
        }
    }

    private var myUserId: String? { TokenStore.shared.userId }
    private var myDeviceId: String? { E2EManager.shared.deviceId }

    // MARK: - Local reload (synchronous, from the DB)

    func reloadFromStore() {
        StoryStore.sweepExpired()
        let all = StoryStore.liveContexts()
        // Split mine out into the "Your story" cell; others sort unviewed-first, newest-first.
        contexts = all
            .filter { !$0.isMine }
            .sorted { a, b in
                if a.hasUnviewed != b.hasUnviewed { return a.hasUnviewed }        // unviewed first
                let an = a.newest?.createdAt ?? .distantPast
                let bn = b.newest?.createdAt ?? .distantPast
                return an > bn
            }
        myStories = StoryStore.myStories(myUserId: myUserId ?? "")
        hasUnviewed = StoryStore.hasUnviewed()
    }

    // MARK: - Sync

    /// Foreground refresh: sweep, pull the feed, pull receipts, rebuild published state.
    /// Never throws to the UI — a failure leaves the tray as it was.
    func refresh() async {
        reloadFromStore()
        await syncFeed()
        await syncReceipts()
        reloadFromStore()
        autoDownloadEligible()
    }

    /// Pull this device's pending story key blobs, decrypt + validate each, persist.
    private func syncFeed() async {
        guard let deviceId = myDeviceId else { return }
        let rows: [StoryService.FeedStory]
        // RECOVERY: with no live stories held locally, re-fetch already-delivered rows too, so a
        // lost local DB (or a past dropped key) still recovers the live feed instead of staying
        // empty — the deliver-once feed would otherwise return nothing.
        // Gate on stories RECEIVED FROM OTHERS, not on the whole feed. Your own posted story
        // made the feed non-empty and so silently disabled this recovery — meaning the moment
        // you posted anything, a story previously lost to a dropped key became unrecoverable.
        let includeDelivered = !StoryStore.liveContexts().contains { !$0.isMine }
        do { rows = try await svc.feed(deviceId: deviceId, includeDelivered: includeDelivered) }
        catch { NSLog("[VOIID] story feed fetch failed: \(error)"); return }

        // Computed ONCE for the whole batch: it reads the conversations table, and doing that
        // per row would be a DB hit per story.
        let reachable = UserDirectory.shared.storyReachableUserIds()

        for row in rows {
            if StoryStore.exists(row.story_id) { continue }   // dedup / decrypt-once (§1.5.6)
            guard let plain = await chat.decryptStoryEnvelope(
                    ciphertextB64: row.ciphertext,
                    authorUserId: row.author_id,
                    authorDeviceId: row.author_device_id) else { continue }
            // Decode failures are LOGGED, never silent. This exact line silently dropped every
            // story sent from Android: kotlinx omits default-valued fields and Swift's
            // synthesized Codable throws keyNotFound instead of applying the property default,
            // so the whole feed vanished with no trace. The feed is deliver-once, so each drop
            // was permanent. (Fixed at the type level in StoryEnvelope; the log stays so the
            // next wire mismatch is visible in seconds rather than invisible for weeks.)
            let env: StoryEnvelope
            do { env = try JSONDecoder().decode(StoryEnvelope.self, from: plain) }
            catch {
                NSLog("[VOIID] story DROPPED id=\(row.story_id) from=\(row.author_id): envelope decode failed: \(error)")
                continue
            }

            // Receiver-side validation (§1.5) — the server does none of this for us.
            guard env.story_id == row.story_id else {
                NSLog("[VOIID] story DROPPED id=\(row.story_id): envelope story_id mismatch (\(env.story_id))")
                continue
            }
            guard env.author_id == row.author_id else {
                NSLog("[VOIID] story DROPPED id=\(row.story_id): author mismatch (\(env.author_id) vs \(row.author_id))")
                continue
            }
            guard env.media.mediaUrl == row.r2_key else {
                NSLog("[VOIID] story DROPPED id=\(row.story_id): media ref does not match the feed row's r2_key")
                continue
            }
            // Fall back to the author's CLAIM (authenticated inside the envelope) when the
            // server's rendering is unparseable — never to `Date()`, which meant "expired now".
            let created = parseServerDate(row.created_at)
                ?? Date(timeIntervalSince1970: TimeInterval(env.created_at) / 1000)
            // 4: clamp the expiry to created + 24h + 60s skew. The comment here has always
            // described this clamp; it was never actually applied, so a peer claiming a
            // week-long expiry got one. Now it is enforced, on the server value and the
            // envelope claim alike.
            let cap = created.addingTimeInterval(24 * 3600 + 60)
            let claimed = parseServerDate(row.expires_at)
                ?? Date(timeIntervalSince1970: TimeInterval(env.expires_at) / 1000)
            let serverExpires = min(claimed, cap)
            // 5: author must be someone we actually know. "Known" is REACHABLE — the
            // address-book directory OR an existing 1:1 conversation — not directory-only.
            //
            // Directory-only was both wrong and asymmetric: you can chat with someone daily
            // without ever saving them to your address book, and their story was silently
            // discarded. Because the feed is deliver-once, that drop was PERMANENT. It also
            // disagreed with the send side, which now offers exactly this same set.
            //
            // This is not the real security boundary anyway: we only reach here after
            // decryptStoryEnvelope succeeded, which REQUIRES an established E2E session with
            // the author — a stranger cannot forge that. The check is a secondary filter
            // against someone who somehow holds a session, so widening it to "reachable"
            // costs nothing. (Android's equivalent gate carries the same reasoning.)
            //
            // NOT enforced when `reachable` is EMPTY. That set is built from the local
            // conversation list + directory, both legitimately empty on a fresh install or
            // right after sign-in, and the feed is deliver-once — so dropping there loses a
            // real contact's moment permanently. Empty means "not synced yet", not "stranger".
            // (Android's equivalent gate carries the same carve-out.)
            guard reachable.isEmpty
                    || reachable.contains(env.author_id)
                    || env.author_id == myUserId else {
                NSLog("[VOIID] story DROPPED id=\(row.story_id): author=\(env.author_id) is neither a contact nor someone you have a chat with")
                continue
            }
            if reachable.isEmpty && env.author_id != myUserId {
                NSLog("[VOIID] story ACCEPTED id=\(row.story_id) with a cold reachability cache — directory not yet synced")
            }

            let story = Story(
                id: env.story_id,
                authorId: env.author_id,
                authorDeviceId: row.author_device_id,
                isMine: env.author_id == myUserId,
                createdAt: created,
                expiresAt: serverExpires,
                media: env.media,
                // `caption`/`allowsReplies` are OPTIONAL on the wire (a sender on the other
                // platform may omit them entirely) but non-optional on the model. Fall back to
                // the same defaults the envelope declares, so a missing field is a normal
                // absent value rather than a dropped story.
                caption: env.caption ?? "",
                durationMs: env.durationMs,
                width: env.width,
                height: env.height,
                allowsReplies: env.allowsReplies ?? true,
                viewedAt: nil,
                localPath: nil,
                downloadState: .none)
            StoryStore.upsert(story)
        }
    }

    // MARK: - Posting

    /// Post a story to `audienceUserIds`. Encrypt + upload run OUTSIDE the cross-process
    /// lock (so a big upload never stalls the NSE); only the ratchet-mutating fan-out runs
    /// inside it (that discipline lives in ChatEngine.encryptStoryKeys). The story shows in
    /// "Your story" optimistically the instant this is called.
    ///
    /// `mediaData` is the ALREADY size-capped, re-encoded plaintext (JPEG ≤10MB / H.264
    /// 720p ≤50MB, §8.2) — the caller enforces the caps before handing bytes here.
    func postStory(mediaData: Data, mime: String, caption: String,
                   width: Int?, height: Int?, durationMs: Int?,
                   audienceUserIds: [String]) async {
        guard let myUserId else { return }
        let storyId = UUID().uuidString
        let createdMs = Int64(Date().timeIntervalSince1970 * 1000)
        let expiresMs = createdMs + 24 * 60 * 60 * 1000

        // Optimistic local row: cache the plaintext we already hold so "Your story" renders
        // immediately without a round trip.
        let localPath = StoryStore.mediaCacheDir.appendingPathComponent("\(storyId).bin").path
        try? mediaData.write(to: URL(fileURLWithPath: localPath),
                             options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        posting.insert(storyId)
        failedPosts.remove(storyId)

        do {
            // 1. Encrypt the blob (pure, OUTSIDE the lock).
            let enc = try chat.encryptStoryBlob(mediaData)

            // 2. Presign + PUT the CIPHERTEXT straight to R2. Bytes never transit the API.
            let presign = try await svc.presignUpload()
            try await putToR2(presign.upload_url, ciphertext: enc.ciphertext,
                              contentType: "application/octet-stream")

            // 3. Build the envelope (the media KEY rides inside it, never leaving E2E).
            let ref = MediaRef(mediaUrl: presign.key, mime: mime,
                               key: enc.key, nonce: enc.nonce, sha256: enc.sha256)
            let env = StoryEnvelope(story_id: storyId, author_id: myUserId,
                                    created_at: createdMs, expires_at: expiresMs,
                                    media: ref, caption: caption, durationMs: durationMs,
                                    width: width, height: height, allowsReplies: true)
            let envData = try JSONEncoder().encode(env)

            // 4. Fan out (ratchet-mutating, under the lock inside ChatEngine). Audience +
            //    our own other devices so linked devices show "My story".
            let perDevice = try await chat.encryptStoryKeys(envData, audienceUserIds: audienceUserIds,
                                                            includeOwnDevices: true)
            let keys = perDevice.map { StoryService.KeyEntry(recipient_device_id: $0.deviceId, ciphertext: $0.ciphertext) }
            guard !keys.isEmpty else { throw StoryError.noRecipients }

            // 5. Create the story row (server computes expires_at and returns it).
            let batches = keys.chunked(into: 1000)   // §2.4 cap: first 1000 in POST, rest appended
            let res = try await svc.postStory(storyId: storyId, r2Key: presign.key,
                                              mediaMime: "application/octet-stream",
                                              byteSize: enc.ciphertext.count,
                                              senderDeviceId: myDeviceId, keys: batches.first ?? [])
            for extra in batches.dropFirst() { try? await svc.addKeys(storyId: storyId, keys: extra) }

            // Persist the authoritative row (server expiry wins) with the plaintext already cached.
            let story = Story(id: storyId, authorId: myUserId, authorDeviceId: myDeviceId,
                              isMine: true,
                              // Explicit fallbacks: an unparseable server timestamp must not
                              // make YOUR OWN just-posted story expire immediately (which is
                              // what the old `?? Date()` inside the parser did to expires_at).
                              createdAt: parseServerDate(res.created_at) ?? Date(),
                              expiresAt: parseServerDate(res.expires_at)
                                  ?? Date().addingTimeInterval(24 * 3600),
                              media: ref, caption: caption, durationMs: durationMs,
                              width: width, height: height, allowsReplies: true,
                              viewedAt: Date(), localPath: localPath, downloadState: .ready)
            StoryStore.upsert(story)
            StoryStore.setDownload(storyId, state: .ready, localPath: localPath)
            StoryStore.saveAudience(storyId: storyId, userIds: audienceUserIds)
            posting.remove(storyId)
            NSLog("[VOIID] ✅ posted story \(storyId) to \(keys.count) device(s)")
        } catch {
            posting.remove(storyId)
            failedPosts.insert(storyId)
            NSLog("[VOIID] ❌ post story failed \(storyId): \(error)")
        }
        reloadFromStore()
    }

    // MARK: - Download (§8.4 lazy, verified)

    /// Ensure a story's plaintext is on disk, decrypted + hash-verified. Returns the file
    /// URL, or nil on a decrypt failure / R2 404 (the caller shows the right failure copy).
    @discardableResult
    func ensureDownloaded(_ story: Story) async -> URL? {
        if let path = story.localPath, FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        StoryStore.setDownload(story.id, state: .downloading)
        do {
            let url = try await svc.presignDownload(storyId: story.id)
            let ciphertext = try await getFromR2(url)
            let plain = try chat.decryptStoryBlob(ciphertext: ciphertext,
                                                  key: story.media.key, nonce: story.media.nonce,
                                                  sha256: story.media.sha256)
            let path = StoryStore.mediaCacheDir.appendingPathComponent("\(story.id).bin").path
            try plain.write(to: URL(fileURLWithPath: path),
                            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            StoryStore.setDownload(story.id, state: .ready, localPath: path)
            reloadFromStore()
            return URL(fileURLWithPath: path)
        } catch {
            // R2 404 (object gone) is distinct from a decrypt failure only in the message;
            // both leave the viewer with a clear terminal state, never a blank frame.
            let gone: Bool
            if case APIError.http(let s, _) = error, s == 404 { gone = true } else { gone = false }
            StoryStore.setDownload(story.id, state: gone ? .gone : .failed)
            reloadFromStore()
            NSLog("[VOIID] story download failed \(story.id): \(error)")
            return nil
        }
    }

    /// Auto-download throttle (§8.3): a context's first story is prefetched only when few of
    /// that author's stories are already in flight. We do NOT model "top-20 recents" here (no
    /// cheap signal on this client), so we cap purely on already-downloaded count, which is
    /// the load-bearing half of the rule — everything else stays a pointer until opened.
    private func autoDownloadEligible() {
        for ctx in contexts.prefix(20) {
            let inFlight = ctx.stories.filter { !$0.isViewed && ($0.downloadState == .ready || $0.downloadState == .downloading) }.count
            guard inFlight < 3, let first = ctx.stories.first(where: { !$0.isViewed && $0.downloadState == .none }) else { continue }
            Task { await ensureDownloaded(first) }
        }
    }

    // MARK: - Viewing + receipts

    /// Mark a story seen locally (drives the ring — always recorded, never transmitted) and,
    /// if the viewer opted in AND it isn't our own story, fan a view receipt to the author.
    func markViewed(_ story: Story) async {
        StoryStore.markViewed(story.id)
        reloadFromStore()
        guard StorySettings.shared.sendViewReceipts, !story.isMine, let myUserId else { return }
        let env = StoryViewEnvelope(story_id: story.id, viewer_id: myUserId,
                                    viewed_at: Int64(Date().timeIntervalSince1970 * 1000))
        guard let data = try? JSONEncoder().encode(env) else { return }
        do {
            // Receipt targets the AUTHOR's devices only (never our own other devices).
            let perDevice = try await chat.encryptStoryKeys(data, audienceUserIds: [story.authorId],
                                                            includeOwnDevices: false)
            guard !perDevice.isEmpty else { return }
            let receipts = perDevice.map { StoryService.KeyEntry(recipient_device_id: $0.deviceId, ciphertext: $0.ciphertext) }
            try await svc.postReceipt(storyId: story.id, receipts: receipts)
        } catch {
            NSLog("[VOIID] view receipt send failed \(story.id): \(error)")
        }
    }

    /// Author side: pull pending receipts, decrypt (trying the story's known audience), and
    /// upsert the viewer list. When receipts are OFF the receipts are discarded on decrypt
    /// (the reciprocal opt-out, §4.4) — we simply do not pull or store them.
    private func syncReceipts() async {
        guard StorySettings.shared.sendViewReceipts, let deviceId = myDeviceId else { return }
        let rows: [StoryService.ReceiptRow]
        do { rows = try await svc.receipts(deviceId: deviceId) }
        catch { return }
        for row in rows {
            let audience = StoryStore.audience(storyId: row.story_id)
            guard !audience.isEmpty else { continue }
            guard let plain = await chat.decryptStoryReceipt(ciphertextB64: row.ciphertext, audienceUserIds: audience),
                  let env = try? JSONDecoder().decode(StoryViewEnvelope.self, from: plain),
                  env.story_id == row.story_id else { continue }
            StoryStore.recordView(storyId: row.story_id, viewerUserId: env.viewer_id,
                                  viewedAt: Date(timeIntervalSince1970: TimeInterval(env.viewed_at) / 1000))
        }
    }

    // MARK: - Reply

    /// Reply to a story: an ordinary 1:1 message into the chat with the author (§5). Creates
    /// the conversation if absent. `reaction` is a single emoji for the quick-tap rail.
    func reply(to story: Story, text: String, reaction: String?) async {
        let env = StoryReplyEnvelope(storyId: story.id, storyAuthorId: story.authorId,
                                     storyCreatedAt: Int64(story.createdAt.timeIntervalSince1970 * 1000),
                                     text: text, reaction: reaction)
        // Reuse ChatService's create-or-fetch (returns the existing conversation if any).
        var convId = LocalStore.conversationId(forPeer: story.authorId)
        if convId == nil {
            convId = try? await ChatService.shared.createDirect(memberId: story.authorId)
        }
        guard let convId else { return }
        _ = try? await chat.sendStoryReply(env, conversationId: convId, peerUserId: story.authorId)
    }

    // MARK: - Delete

    /// Author-only delete. Removes the R2 object + rows server-side and locally. NOT a
    /// security operation — anyone who already downloaded keeps the media (§1.6).
    func deleteStory(_ story: Story) async {
        try? await svc.delete(storyId: story.id)
        StoryStore.delete(story.id)
        reloadFromStore()
    }

    // MARK: - R2 transport (ciphertext only; the key/nonce never touch this path)

    private func putToR2(_ urlString: String, ciphertext: Data, contentType: String) async throws {
        guard let url = URL(string: urlString) else { throw StoryError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "PUT"
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        req.httpBody = ciphertext
        let (_, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status, message: "story upload failed (\(status))") }
    }

    private func getFromR2(_ urlString: String) async throws -> Data {
        guard let url = URL(string: urlString) else { throw StoryError.badURL }
        let (data, resp) = try await URLSession.shared.data(from: url)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw APIError.http(status: status, message: "story download failed (\(status))") }
        return data
    }

    // MARK: - Dates

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    /// Parse a server timestamp, or nil if BOTH formatters reject it.
    ///
    /// This used to fall back to `Date()`, which was silently catastrophic for `expires_at`:
    /// an unparseable value became "expires now", so the story was stored and then immediately
    /// filtered out by `liveContexts()` (expires_at > now). The symptom was "posted, nothing
    /// appears" with nothing wrong in the logs. Postgres can render timestamptz as
    /// "2026-07-28 12:00:00+00" (space separator, no T), which neither ISO8601 formatter
    /// accepts — so this was reachable, not theoretical.
    ///
    /// Callers now decide the fallback explicitly. Android's parseTs has always returned null
    /// here for the same reason.
    private func parseServerDate(_ s: String) -> Date? {
        if let d = Self.isoFrac.date(from: s) { return d }
        if let d = ISO8601DateFormatter().date(from: s) { return d }
        // Postgres' space-separated rendering, as a last resort before giving up.
        let fallback = DateFormatter()
        fallback.locale = Locale(identifier: "en_US_POSIX")
        fallback.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss.SSSSSSZ", "yyyy-MM-dd HH:mm:ssZ", "yyyy-MM-dd HH:mm:ss"] {
            fallback.dateFormat = format
            if let d = fallback.date(from: s) { return d }
        }
        NSLog("[VOIID] story: UNPARSEABLE server timestamp '\(s)' — falling back to the envelope's claim")
        return nil
    }

    enum StoryError: Error { case noRecipients, badURL }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
