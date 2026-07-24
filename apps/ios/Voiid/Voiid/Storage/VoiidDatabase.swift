//
//  VoiidDatabase.swift
//  Voiid
//
//  The single local source of truth. Everything the UI renders is read from HERE,
//  never straight from the network — the server is a sync peer, not the store.
//
//  WHY: the app previously kept messages in one app-group JSON blob and everything
//  else (conversations, contacts, profiles) in memory or in per-view fetches. A cold
//  launch with no network therefore rendered an EMPTY chat grid even though the whole
//  message history sat on disk, because the conversation list only ever came from the
//  server. Local-first fixes that class of bug by construction: a failed fetch leaves
//  the UI exactly as it was, showing local data.
//
//  Same shape Signal and WhatsApp use — one SQLite database, written by sync, read by
//  the UI. (Signal-iOS reaches the same place via GRDB + a schema migrator; we follow
//  the pattern, not the code.)
//
//  CROSS-PROCESS: the database lives in the App Group container because the
//  Notification Service Extension decrypts messages in a separate process and must
//  write them where the app will see them. WAL mode allows concurrent readers with a
//  writer; `CrossProcessLock` (SharedStore.swift) still guards the ratchet critical
//  section, which is a stricter requirement than database consistency.
//
//  FILE PROTECTION: `.completeUntilFirstUserAuthentication`, NOT `.complete`. The NSE
//  must be able to write a decrypted message while the device is locked; with
//  `.complete` the file is unreadable in that state and incoming messages would be
//  silently dropped until the next unlock.
//

import Foundation
import GRDB

/// Local database handle. Open once per process via `VoiidDatabase.shared`.
final class VoiidDatabase {
    static let shared = VoiidDatabase()

    /// nil only if the database could not be opened at all (missing App Group
    /// entitlement, disk full). Callers degrade to network-only rather than crash —
    /// a broken cache must never be worse than no cache.
    private(set) var pool: DatabasePool?

    private init() {
        do {
            pool = try Self.open()
            // Loud, unmissable proof the local DB opened, WHERE it lives, and what it holds.
            // If you ever see "local database UNAVAILABLE" instead, that is why nothing is
            // storing locally — every read/write silently no-ops on a nil pool.
            let counts = try? pool?.read { db -> String in
                let convs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
                let msgs = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
                let users = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM users") ?? 0
                return "conversations=\(convs) messages=\(msgs) users=\(users)"
            }
            NSLog("[VOIID] ✅ local DB OPEN at \(Self.databaseURL.path) — \(counts ?? "?") | appGroup=\(AppGroup.containerURL != nil)")
        } catch {
            NSLog("[VOIID] ❌ local database UNAVAILABLE (nothing will persist): \(error)")
            pool = nil
        }
    }

    // MARK: - Location

    /// App-group path so the NSE writes the same file the app reads. Falls back to
    /// Application Support if the entitlement is missing, which keeps a development
    /// build working (the NSE just won't share state).
    static var databaseURL: URL {
        let dir = AppGroup.containerURL
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("voiid.sqlite")
    }

    private static func open() throws -> DatabasePool {
        var config = Configuration()
        // Never log SQL in release: message text and SDP-adjacent routing ids pass
        // through here and must not reach the system log.
        config.publicStatementArguments = false
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
        }

        let url = databaseURL
        let pool = try DatabasePool(path: url.path, configuration: config)

