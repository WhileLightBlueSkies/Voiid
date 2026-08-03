//
//  LocalStore.swift
//  Voiid
//
//  Disk persistence for conversations, messages and call history, plus the one-time
//  import of the legacy app-group JSON message blob.
//
//  READ PATH (the point of all this): the UI asks LocalStore first and renders
//  immediately, then a network sync updates the database and the UI follows. A failed
//  fetch is therefore invisible — you keep seeing your chats. Before this, the
//  conversation list existed ONLY as the response body of a GET, so airplane mode (or
//  one 500) produced an empty grid on top of a full local message history.
//
//  WRITE PATH: local write first, network second. A message typed offline is already
//  durable before the request is attempted, so it survives a restart and is retried.
//

import Foundation
import GRDB

@MainActor
enum LocalStore {

    private static var db: VoiidDatabase { VoiidDatabase.shared }

    // MARK: - Conversations

    /// Every conversation we know about locally, newest activity first.
    ///
    /// Direct-chat titles are resolved through `UserDirectory` at READ time rather
    /// than being stored: the address book is the authority for what a person is
    /// called, and resolving late means renaming a contact updates every screen
    /// without a re-sync or a stale denormalized copy.
    static func conversations() -> [VConversation] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT id, kind, title, peer_user_id, photo_url,
                       last_message_at, unread_count, last_message_preview
                  FROM conversations
                 ORDER BY COALESCE(last_message_at, 0) DESC
                """)
        } ?? []

        return rows.map { row in
            let id: String = row["id"]
            let kind: String = row["kind"] ?? "direct"
            let peerUserId: String? = row["peer_user_id"]
            let storedTitle: String? = row["title"]
            let lastAt: Int64? = row["last_message_at"]

            let title: String
            if kind == "group" {
                title = storedTitle?.isEmpty == false ? storedTitle! : "Group"
            } else if let peer = peerUserId {
                // Never fall through to the raw id — that's the UUID-on-screen bug.
                title = UserDirectory.shared.displayName(peer, fallback: storedTitle)
            } else {
                title = storedTitle ?? "Unknown"
            }

            return VConversation(
                id: id,
                type: kind == "group" ? .group : .direct,
                title: title,
                photoName: nil,
                lastMessagePreview: row["last_message_preview"],
                lastMessageAt: lastAt.map { Date(timeIntervalSince1970: TimeInterval($0)) },
                unreadCount: row["unread_count"] ?? 0,
                peerUserId: peerUserId,
                photoURL: row["photo_url"] ?? peerUserId.flatMap { UserDirectory.shared.photoURL($0) }
            )
        }
    }

    /// Persist a server sync result.
    ///
    /// Deliberately an UPSERT and not a replace-all: rows the server omits (a
    /// conversation created offline and not yet pushed) must survive.
    ///
    /// `unread_count` IS overwritten from the server, on purpose: read state has to
    /// converge across a user's devices, and the server is the only party that sees
    /// all of them. The cost is that reading a chat on your phone zeroes the badge
    /// here on the next sync, which is the behaviour you want.
    static func saveConversations(_ convs: [VConversation]) {
        guard !convs.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        db.write { database in
            for c in convs {
                try database.execute(sql: """
                    INSERT INTO conversations
                        (id, kind, title, peer_user_id, photo_url, last_message_at, unread_count, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind            = excluded.kind,
                        title           = COALESCE(excluded.title, conversations.title),
                        peer_user_id    = COALESCE(excluded.peer_user_id, conversations.peer_user_id),
                        photo_url       = COALESCE(excluded.photo_url, conversations.photo_url),
                        last_message_at = MAX(COALESCE(excluded.last_message_at, 0),
                                              COALESCE(conversations.last_message_at, 0)),
                        unread_count    = excluded.unread_count,
                        updated_at      = excluded.updated_at
                    """, arguments: [
                        c.id,
                        c.type == .group ? "group" : "direct",
                        c.title,
                        c.peerUserId,
                        c.photoURL,
                        c.lastMessageAt.map { Int64($0.timeIntervalSince1970) },
                        c.unreadCount,
                        now,
                    ])
            }
        }
    }

    /// Insert a conversation created on this device, before the server knows about it.
    static func upsertConversation(_ c: VConversation) { saveConversations([c]) }

    /// Denormalize the latest message's preview + time onto the conversation row, so the chat
    /// LIST can render each chat's snippet and order WITHOUT loading the message store. Called
    /// at message write time. `at` also bumps `last_message_at` (never backwards) so the list
    /// re-sorts. A row that doesn't exist yet is created (a message can arrive before the
    /// conversation sync does). Empty/whitespace previews are ignored (e.g. media/control).
    static func updatePreview(conversationId: String, preview: String, at date: Date) {
        guard !conversationId.isEmpty else { return }
        let ts = Int64(date.timeIntervalSince1970)
        db.write { database in
            try database.execute(sql: """
                INSERT INTO conversations (id, kind, last_message_at, last_message_preview, updated_at)
                VALUES (?, 'direct', ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    last_message_preview = excluded.last_message_preview,
                    last_message_at      = MAX(COALESCE(excluded.last_message_at, 0),
                                               COALESCE(conversations.last_message_at, 0)),
                    updated_at           = excluded.updated_at
                """, arguments: [conversationId, ts, preview, ts])
        }
    }

    /// The direct conversation with a peer, if we have one.
    ///
    /// The call paths need this because they are handed a USER id and everything
    /// downstream of a call — `POST /calls/ring`, notification threading, the tap
    /// deep-link — is keyed by CONVERSATION id. Resolving it locally means a call
    /// placed from Recents or a Siri intent (which know nothing about conversations)
    /// still carries one.
    static func conversationId(forPeer peerUserId: String) -> String? {
        guard !peerUserId.isEmpty else { return nil }
        return db.read { database -> String? in
            try String.fetchOne(database, sql: """
                SELECT id FROM conversations
                 WHERE peer_user_id = ? AND kind = 'direct'
                 ORDER BY COALESCE(last_message_at, 0) DESC
                 LIMIT 1
                """, arguments: [peerUserId])
        } ?? nil
    }

    // MARK: - Messages

    static func messages(conversationId: String, limit: Int = 500) -> [DecryptedMessage] {
        db.read { database -> [DecryptedMessage] in
            let rows = try Row.fetchAll(database, sql: """
                SELECT * FROM messages
                 WHERE conversation_id = ?
                 ORDER BY created_at ASC
                 LIMIT ?
                """, arguments: [conversationId, limit])
            return rows.compactMap(decode)
        } ?? []
    }

    /// Everything still waiting to reach the server, oldest first — the outbox.
    /// Drives the flush on reconnect.
    static func pendingMessages() -> [(conversationId: String, message: DecryptedMessage)] {
        db.read { database -> [(String, DecryptedMessage)] in
            let rows = try Row.fetchAll(database, sql: """
                SELECT * FROM messages WHERE pending = 1 ORDER BY created_at ASC
                """)
            return rows.compactMap { row in
                guard let m = decode(row) else { return nil }
                let convId: String = row["conversation_id"]
                return (convId, m)
            }
        } ?? []
    }

    static func saveMessages(_ messages: [DecryptedMessage], conversationId: String) {
        guard !messages.isEmpty else { return }
        db.write { database in
            for m in messages { try insert(m, conversationId: conversationId, into: database) }
        }
    }

    static func saveMessage(_ m: DecryptedMessage, conversationId: String) {
        saveMessages([m], conversationId: conversationId)
    }

    // MARK: - Call history
    //
    // New capability, not a port: calls previously left no local trace at all, so a
    // missed call was invisible once the CallKit banner went away.

    static func recordCall(id: String, conversationId: String?, peerUserId: String?,
                           kind: String, direction: String, outcome: String,
                           startedAt: Date, endedAt: Date? = nil) {
        db.write { database in
            try database.execute(sql: """
                INSERT INTO call_history
                    (id, conversation_id, peer_user_id, kind, direction, outcome, started_at, ended_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    outcome  = excluded.outcome,
                    ended_at = COALESCE(excluded.ended_at, call_history.ended_at)
                """, arguments: [id, conversationId, peerUserId, kind, direction, outcome,
                                 Int64(startedAt.timeIntervalSince1970),
                                 endedAt.map { Int64($0.timeIntervalSince1970) }])
        }
    }

    /// One conversation's finished calls, oldest first — the transcript's call bubbles.
    ///
    /// Timestamps are stored as epoch SECONDS here while VMessage.createdAt is a Date; the
    /// conversion happens at the call site that builds the bubble.
    static func callsForConversation(_ conversationId: String) -> [CallHistoryEntry] {
        (try? db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT id, kind, direction, outcome, started_at, ended_at
                  FROM call_history
                 WHERE conversation_id = ?
                 ORDER BY started_at ASC
                """, arguments: [conversationId]).map { row in
                CallHistoryEntry(
                    id: row["id"],
                    kind: row["kind"],
                    direction: row["direction"],
                    outcome: row["outcome"],
                    startedAt: Date(timeIntervalSince1970: TimeInterval(row["started_at"] as Int64)),
                    endedAt: (row["ended_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }) ?? []
    }

    /// EVERY call, newest first — the Recents screen.
    ///
    /// A separate query from `callsForConversation` rather than a filter over it: that one is
    /// keyed on a conversation and ordered ASC for the transcript, and this needs neither.
    /// It also carries `conversationId` and `peerUserId`, which the per-chat query drops
    /// because the caller already knows them — here they are what lets a row open a chat or
    /// place a call back.
    ///
    /// Capped at 500. A call log is read from the top; nobody scrolls to their thousandth
    /// call, and an unbounded query on a chatty account would decode the lot to draw a screen
    /// of twenty rows.
    static func allCalls(limit: Int = 500) -> [CallLogEntry] {
        (try? db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT id, conversation_id, peer_user_id, kind, direction, outcome,
                       started_at, ended_at
                  FROM call_history
                 ORDER BY started_at DESC
                 LIMIT ?
                """, arguments: [limit]).map { row in
                CallLogEntry(
                    id: row["id"],
                    conversationId: row["conversation_id"],
                    peerUserId: row["peer_user_id"],
                    kind: row["kind"],
                    direction: row["direction"],
                    outcome: row["outcome"],
                    startedAt: Date(timeIntervalSince1970: TimeInterval(row["started_at"] as Int64)),
                    endedAt: (row["ended_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }) ?? []
    }

    /// Delete every call row. Backs "Clear call history".
    static func clearCallHistory() {
        db.write { database in
            try database.execute(sql: "DELETE FROM call_history")
        }
    }

    /// A row of the global call log. Distinct from [CallHistoryEntry] because it carries the
    /// conversation and peer the transcript version does not need.
    struct CallLogEntry: Identifiable {
        let id: String
        let conversationId: String?
        let peerUserId: String?
        let kind: String        // voice | video
        let direction: String   // incoming | outgoing
        let outcome: String     // answered | missed | declined | failed
        let startedAt: Date
        let endedAt: Date?

        var isVideo: Bool { kind == "video" }
        var incoming: Bool { direction == "incoming" }
        /// Missed means it RANG and was never answered. A call the user declined was
        /// answered-by-a-human-decision and must not sit in the missed filter.
        var missed: Bool { incoming && outcome != "answered" && outcome != "declined" }

        /// Seconds, or nil when the call never connected.
        var duration: TimeInterval? {
            guard outcome == "answered", let endedAt else { return nil }
            return max(0, endedAt.timeIntervalSince(startedAt))
        }
    }

    /// A row of `call_history`, as read back for the transcript.
    struct CallHistoryEntry: Identifiable {
        let id: String
        let kind: String        // voice | video
        let direction: String   // incoming | outgoing
        let outcome: String     // answered | missed | declined | failed
        let startedAt: Date
        let endedAt: Date?
    }

    // MARK: - Legacy import
    //
    // The previous store was `[conversationId: [DecryptedMessage]]` in one JSON file
    // in the App Group. Import it once, then leave the file alone (do not delete it):
    // if a build has to be rolled back, the old code still finds its history.

    private static let importFlagKey = "voiid.localstore.imported_message_blob_v1"

    static func importLegacyMessageBlobIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: importFlagKey) else { return }
        guard let url = AppGroup.messageStoreURL ?? legacyBlobURL(),
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [DecryptedMessage]].self, from: data)
        else {
            // Nothing to import (fresh install) — still flag it, so we don't re-stat
            // the filesystem on every launch forever.
            UserDefaults.standard.set(true, forKey: importFlagKey)
            return
        }

        var imported = 0
        db.write { database in
            for (convId, messages) in decoded {
                // A conversation row must exist for the messages to be reachable —
                // this is exactly the gap that hid history behind an empty grid.
                try database.execute(sql: """
                    INSERT INTO conversations (id, kind, last_message_at, updated_at)
                    VALUES (?, 'direct', ?, ?)
                    ON CONFLICT(id) DO NOTHING
                    """, arguments: [
                        convId,
                        messages.map { Int64($0.createdAt.timeIntervalSince1970) }.max() ?? 0,
                        Int64(Date().timeIntervalSince1970),
                    ])
                for m in messages {
                    try insert(m, conversationId: convId, into: database)
                    imported += 1
                }
            }
        }
        UserDefaults.standard.set(true, forKey: importFlagKey)
        NSLog("[VOIID] imported \(imported) messages from the legacy blob into SQLite")
    }

    private static func legacyBlobURL() -> URL? {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = dir.appendingPathComponent("voiid_messages.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: - Row mapping

    private static func insert(_ m: DecryptedMessage, conversationId: String,
                               into database: Database) throws {
        let mediaJSON = m.media.flatMap { try? JSONEncoder().encode($0) }
            .flatMap { String(data: $0, encoding: .utf8) }
        try database.execute(sql: """
            INSERT INTO messages
                (id, conversation_id, sender_id, text, created_at, is_mine,
                 pending, failed, server_id, delivery_status, media_json)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                text            = excluded.text,
                pending         = excluded.pending,
                failed          = excluded.failed,
                server_id       = COALESCE(excluded.server_id, messages.server_id),
                -- Delivery state only ever moves FORWARD. A late re-sync of an older
                -- payload must not drag a "read" message back to "sent".
                delivery_status = CASE
                    WHEN messages.delivery_status = 'read' THEN 'read'
                    WHEN messages.delivery_status = 'delivered'
                         AND excluded.delivery_status = 'sent' THEN 'delivered'
                    ELSE COALESCE(excluded.delivery_status, messages.delivery_status)
                END,
                media_json      = COALESCE(excluded.media_json, messages.media_json)
            """, arguments: [
                m.id, conversationId, m.senderId, m.text,
                Int64(m.createdAt.timeIntervalSince1970), m.isMine,
                m.pending, m.failed, m.serverId, m.deliveryStatus, mediaJSON,
            ])
    }

    private static func decode(_ row: Row) -> DecryptedMessage? {
        guard let id: String = row["id"], let senderId: String = row["sender_id"] else { return nil }
        let createdAt: Int64 = row["created_at"] ?? 0
        var media: MediaRef?
        if let json: String = row["media_json"], let data = json.data(using: .utf8) {
            media = try? JSONDecoder().decode(MediaRef.self, from: data)
        }
        return DecryptedMessage(
            id: id,
            senderId: senderId,
            text: row["text"] ?? "",
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            isMine: row["is_mine"] ?? false,
            media: media,
            pending: row["pending"] ?? false,
            serverId: row["server_id"],
            deliveryStatus: row["delivery_status"],
            failed: row["failed"] ?? false
        )
    }
}
