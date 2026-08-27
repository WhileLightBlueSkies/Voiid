//
//  AIStore.swift
//  Voiid
//
//  Reads and writes Voiid AI's stored conversations. Follows the `LocalStore` idiom: a
//  MainActor enum of static functions over `VoiidDatabase.shared`, with every call returning
//  a plain value and swallowing storage failure rather than throwing into the UI.
//
//  ── WHY THE HUB'S RECENT LIST IS REAL HERE, AND WAS NOT IN THE REFERENCE ────────
//  The reference app's Recent rows were sample data, and tapping one opened a blank screen —
//  it had nowhere to store a transcript, and said so. The live app has SQLite, so the rows
//  are genuine and reopen where you left off. This is the one place the port deliberately
//  does MORE than the design it came from.
//

import Foundation
import GRDB

@MainActor
enum AIStore {

    private static var db: VoiidDatabase { VoiidDatabase.shared }

    // MARK: - Threads

    /// Every stored conversation, most recently updated first — the hub's Recent list.
    ///
    /// Reads only the `ai_threads` table: title and preview are denormalized at write time,
    /// so the list never has to touch a single message row.
    static func threads(limit: Int = 50) -> [AIThread] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT id, title, preview, icon, updated_at
                  FROM ai_threads
                 ORDER BY updated_at DESC
                 LIMIT ?
                """, arguments: [limit])
        } ?? []

        return rows.compactMap { row in
            guard let id: String = row["id"] else { return nil }
            let updated: Int64 = row["updated_at"] ?? 0
            return AIThread(
                id: id,
                title: row["title"] ?? "New conversation",
                preview: row["preview"] ?? "",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(updated)),
                icon: row["icon"] ?? "sparkles"
            )
        }
    }

    /// Every message in one thread, oldest first.
    static func messages(in threadID: String) -> [AIMessage] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT id, author, text, failure, created_at
                  FROM ai_messages
                 WHERE thread_id = ?
                 ORDER BY created_at ASC
                """, arguments: [threadID])
        } ?? []

        return rows.compactMap { row in
            guard let id: String = row["id"],
                  let rawAuthor: String = row["author"],
                  let author = AIMessage.Author(rawValue: rawAuthor) else { return nil }
            let created: Int64 = row["created_at"] ?? 0
            return AIMessage(
                id: id,
                author: author,
                text: row["text"] ?? "",
                createdAt: Date(timeIntervalSince1970: TimeInterval(created)),
                // Never restored as streaming: a reply that was mid-flight when the app died
                // is finished as far as storage is concerned, and reopening it with a live
                // cursor would show a stop button for a stream that does not exist.
                isStreaming: false,
                failure: row["failure"]
            )
        }
    }

    // MARK: - Writing

    /// Writes a whole conversation in one transaction: the thread row plus its messages.
    ///
    /// REPLACE-ALL rather than a diff. A transcript is small (tens of rows), append-only in
    /// practice, and the alternative — tracking which messages are new while one of them is
    /// being mutated token by token — is a great deal of machinery to save a few writes.
    /// Called when a turn SETTLES, never per token; see `AIChatView`.
    ///
    /// An empty conversation is not stored: opening the tab, reading the hub and leaving
    /// should not litter Recent with blank rows.
    static func save(_ conversation: AIConversation) {
        let messages = conversation.messages.filter { !$0.isStreaming }
        guard !messages.isEmpty else { return }

        let id = conversation.id
        let title = conversation.derivedTitle
        let preview = conversation.derivedPreview
        let now = Int64(Date().timeIntervalSince1970)

        _ = db.write { database in
            try database.execute(sql: """
                INSERT INTO ai_threads (id, title, preview, icon, created_at, updated_at)
                VALUES (?, ?, ?, 'sparkles', ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    title = excluded.title,
                    preview = excluded.preview,
                    updated_at = excluded.updated_at
                """, arguments: [id, title, preview, now, now])

            // Clear and rewrite. Bounded by the transaction, so a crash mid-save leaves the
            // previous transcript intact rather than a half-deleted one.
            try database.execute(sql: "DELETE FROM ai_messages WHERE thread_id = ?",
                                 arguments: [id])

            for message in messages {
                try database.execute(sql: """
                    INSERT INTO ai_messages (id, thread_id, author, text, failure, created_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """, arguments: [
                        message.id, id, message.author.rawValue, message.text,
                        message.failure, Int64(message.createdAt.timeIntervalSince1970),
                    ])
            }
        }
    }

    /// Removes one conversation and, by cascade, its messages.
    static func delete(threadID: String) {
        _ = db.write { database in
            try database.execute(sql: "DELETE FROM ai_threads WHERE id = ?",
                                 arguments: [threadID])
        }
    }

    /// Removes every stored conversation. Offered in the hub's menu — an assistant that
    /// cannot be cleared is a log the user did not ask to keep.
    static func deleteAll() {
        _ = db.write { database in
            try database.execute(sql: "DELETE FROM ai_threads")
        }
    }
}