        // Must be applied after the file exists, and covers the -wal/-shm siblings too.
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            guard FileManager.default.fileExists(atPath: path) else { continue }
            try? FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                ofItemAtPath: path
            )
        }

        try migrator.migrate(pool)
        return pool
    }

    // MARK: - Schema

    /// Ordered, append-only migrations. NEVER edit a shipped migration — add a new
    /// one. An installed app replays only the migrations it hasn't seen, so editing
    /// history silently diverges schemas between old and new installs.
    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1_core") { db in
            // --- users -------------------------------------------------------------
            // One row per person we know anything about, from any source. The name
            // columns are deliberately separate rather than pre-resolved into one
            // "display name", because precedence differs per source and the address
            // book can change without the server knowing:
            //   saved_name  — from THIS device's address book. Always wins: if you
            //                 saved them as "Mum", the app says "Mum" regardless of
            //                 what they called themselves at signup.
            //   full_name   — what the peer set on their own profile.
            //   username    — Clips handle.
            //   phone_e164  — normalized number, shown when there's no name at all.
            // A raw user id is NEVER an acceptable display name (that's the UUID bug).
            try db.create(table: "users") { t in
                t.primaryKey("user_id", .text)
                t.column("saved_name", .text)
                t.column("full_name", .text)
                t.column("username", .text)
                t.column("phone_e164", .text)
                t.column("photo_url", .text)
                t.column("bio", .text)
                t.column("updated_at", .integer).notNull().defaults(to: 0)
            }

            // --- conversations -----------------------------------------------------
            // `title` is only authoritative for GROUPS. For a direct chat the title is
            // derived at read time from `users` via peer_user_id, so renaming a contact
            // in the address book updates every screen at once instead of leaving a
            // stale copy denormalized here.
            try db.create(table: "conversations") { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull().defaults(to: "direct")
                t.column("title", .text)
                t.column("peer_user_id", .text).references("users", onDelete: .setNull)
                t.column("photo_url", .text)
                t.column("last_message_at", .integer)
                t.column("unread_count", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "idx_conversations_recent", on: "conversations",
                          columns: ["last_message_at"])

            // --- messages ----------------------------------------------------------
            // Mirrors DecryptedMessage so the existing app-group JSON blob imports
            // losslessly. `media` stays a JSON column: MediaRef is a stable Codable
            // and giving it tables of its own would buy nothing today.
            //
            // `pending` is the offline outbox — a message typed with no network is
            // written here FIRST and retried later, so it survives a restart.
            try db.create(table: "messages") { t in
                t.primaryKey("id", .text)
                t.column("conversation_id", .text).notNull()
                t.column("sender_id", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("created_at", .integer).notNull()
                t.column("is_mine", .boolean).notNull().defaults(to: false)
                t.column("pending", .boolean).notNull().defaults(to: false)
                t.column("failed", .boolean).notNull().defaults(to: false)
                t.column("server_id", .text)
                t.column("delivery_status", .text)
                t.column("media_json", .text)
            }
            // The hot query is "latest N messages in this conversation".
            try db.create(index: "idx_messages_conversation", on: "messages",
                          columns: ["conversation_id", "created_at"])
            // Receipts arrive keyed by SERVER id; without this the match is a scan.
            try db.create(index: "idx_messages_server_id", on: "messages",
                          columns: ["server_id"])
            // Drives the outbox flush on reconnect.
            try db.create(index: "idx_messages_pending", on: "messages",
                          columns: ["pending"])

            // --- call history ------------------------------------------------------
            // Did not exist in any form before: calls were live signaling only, so a
            // missed call left no trace anywhere in the app.
            try db.create(table: "call_history") { t in
                t.primaryKey("id", .text)
                t.column("conversation_id", .text)
                t.column("peer_user_id", .text)
                t.column("kind", .text).notNull().defaults(to: "voice")     // voice | video
                t.column("direction", .text).notNull()                      // incoming | outgoing
                t.column("outcome", .text).notNull().defaults(to: "missed") // answered | missed | declined | failed
                t.column("started_at", .integer).notNull()
                t.column("ended_at", .integer)
            }
            try db.create(index: "idx_calls_recent", on: "call_history",
                          columns: ["started_at"])
        }

        // Append-only: v2 adds the Stories tables. Body lives in StoriesSchema so this
        // shared file is touched by exactly one line. NEVER edit v1_core above.
        StoriesSchema.register(&m)

        // Feature (B) — the Map. Its own identified migration, appended after Stories;
        // registration order is execution order and each migration is independent, so the
        // two never collide. Body lives in Storage/MapSchema.swift.
        MapSchema.register(&m)

        // Feature (A) — location IN conversations. Its own identified migration
        // (`v2_location`), appended independently; body in Storage/LocationSchema.swift.
        LocationSchema.register(&m)

        // Denormalized last-message preview on the conversation row, so the chat LIST renders
        // instantly from SQLite alone — it never has to load or decode the message store to
        // show each chat's snippet. Kept fresh at write time (LocalStore.updatePreview).
        m.registerMigration("v3_conversation_preview") { db in
            try db.alter(table: "conversations") { t in
                t.add(column: "last_message_preview", .text)
            }
        }

        return m
    }

    // MARK: - Teardown

    /// Close the database so its files can be deleted, then reopen an EMPTY one.
    ///
    /// Deleting voiid.sqlite while the pool is open does not do what it looks like: SQLite
    /// keeps writing through its open file descriptors to the now-unlinked inode, and a
    /// checkpoint of the still-live WAL can recreate the file with the previous account's
    /// rows in it. Sign-out would appear to work and then leak data back.
    ///
    /// Releasing the pool closes every connection (GRDB closes on deallocation), so the
    /// unlink is real. We reopen immediately afterwards because the process keeps running
    /// and the next sign-in expects a working, empty database — every read path already
    /// tolerates a nil pool, but leaving it nil would silently disable local storage for
    /// the rest of the session.
    func closeForTeardown() {
        pool = nil
    }

    func reopenAfterTeardown() {
        do { pool = try Self.open() } catch {
            NSLog("[VOIID] failed to reopen local database after teardown: \(error.localizedDescription)")
            pool = nil
        }
    }

    // MARK: - Access

    /// Read helper that returns `nil` instead of throwing. Read paths feed the UI, and
    /// a transient database error should degrade a screen, never break the render.
    func read<T>(_ block: (Database) throws -> T) -> T? {
        guard let pool else { return nil }
        do { return try pool.read(block) } catch {
            NSLog("[VOIID] db read failed: \(error.localizedDescription)")
            return nil
        }
    }

    @discardableResult
    func write<T>(_ block: (Database) throws -> T) -> T? {
        guard let pool else { return nil }
        do { return try pool.write(block) } catch {
            NSLog("[VOIID] db write failed: \(error.localizedDescription)")
            return nil
        }
    }
}
