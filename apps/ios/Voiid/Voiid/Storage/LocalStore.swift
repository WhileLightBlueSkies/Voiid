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
                       last_message_at, unread_count, last_message_preview,
                       pinned_at, starred, sort_index
                  FROM conversations
                 ORDER BY CASE WHEN pinned_at IS NULL THEN 1 ELSE 0 END,
                          pinned_at DESC,
                          CASE WHEN sort_index IS NULL THEN 1 ELSE 0 END,
                          sort_index ASC,
                          COALESCE(last_message_at, 0) DESC
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
            } else if kind == "self" {
                // BEFORE the peer branch. A self row has no peer, so without this it fell to
                // `storedTitle ?? "Unknown"` and the chat list showed "Unknown" for your own
                // notes on every cold launch.
                title = "Note to Self"
            } else if let peer = peerUserId {
                // Never fall through to the raw id — that's the UUID-on-screen bug.
                title = UserDirectory.shared.displayName(peer, fallback: storedTitle)
            } else {
                title = storedTitle ?? "Unknown"
            }

            return VConversation(
                id: id,
                // Three-way, not group/not-group. Collapsing `self` into `direct` here made
                // the chat list (which renders straight from SQLite) re-read Note to Self as
                // an ordinary chat on the next cold launch — the self short-circuit in
                // ChatStore never fired, send fell through to resolvePeer and threw 404, and
                // the top-pin was lost. `kind` is free text with no CHECK constraint, so rows
                // already written as "direct" self-heal on the next fetch-and-save.
                type: ConversationType(rawValue: kind) ?? .direct,
                title: title,
                photoName: nil,
                lastMessagePreview: row["last_message_preview"],
                // ZERO IS NOT A DATE. Rows written before the NULLIF fix below hold the
                // epoch sentinel, and every one of those installs would keep showing
                // "1 Jan 1970" until that chat next received a message. Treating 0 as
                // absent repairs them on the next read rather than on the next write.
                lastMessageAt: lastAt.flatMap { $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil },
                unreadCount: row["unread_count"] ?? 0,
                peerUserId: peerUserId,
                photoURL: row["photo_url"] ?? peerUserId.flatMap { UserDirectory.shared.photoURL($0) },
                pinnedAt: (row["pinned_at"] as Int64?).flatMap {
                    $0 > 0 ? Date(timeIntervalSince1970: TimeInterval($0)) : nil
                },
                isStarred: (row["starred"] as Int64?) == 1,
                sortIndex: row["sort_index"] as Int?
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
    private static var readPositionKey: String { "voiid.read-position.\(TokenStore.shared.userId ?? "signed-out")" }

    static func rememberReadPosition(_ id: String, through: Double) {
        var positions = UserDefaults.standard.dictionary(forKey: readPositionKey) ?? [:]
        positions[id] = max(positions[id] as? Double ?? 0, through)
        UserDefaults.standard.set(positions, forKey: readPositionKey)
        db.write { database in
            try database.execute(sql: "UPDATE conversations SET unread_count = 0 WHERE id = ?", arguments: [id])
        }
    }

    /// Pin a chat to the top of the grid, or unpin it.
    ///
    /// The timestamp is what orders multiple pins against each other; `conversations()`
    /// reads pinned rows first, newest pin highest, then everything else by recency.
    static func setPinned(_ id: String, _ pinned: Bool) {
        db.write { database in
            try database.execute(
                sql: "UPDATE conversations SET pinned_at = ? WHERE id = ?",
                arguments: [pinned ? Int64(Date().timeIntervalSince1970) : nil, id])
        }
    }

    /// Persist a manual arrangement from the grid's reorder mode.
    ///
    /// Writes the WHOLE visible order in one transaction rather than the moved tile alone.
    /// A single tile's index only means something relative to its neighbours, so a partial
    /// write would leave the rest still ordered by recency and the arrangement would come
    /// apart on the next message.
    static func setSortOrder(_ orderedIds: [String]) {
        guard !orderedIds.isEmpty else { return }
        db.write { database in
            for (index, id) in orderedIds.enumerated() {
                try database.execute(
                    sql: "UPDATE conversations SET sort_index = ? WHERE id = ?",
                    arguments: [index, id])
            }
        }
    }

    /// Set or clear one chat's manual position. Nil returns it to recency ordering.
    static func setSortIndex(_ id: String, _ index: Int?) {
        db.write { database in
            try database.execute(
                sql: "UPDATE conversations SET sort_index = ? WHERE id = ?",
                arguments: [index, id])
        }
    }

    /// Mark a chat important, or clear it. Does not affect ordering — a star is a label,
    /// and silently moving a chat because it was starred would make the grid unpredictable
    /// in exactly the way pinning is meant to be explicit about.
    static func setStarred(_ id: String, _ starred: Bool) {
        db.write { database in
            try database.execute(
                sql: "UPDATE conversations SET starred = ? WHERE id = ?",
                arguments: [starred ? 1 : 0, id])
        }
    }

    static func applyingReadPosition(_ conversation: VConversation) -> VConversation {
        var result = conversation
        let positions = UserDefaults.standard.dictionary(forKey: readPositionKey) ?? [:]
        if let through = positions[conversation.id] as? Double,
           let last = conversation.lastMessageAt, last.timeIntervalSince1970 <= through {
            result.unreadCount = 0
        }
        return result
    }

    static func saveConversations(_ convs: [VConversation]) {
        guard !convs.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        db.write { database in
            for c in convs.map(applyingReadPosition) {
                try database.execute(sql: """
                    INSERT INTO conversations
                        (id, kind, title, peer_user_id, photo_url, last_message_at, unread_count, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        kind            = excluded.kind,
                        title           = COALESCE(excluded.title, conversations.title),
                        peer_user_id    = COALESCE(excluded.peer_user_id, conversations.peer_user_id),
                        photo_url       = COALESCE(excluded.photo_url, conversations.photo_url),
                        -- NULLIF around MAX, because COALESCE(...,0) writes the SENTINEL
                        -- back into the column. When both sides are null — a chat with no
                        -- messages yet — MAX(0, 0) stored 0, which the reader faithfully
                        -- renders as "1 Jan 1970" on the tile. The zeros exist only so MAX
                        -- can ignore a null; NULLIF turns the all-null result back into
                        -- null instead of persisting epoch.
                        last_message_at = NULLIF(MAX(COALESCE(excluded.last_message_at, 0),
                                                     COALESCE(conversations.last_message_at, 0)), 0),
                        unread_count    = excluded.unread_count,
                        updated_at      = excluded.updated_at
                    """, arguments: [
                        c.id,
                        c.type.rawValue,
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

    /// The NEWEST page of a conversation, returned oldest-first for rendering (I01).
    ///
    /// THE BUG THIS FIXES: this was `ORDER BY created_at ASC LIMIT 500`, which takes the
    /// 500 **oldest** messages. On a 10,000-message history that returns the beginning of
    /// the conversation and never the recent part — the user opens a chat and sees messages
    /// from months ago, with no way to page forward to the present.
    ///
    /// The fix orders DESC to select the newest page, then reverses for display. Note the
    /// ordering is on `(created_at, id)`, not `created_at` alone: a fan-out send writes its
    /// rows in one transaction and a burst lands inside the same second, so `created_at` is
    /// not unique and a page boundary falling inside such a group would otherwise skip or
    /// repeat rows — the same defect M04 fixed on the server.
    static func latestMessages(conversationId: String, limit: Int = 50) -> [DecryptedMessage] {
        db.read { database -> [DecryptedMessage] in
            let rows = try Row.fetchAll(database, sql: """
                SELECT * FROM messages
                 WHERE conversation_id = ?
                 ORDER BY created_at DESC, id DESC
                 LIMIT ?
                """, arguments: [conversationId, limit])
            return rows.compactMap(decode).reversed()
        } ?? []
    }

    /// The page of messages immediately OLDER than `before` — scrolling up.
    ///
    /// A keyset cursor on the `(created_at, id)` tuple rather than an OFFSET: an offset
    /// walks and discards every row it skips, so page N costs O(N × pageSize), and it
    /// silently shifts when a message arrives while the user is reading.
    static func messagesBefore(conversationId: String,
                               createdAt: Date,
                               id: String,
                               limit: Int = 50) -> [DecryptedMessage] {
        let ts = Int64(createdAt.timeIntervalSince1970)
        return db.read { database -> [DecryptedMessage] in
            let rows = try Row.fetchAll(database, sql: """
                SELECT * FROM messages
                 WHERE conversation_id = ?
                   AND (created_at < ? OR (created_at = ? AND id < ?))
                 ORDER BY created_at DESC, id DESC
                 LIMIT ?
                """, arguments: [conversationId, ts, ts, id, limit])
            return rows.compactMap(decode).reversed()
        } ?? []
    }

    /// Oldest-first read, retained for callers that genuinely want the whole thread
    /// (export/backup). NOT for the chat UI — see `latestMessages`.
    static func messages(conversationId: String, limit: Int = 500) -> [DecryptedMessage] {
        db.read { database -> [DecryptedMessage] in
            let rows = try Row.fetchAll(database, sql: """
                SELECT * FROM messages
                 WHERE conversation_id = ?
                 ORDER BY created_at ASC, id ASC
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

    private static let callWriteLock = NSRecursiveLock()
    private static var pendingCallKey: String { "voiid.pending-calls.\(TokenStore.shared.userId ?? "signed-out")" }
    private struct PendingCall: Codable {
        let id: String; let conversationId: String?; let peerUserId: String?
        let kind: String; let direction: String; let outcome: String
        let startedAt: Date; let endedAt: Date?; let connectedAt: Date?
    }

    static func retryPendingCalls() {
        callWriteLock.lock(); defer { callWriteLock.unlock() }
        let pending = UserDefaults.standard.dictionary(forKey: pendingCallKey) ?? [:]
        for data in pending.values {
            guard let data = data as? Data,
                  let call = try? JSONDecoder().decode(PendingCall.self, from: data) else { continue }
            recordCall(id: call.id, conversationId: call.conversationId, peerUserId: call.peerUserId,
                kind: call.kind, direction: call.direction, outcome: call.outcome,
                startedAt: call.startedAt, endedAt: call.endedAt, connectedAt: call.connectedAt)
        }
    }

    @MainActor private static var recoveringCalls = false
    @MainActor private static var lastCallRecovery: [String: Date] = [:]
    @MainActor static func recoverMissedCalls() async {
        retryPendingCalls()
        guard !recoveringCalls, let account = TokenStore.shared.userId else { return }
        if let last = lastCallRecovery[account], Date().timeIntervalSince(last) < 60 { return }
        recoveringCalls = true; defer { recoveringCalls = false }
        struct Wire: Decodable {
            let id: String; let conversation_id: String; let peer_user_id: String
            let kind: String; let started_at: Date; let ended_at: Date
        }
        struct Page: Decodable { let calls: [Wire]; let next_cursor: String? }
        var cursor: String?
        do {
            repeat {
                let suffix = cursor.map { "?cursor=\($0)" } ?? ""
                let page = try await APIClient().request("GET", "calls/history/missed\(suffix)", as: Page.self)
                guard TokenStore.shared.userId == account else { return }
                let clearedThrough = UserDefaults.standard.double(forKey: "voiid.calls-cleared.\(account)")
                for call in page.calls {
                    if call.started_at.timeIntervalSince1970 <= clearedThrough { continue }
                    // Existing local outcomes (answered, declined, taken elsewhere) win.
                    let committed = db.writeCommitted { database in
                        try database.execute(sql: """
                            INSERT OR IGNORE INTO call_history
                              (id,conversation_id,peer_user_id,kind,direction,outcome,started_at,ended_at)
                            VALUES (?,?,?,?,'incoming','missed',?,?)
                            """, arguments: [call.id,call.conversation_id,call.peer_user_id,call.kind,
                                Int64(call.started_at.timeIntervalSince1970),Int64(call.ended_at.timeIntervalSince1970)])
                    }
                    guard committed else { return } // no page is acknowledged on failure
                }
                NotificationCenter.default.post(name: callHistoryDidChange, object: nil)
                cursor = page.next_cursor
            } while cursor != nil && !Task.isCancelled
            if !Task.isCancelled { lastCallRecovery[account] = Date() }
        } catch { NSLog("[VOIID] missed-call recovery will retry: \(error.localizedDescription)") }
    }

    static let callHistoryDidChange = Notification.Name("VoiidCallHistoryDidChange")

    @discardableResult
    static func recordCall(id: String, conversationId: String?, peerUserId: String?,
                           kind: String, direction: String, outcome: String,
                           startedAt: Date, endedAt: Date? = nil, connectedAt: Date? = nil) -> Bool {
        callWriteLock.lock(); defer { callWriteLock.unlock() }
        let key = pendingCallKey
        var pending = UserDefaults.standard.dictionary(forKey: key) ?? [:]
        let incoming = PendingCall(id: id, conversationId: conversationId, peerUserId: peerUserId,
            kind: kind, direction: direction, outcome: outcome,
            startedAt: startedAt, endedAt: endedAt, connectedAt: connectedAt)
        // Preserve a final failed write when a delayed provisional write arrives.
        if let data = pending[id] as? Data,
           let previous = try? JSONDecoder().decode(PendingCall.self, from: data),
           previous.endedAt != nil && endedAt == nil {
            return recordCall(id: previous.id, conversationId: previous.conversationId,
                peerUserId: previous.peerUserId, kind: previous.kind, direction: previous.direction,
                outcome: previous.outcome, startedAt: previous.startedAt,
                endedAt: previous.endedAt, connectedAt: previous.connectedAt)
        }
        pending[id] = try? JSONEncoder().encode(incoming)
        UserDefaults.standard.set(pending, forKey: key)
        let committed = db.writeCommitted { database in
            try database.execute(sql: """
                INSERT INTO call_history
                    (id, conversation_id, peer_user_id, kind, direction, outcome, started_at, ended_at, connected_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    outcome = CASE WHEN excluded.ended_at IS NULL AND call_history.ended_at IS NOT NULL
                                   THEN call_history.outcome ELSE excluded.outcome END,
                    started_at = MIN(call_history.started_at, excluded.started_at),
                    connected_at = COALESCE(call_history.connected_at, excluded.connected_at),
                    ended_at = COALESCE(excluded.ended_at, call_history.ended_at),
                    conversation_id = COALESCE(call_history.conversation_id, excluded.conversation_id),
                    peer_user_id = COALESCE(call_history.peer_user_id, excluded.peer_user_id)
                """, arguments: [id, conversationId, peerUserId, kind, direction, outcome,
                                 Int64(startedAt.timeIntervalSince1970),
                                 endedAt.map { Int64($0.timeIntervalSince1970) },
                                 connectedAt.map { Int64($0.timeIntervalSince1970) }])
        }
        if committed {
            pending.removeValue(forKey: id)
            UserDefaults.standard.set(pending, forKey: key)
            NotificationCenter.default.post(name: callHistoryDidChange, object: nil)
        }
        return committed
    }

    /// One conversation's finished calls, oldest first — the transcript's call bubbles.
    ///
    /// Timestamps are stored as epoch SECONDS here while VMessage.createdAt is a Date; the
    /// conversion happens at the call site that builds the bubble.
    static func callsForConversation(_ conversationId: String) -> [CallHistoryEntry] {
        (try? db.read { database in
            try Row.fetchAll(database, sql: """
                SELECT id, kind, direction, outcome, started_at, ended_at, connected_at
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
                    endedAt: (row["ended_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    connectedAt: (row["connected_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
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
                       started_at, ended_at, connected_at
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
                    endedAt: (row["ended_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
                    connectedAt: (row["connected_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                )
            }
        }) ?? []
    }

    /// Delete every call row. Backs "Clear call history".
    static func clearCallHistory() {
        callWriteLock.lock(); defer { callWriteLock.unlock() }
        if db.writeCommitted({ database in
            try database.execute(sql: "DELETE FROM call_history")
        }) {
            UserDefaults.standard.removeObject(forKey: pendingCallKey)
            UserDefaults.standard.set(Date().timeIntervalSince1970,
                forKey: "voiid.calls-cleared.\(TokenStore.shared.userId ?? "signed-out")")
            NotificationCenter.default.post(name: callHistoryDidChange, object: nil)
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
        var connectedAt: Date? = nil

        var isVideo: Bool { kind == "video" }
        var incoming: Bool { direction == "incoming" }
        /// Missed means it RANG and was never answered. A call the user declined was
        /// answered-by-a-human-decision and must not sit in the missed filter.
        var missed: Bool { incoming && outcome != "answered" && outcome != "declined" }

        /// Seconds, or nil when the call never connected.
        var duration: TimeInterval? {
            guard outcome == "answered", let endedAt else { return nil }
            return max(0, endedAt.timeIntervalSince(connectedAt ?? startedAt))
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
        var connectedAt: Date? = nil
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

        try indexMedia(m, conversationId: conversationId, mediaJSON: mediaJSON, into: database)
    }

    /// Keep `chat_media` in step with the message that produced it.
    ///
    /// Written HERE, in the one place every message lands, rather than at each call site
    /// that sends media. An index maintained by its callers drifts the first time someone
    /// adds a new send path and forgets — and a media viewer missing the photo you just sent
    /// is worse than no viewer.
    ///
    /// Only images and video are indexed. Voice notes and documents share the same media
    /// pipeline but belong to a different screen, so admitting them would put an unplayable
    /// item in the pager.
    private static func indexMedia(_ m: DecryptedMessage, conversationId: String,
                                   mediaJSON: String?, into database: Database) throws {
        guard let mediaJSON, let ref = m.media else { return }
        let kind: String
        if ref.mime.hasPrefix("image/") { kind = "image" }
        else if ref.mime.hasPrefix("video/") { kind = "video" }
        else { return }

        // The caption rides in the message body for media messages. Empty is stored as NULL
        // so the viewer's caption bar can test for presence rather than for emptiness.
        let caption = m.text.trimmingCharacters(in: .whitespacesAndNewlines)

        try database.execute(sql: """
            INSERT INTO chat_media
                (message_id, chat_id, type, media_json, sent_at, sender_id, is_outgoing, caption)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(message_id) DO UPDATE SET
                caption    = excluded.caption,
                media_json = excluded.media_json
            """, arguments: [
                m.id, conversationId, kind, mediaJSON,
                Int64(m.createdAt.timeIntervalSince1970), m.senderId, m.isMine,
                caption.isEmpty ? nil : caption,
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
