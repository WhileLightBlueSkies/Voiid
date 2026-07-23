//
//  StoryStore.swift
//  Voiid
//
//  Local-first persistence for Stories, modelled on LocalStore: the UI reads HERE and
//  renders immediately; StoryEngine syncs the server in the background and writes back.
//  A failed fetch therefore leaves the tray exactly as it was.
//
//  Columns hold epoch SECONDS (v1_core convention); the Swift models hold Date. Conversion
//  happens only at this boundary. Decrypted plaintext is a FILE in the app-group Caches
//  dir referenced by `local_path` — never a column, never voiid_messages.json.
//

import Foundation
import GRDB

@MainActor
enum StoryStore {

    private static var db: VoiidDatabase { VoiidDatabase.shared }

    // MARK: - Plaintext cache directory (decrypted story bytes at rest)

    /// Decrypted story bytes live here, file-protected, swept on expiry. In the app-group
    /// container so a future NSE could reach them, but app-private Caches is the fallback.
    static var mediaCacheDir: URL {
        let base = AppGroup.containerURL
            ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("stories", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - Upsert (from feed sync or optimistic local post)

    /// Insert or refresh a story. `viewed_at`/`local_path`/`download_state` are NOT
    /// overwritten by a re-sync — they are this device's local state and the server has
    /// no opinion on them.
    static func upsert(_ s: Story) {
        let mediaJSON = (try? JSONEncoder().encode(s.media)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        db.write { database in
            try database.execute(sql: """
                INSERT INTO stories
                    (id, author_id, author_device_id, is_mine, created_at, expires_at,
                     media_json, caption, duration_ms, width, height, allows_replies,
                     viewed_at, local_path, download_state)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    author_id        = excluded.author_id,
                    author_device_id = COALESCE(excluded.author_device_id, stories.author_device_id),
                    is_mine          = excluded.is_mine,
                    expires_at       = excluded.expires_at,
                    media_json       = excluded.media_json,
                    caption          = excluded.caption,
                    duration_ms      = COALESCE(excluded.duration_ms, stories.duration_ms),
                    width            = COALESCE(excluded.width, stories.width),
                    height           = COALESCE(excluded.height, stories.height),
                    allows_replies   = excluded.allows_replies
                """, arguments: [
                    s.id, s.authorId, s.authorDeviceId, s.isMine,
                    Int64(s.createdAt.timeIntervalSince1970), Int64(s.expiresAt.timeIntervalSince1970),
                    mediaJSON, s.caption, s.durationMs, s.width, s.height, s.allowsReplies,
                    s.viewedAt.map { Int64($0.timeIntervalSince1970) }, s.localPath, s.downloadState.rawValue,
                ])
        }
    }

    /// True if this story id is already stored (dedup / decrypt-once, §1.5.6).
    static func exists(_ id: String) -> Bool {
        db.read { database in
            try Bool.fetchOne(database, sql: "SELECT 1 FROM stories WHERE id = ?", arguments: [id]) ?? false
        } ?? false
    }

    // MARK: - Reads

    /// Every live (unexpired) story, grouped into contexts. Author names are resolved by
    /// the caller through UserDirectory — never a raw id.
    static func liveContexts() -> [StoryContext] {
        let now = Int64(Date().timeIntervalSince1970)
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT * FROM stories
                 WHERE expires_at > ?
                 ORDER BY author_id, created_at ASC
                """, arguments: [now])
        } ?? []
        var byAuthor: [String: [Story]] = [:]
        var order: [String] = []
        for row in rows {
            guard let s = decode(row) else { continue }
            if byAuthor[s.authorId] == nil { order.append(s.authorId) }
            byAuthor[s.authorId, default: []].append(s)
        }
        return order.map { StoryContext(authorId: $0, stories: byAuthor[$0] ?? []) }
    }

    /// My own live stories, newest first (the "Your story" cell).
    static func myStories(myUserId: String) -> [Story] {
        let now = Int64(Date().timeIntervalSince1970)
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT * FROM stories
                 WHERE is_mine = 1 AND expires_at > ?
                 ORDER BY created_at DESC
                """, arguments: [now])
        } ?? []
        return rows.compactMap(decode)
    }

    static func story(_ id: String) -> Story? {
        db.read { database -> Row? in
            try Row.fetchOne(database, sql: "SELECT * FROM stories WHERE id = ?", arguments: [id])
        }.flatMap { $0 }.flatMap(decode)
    }

    /// True when any unexpired unviewed story exists — drives the tab unread dot (§8.1).
    static func hasUnviewed() -> Bool {
        let now = Int64(Date().timeIntervalSince1970)
        return db.read { database in
            try Bool.fetchOne(database, sql: """
                SELECT 1 FROM stories WHERE expires_at > ? AND is_mine = 0 AND viewed_at IS NULL LIMIT 1
                """, arguments: [now]) ?? false
        } ?? false
    }

    // MARK: - Local mutations

    /// Mark a story seen on THIS device (drives the ring). Never transmitted.
    static func markViewed(_ id: String) {
        db.write { database in
            try database.execute(sql:
                "UPDATE stories SET viewed_at = COALESCE(viewed_at, ?) WHERE id = ?",
                arguments: [Int64(Date().timeIntervalSince1970), id])
        }
    }

    static func setDownload(_ id: String, state: StoryDownloadState, localPath: String? = nil) {
        db.write { database in
            if let localPath {
                try database.execute(sql:
                    "UPDATE stories SET download_state = ?, local_path = ? WHERE id = ?",
                    arguments: [state.rawValue, localPath, id])
            } else {
                try database.execute(sql:
                    "UPDATE stories SET download_state = ? WHERE id = ?",
                    arguments: [state.rawValue, id])
            }
        }
    }

    /// Delete a story locally + its cached plaintext file. Used by the reaper sweep and
    /// by the author's Delete action once the server confirms.
    static func delete(_ id: String) {
        if let s = story(id), let path = s.localPath {
            try? FileManager.default.removeItem(atPath: path)
        }
        db.write { database in
            try database.execute(sql: "DELETE FROM stories WHERE id = ?", arguments: [id])
            try database.execute(sql: "DELETE FROM story_audience WHERE story_id = ?", arguments: [id])
            try database.execute(sql: "DELETE FROM story_views WHERE story_id = ?", arguments: [id])
        }
    }

    /// Sweep every expired story + its cached plaintext, regardless of server state
    /// (§3.5). Called on foreground and on viewer open. Stories are the first table that
    /// legitimately supports a TTL sweep.
    static func sweepExpired() {
        let now = Int64(Date().timeIntervalSince1970)
        let expired = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: "SELECT id, local_path FROM stories WHERE expires_at <= ?", arguments: [now])
        } ?? []
        for row in expired {
            if let path: String = row["local_path"] { try? FileManager.default.removeItem(atPath: path) }
        }
        db.write { database in
            try database.execute(sql: """
                DELETE FROM story_audience WHERE story_id IN (SELECT id FROM stories WHERE expires_at <= ?)
                """, arguments: [now])
            try database.execute(sql: """
                DELETE FROM story_views WHERE story_id IN (SELECT id FROM stories WHERE expires_at <= ?)
                """, arguments: [now])
            try database.execute(sql: "DELETE FROM stories WHERE expires_at <= ?", arguments: [now])
        }
    }

    // MARK: - Audience (author-side only)

    static func saveAudience(storyId: String, userIds: [String]) {
        guard !userIds.isEmpty else { return }
        db.write { database in
            for uid in userIds {
                try database.execute(sql:
                    "INSERT INTO story_audience (story_id, user_id) VALUES (?, ?) ON CONFLICT DO NOTHING",
                    arguments: [storyId, uid])
            }
        }
    }

    static func audience(storyId: String) -> [String] {
        db.read { database in
            try String.fetchAll(database, sql: "SELECT user_id FROM story_audience WHERE story_id = ?", arguments: [storyId])
        } ?? []
    }

    // MARK: - Views (author-side only, from decrypted receipts)

    static func recordView(storyId: String, viewerUserId: String, viewedAt: Date) {
        db.write { database in
            try database.execute(sql: """
                INSERT INTO story_views (story_id, viewer_user_id, viewed_at)
                VALUES (?, ?, ?)
                ON CONFLICT(story_id, viewer_user_id) DO NOTHING
                """, arguments: [storyId, viewerUserId, Int64(viewedAt.timeIntervalSince1970)])
        }
    }

    /// (viewerUserId, viewedAt) for a story, newest first — the author's viewer list.
    static func viewers(storyId: String) -> [(userId: String, viewedAt: Date)] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT viewer_user_id, viewed_at FROM story_views
                 WHERE story_id = ? ORDER BY viewed_at DESC
                """, arguments: [storyId])
        } ?? []
        return rows.compactMap { row in
            guard let uid: String = row["viewer_user_id"] else { return nil }
            let at: Int64 = row["viewed_at"] ?? 0
            return (uid, Date(timeIntervalSince1970: TimeInterval(at)))
        }
    }

    // MARK: - Row mapping

    private static func decode(_ row: Row) -> Story? {
        guard let id: String = row["id"], let authorId: String = row["author_id"] else { return nil }
        guard let mediaJSON: String = row["media_json"], let data = mediaJSON.data(using: .utf8),
              let media = try? JSONDecoder().decode(MediaRef.self, from: data) else { return nil }
        let createdAt: Int64 = row["created_at"] ?? 0
        let expiresAt: Int64 = row["expires_at"] ?? 0
        let viewedAt: Int64? = row["viewed_at"]
        return Story(
            id: id,
            authorId: authorId,
            authorDeviceId: row["author_device_id"],
            isMine: row["is_mine"] ?? false,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            expiresAt: Date(timeIntervalSince1970: TimeInterval(expiresAt)),
            media: media,
            caption: row["caption"] ?? "",
            durationMs: row["duration_ms"],
            width: row["width"],
            height: row["height"],
            allowsReplies: row["allows_replies"] ?? true,
            viewedAt: viewedAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            localPath: row["local_path"],
            downloadState: StoryDownloadState(rawValue: row["download_state"] ?? "none") ?? .none
        )
    }
}
