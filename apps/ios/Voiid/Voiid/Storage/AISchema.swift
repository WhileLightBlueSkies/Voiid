//
//  AISchema.swift
//  Voiid
//
//  Voiid AI's local tables, registered as a SEPARATE GRDB migration so the shared
//  `VoiidDatabase.swift` edit is a single line: `AISchema.register(&m)`.
//
//  Migrations are append-only and registration order IS execution order; GRDB records the
//  applied identifiers, so an existing install only runs `ai_v1_threads`.
//
//  ── DEVICE-ONLY, AND NEVER SYNCED ───────────────────────────────────────────────
//  These rows are the most sensitive thing the app stores that the SERVER has never seen:
//  the model runs on-device, so a Voiid AI transcript exists in exactly one place. It is
//  therefore deliberately NOT part of backup, not part of multi-device linking, and not
//  fanned out. Sign-out drops it with the rest of the database.
//

import Foundation
import GRDB

enum AISchema {
    /// Append the `ai_v1_threads` migration. Additive only.
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("ai_v1_threads") { db in
            // --- ai_threads --------------------------------------------------------
            // One row per conversation with the assistant. `title` and `preview` are
            // denormalized so the hub's Recent list renders from this table alone and
            // never has to load a single message.
            try db.create(table: "ai_threads", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull().defaults(to: "")
                t.column("preview", .text).notNull().defaults(to: "")
                t.column("icon", .text).notNull().defaults(to: "sparkles")
                t.column("created_at", .integer).notNull().defaults(to: 0)
                t.column("updated_at", .integer).notNull().defaults(to: 0)
            }
            // The only query the hub makes: most recent first.
            try db.create(index: "idx_ai_threads_recent", on: "ai_threads",
                          columns: ["updated_at"])

            // --- ai_messages -------------------------------------------------------
            // `author` is "user" | "assistant". A failed turn is stored with its reason
            // in `failure` and an empty body, so reopening a thread shows the same honest
            // error rather than a blank bubble that looks like a lost message.
            //
            // ON DELETE CASCADE: deleting a thread must not strand its messages, and the
            // hub offers exactly that via swipe-to-delete.
            try db.create(table: "ai_messages", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("thread_id", .text).notNull()
                    .references("ai_threads", onDelete: .cascade)
                t.column("author", .text).notNull()
                t.column("text", .text).notNull().defaults(to: "")
                t.column("failure", .text)
                t.column("created_at", .integer).notNull().defaults(to: 0)
            }
            // The hot query is "every message in this thread, oldest first".
            try db.create(index: "idx_ai_messages_thread", on: "ai_messages",
                          columns: ["thread_id", "created_at"])
        }
    }
}
