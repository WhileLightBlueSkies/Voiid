//
//  LocationSchema.swift
//  Voiid
//
//  Location's local tables, registered as a SEPARATE GRDB migration so the shared
//  `VoiidDatabase.swift` edit is a single line: `LocationSchema.register(&m)`, called
//  after the `v1_core` closure and before `return m`.
//
//  Migrations are append-only and registration order IS execution order; GRDB records
//  the applied identifiers, so `v1_core` never replays and an existing install only runs
//  `v2_location`. This mirrors the Android side's mandatory additive Migration(1,2).
//
//  The server stores almost nothing (only "a share exists between A and B until T");
//  EVERYTHING else lives here, on the client. No coordinate history is ever kept: the
//  last-fix table holds exactly one row per (share, sender), overwritten in place.
//
//  This migration owns ONLY the conversation-share substrate (feature A). The Map
//  (feature B) ships its own `map_v1_presence` migration in Storage/MapSchema.swift with
//  the `map_audience` / `map_presence` tables, so nothing here touches those.
//

import Foundation
import GRDB

enum LocationSchema {
    /// Append the `v2_location` migration. Additive only — it creates new tables and
    /// indices and touches nothing in `v1_core`.
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("v2_location") { db in
            // --- location_shares ---------------------------------------------------
            // One row per share this device knows about, inbound OR outbound. Columns
            // hold epoch SECONDS (the LocalStore boundary convention); models carry
            // millis. `state` is a cached label; the authoritative state is always
            // re-derived from `expires_at` at read time.
            try db.create(table: "location_shares", ifNotExists: true) { t in
                t.primaryKey("id", .text)
                t.column("kind", .text).notNull().defaults(to: "conversation")   // conversation | map
                t.column("direction", .text).notNull()                           // out | in
                t.column("conversation_id", .text)
                t.column("peer_user_id", .text)                                  // owner (inbound) / n/a (outbound)
                t.column("started_at", .integer).notNull().defaults(to: 0)
                t.column("expires_at", .integer).notNull().defaults(to: 0)
                t.column("ended_at", .integer)
                t.column("cadence_seconds", .integer).notNull().defaults(to: 15)
                t.column("state", .text).notNull().defaults(to: "live")
            }
            try db.create(index: "idx_location_shares_active", on: "location_shares",
                          columns: ["direction", "ended_at", "expires_at"])

            // --- location_share_targets (outbound only) ----------------------------
            try db.create(table: "location_share_targets", ifNotExists: true) { t in
                t.column("share_id", .text).notNull()
                t.column("user_id", .text).notNull()
                t.column("revoked_at", .integer)
                t.primaryKey(["share_id", "user_id"])
            }

            // --- location_last_fix -------------------------------------------------
            // EXACTLY one row per (share, sender), overwritten in place. No history, no
            // trail, ever (docs/LOCATION.md §6). A live marker is drawn from here.
            try db.create(table: "location_last_fix", ifNotExists: true) { t in
                t.column("share_id", .text).notNull()
                t.column("sender_user_id", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("acc", .double)
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("fixed_at", .integer).notNull().defaults(to: 0)   // epoch seconds
                t.primaryKey(["share_id", "sender_user_id"])
            }
        }

        // Whether an OUTBOUND share was started in a group. Not inferable after a cold
        // start: the resume path guessed "more than one recipient means group", so a group
        // of exactly two resumed as a 1:1 and sent its durable `live_stop` down the 1:1
        // Double Ratchet addressed with the GROUP's conversation id — a ratchet message into
        // an MLS conversation, which is simply lost. Defaults to false so every pre-existing
        // row keeps the behaviour it already had.
        m.registerMigration("v4_location_is_group") { db in
            try db.alter(table: "location_shares") { t in
                t.add(column: "is_group", .boolean).notNull().defaults(to: false)
            }
        }
    }
}
