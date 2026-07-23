//
//  MapSchema.swift
//  Voiid
//
//  Local schema for Feature (B) — The Map. Registered as one append-only GRDB migration
//  from `VoiidDatabase.migrator`, AFTER the `v1_core` closure. Migrations are append-only
//  and GRDB records applied identifiers, so `v1_core` never replays and this one runs
//  exactly once per install.
//
//  WHY ITS OWN MIGRATION (and its own tables) rather than the shared conversation-share
//  tables: the in-conversation live-share workstream (Feature (A)) owns `location_shares`
//  / `location_share_targets` / `location_last_fix`. The Map keeps a strictly separate,
//  narrower footprint — an allow-list and a single latest fix per contact — so the two
//  features can ship independently without either owning the other's rows. Distinct
//  migration identifier ⇒ no collision with (A)'s registration.
//
//  WHAT IS DELIBERATELY NOT HERE: no fix history, no trail, no "seen count", no key. The
//  share key lives in the Keychain (MapKeyStore), never in SQLite. Exactly one presence
//  row per contact, overwritten in place — a replayed trail is worse than useless (§8/§10).
//

import Foundation
import GRDB

enum MapSchema {
    /// Append this migration to the shared migrator. Called from `VoiidDatabase.migrator`
    /// with a single line, after `v1_core` and before `return m`.
    static func register(_ m: inout DatabaseMigrator) {
        m.registerMigration("map_v1_presence") { db in
            // --- map_audience ------------------------------------------------------
            // The (B) allow-list: one row per person you have explicitly chosen to be
            // visible to. Empty by default; grows only by per-contact selection. Stored as
            // individuals even when picked via a group (see MapModels), so leaving a group
            // never silently keeps someone here.
            try db.create(table: "map_audience") { t in
                t.primaryKey("user_id", .text)
                t.column("added_at", .integer).notNull().defaults(to: 0)
            }

            // --- map_presence ------------------------------------------------------
            // A contact currently visible TO you. EXACTLY ONE row per sender, overwritten
            // in place on every fix — never a queue, never a history. `fixed_at` alone
            // drives the live/stale/aged-out render, so a dead sender ages out with no
            // network. A `map_off` DELETEs the row (erasing the last position); an age-out
            // keeps it (so "phone dead" stays distinguishable from "turned it off").
            try db.create(table: "map_presence", ifNotExists: true) { t in
                t.primaryKey("sender_user_id", .text)
                t.column("share_id", .text).notNull()
                t.column("lat", .double).notNull()
                t.column("lon", .double).notNull()
                t.column("acc", .double).notNull().defaults(to: 0)
                t.column("seq", .integer).notNull().defaults(to: 0)
                t.column("fixed_at", .integer).notNull()   // epoch SECONDS (LocalStore boundary)
            }
        }
    }
}
