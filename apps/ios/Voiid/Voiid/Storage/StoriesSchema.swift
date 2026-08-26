//
//  StoriesSchema.swift
//  Voiid
//
//  The v2_stories GRDB migration, kept OUT of VoiidDatabase.swift so the shared file
//  is touched by exactly one line (`StoriesSchema.register(&m)`). Migrations are
//  append-only: this runs AFTER v1_core and NEVER edits it.
//
//  Stories are the first genuinely expiring content the app holds — the first table
//  that legitimately supports a TTL sweep (see StoryStore.sweepExpired). Everything
//  here is local-only mirror state; the media KEY and the decrypted bytes never live
//  in a column. Decrypted plaintext goes to a file in the app-group Caches dir
//  (`local_path`), never the DB and never voiid_messages.json — putting large blobs
//  in the message store would rewrite the user's whole chat history on every append.
//
//  Timestamps are epoch SECONDS to match v1_core (the messages table stores seconds).
//

import Foundation
import GRDB

enum StoriesSchema {

    /// Register the stories tables on the shared migrator. Called once, from
    /// `VoiidDatabase.migrator`, between the v1_core closure and `return m`.
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2_stories") { db in

            // --- stories -------------------------------------------------------
            // One row per story we know about, ours or a contact's. `media_json`
            // is the same MediaRef Codable convention as messages.media_json —
            // it carries the object key + media key needed to fetch & decrypt.
            // `viewed_at` is this device's seen state and is NEVER transmitted;
            // it drives the seen/unseen ring only. `local_path` points at the
            // decrypted plaintext file in Caches once downloaded.
            try db.create(table: "stories") { t in
                t.primaryKey("id", .text)                       // server story_id (client-minted uuid)
                t.column("author_id", .text).notNull()
                t.column("author_device_id", .text)
                t.column("is_mine", .boolean).notNull().defaults(to: false)
                t.column("created_at", .integer).notNull()      // epoch seconds
                t.column("expires_at", .integer).notNull()      // epoch seconds
                t.column("media_json", .text).notNull()         // MediaRef JSON
                t.column("caption", .text).notNull().defaults(to: "")
                t.column("duration_ms", .integer)               // video only
                t.column("width", .integer)
                t.column("height", .integer)
                t.column("allows_replies", .boolean).notNull().defaults(to: true)
                t.column("viewed_at", .integer)                 // NULL = unseen; local only
                t.column("local_path", .text)                   // decrypted plaintext file
                t.column("download_state", .text).notNull().defaults(to: "none")
            }
            // Tray grouping: an author's stories, newest first.
            try db.create(index: "idx_stories_author_created", on: "stories",
                          columns: ["author_id", "created_at"])
            // Drives the local expiry sweep.
            try db.create(index: "idx_stories_expires", on: "stories",
                          columns: ["expires_at"])

            // --- story_audience ------------------------------------------------
            // AUTHOR-SIDE ONLY. Who we sent a given story to. Never leaves this
            // device (the server learns the audience from story_keys anyway, but
            // this local copy drives reply validation §5.4 and receipt decryption).
            try db.create(table: "story_audience") { t in
                t.column("story_id", .text).notNull()
                t.column("user_id", .text).notNull()
                t.primaryKey(["story_id", "user_id"])
            }

            // --- story_views ---------------------------------------------------
            // AUTHOR-SIDE ONLY, built from decrypted view receipts. The viewer
            // list the author sees, synced across the author's linked devices for
            // free because receipts fan out to all author devices.
            try db.create(table: "story_views") { t in
                t.column("story_id", .text).notNull()
                t.column("viewer_user_id", .text).notNull()
                t.column("viewed_at", .integer).notNull()       // epoch seconds
                t.primaryKey(["story_id", "viewer_user_id"])
            }
        }

        // --- v3_story_archive ------------------------------------------------
        // Append-only, per the rule at the top of this file: v2_stories above is
        // never edited.
        //
        // Archiving is AUTHOR-ONLY and that is a privacy decision, not a
        // limitation. A moment's promise is "these people, 24 hours"; the keys
        // expire with it. Keeping the VIEWER's copy alive past expiry would
        // quietly retract that promise for content someone else authored, so
        // only `is_mine` rows are ever spared by the sweep.
        //
        // No new blob is written: `postStory` already caches the plaintext it
        // just encrypted (StoryEngine, "Optimistic local row"), so archiving is
        // purely a decision NOT to delete that file. Nothing extra is uploaded
        // and the server is not involved — an archived moment is local to the
        // author's device.
        m.registerMigration("v3_story_archive") { db in
            try db.alter(table: "stories") { t in
                // NULL = not archived. Set to epoch seconds when the author keeps it.
                t.add(column: "archived_at", .integer)
            }
            // The archive grid reads "mine, archived, newest first".
            try db.create(index: "idx_stories_archived", on: "stories",
                          columns: ["archived_at"])
        }
    }
}
