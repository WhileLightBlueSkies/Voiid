//
//  MapPresenceStore.swift
//  Voiid
//
//  Local-first persistence for Feature (B). Raw SQL over the shared `VoiidDatabase` pool,
//  the same idiom as `LocalStore` — the UI reads from HERE and renders immediately, then a
//  fetch updates the database and the UI follows. A failed sync is invisible.
//
//  Epoch SECONDS on disk (the `LocalStore` boundary convention); the models above hold
//  `Date`. Cross that boundary in exactly these functions so timestamps are never off by
//  1000×.
//

import Foundation
import CoreLocation
import GRDB

@MainActor
enum MapPresenceStore {

    private static var db: VoiidDatabase { VoiidDatabase.shared }

    // MARK: - Audience (the allow-list)

    /// Everyone you are currently visible to, most-recently-added first.
    static func audience() -> [MapAudienceMember] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT user_id, added_at FROM map_audience ORDER BY added_at DESC
                """)
        } ?? []
        return rows.map { row in
            let userId: String = row["user_id"]
            let addedAt: Int64 = row["added_at"] ?? 0
            return MapAudienceMember(userId: userId,
                                     addedAt: Date(timeIntervalSince1970: TimeInterval(addedAt)))
        }
    }

    static func audienceIds() -> Set<String> { Set(audience().map(\.userId)) }

    /// Add people to the allow-list. Idempotent — re-adding keeps the original `added_at`.
    static func addToAudience(_ userIds: [String]) {
        guard !userIds.isEmpty else { return }
        let now = Int64(Date().timeIntervalSince1970)
        db.write { database in
            for uid in userIds where !uid.isEmpty {
                try database.execute(sql: """
                    INSERT INTO map_audience (user_id, added_at) VALUES (?, ?)
                    ON CONFLICT(user_id) DO NOTHING
                    """, arguments: [uid, now])
            }
        }
    }

    static func removeFromAudience(_ userId: String) {
        db.write { database in
            try database.execute(sql: "DELETE FROM map_audience WHERE user_id = ?", arguments: [userId])
        }
    }

    /// The kill switch's local half: forget every person you were visible to.
    static func clearAudience() {
        db.write { database in try database.execute(sql: "DELETE FROM map_audience") }
    }

    // MARK: - Presence (contacts visible to you)

    /// Every contact we currently hold a fix for. The state machine (live/stale/aged-out)
    /// is applied by the caller from `fixedAt`; this returns the raw rows.
    static func presences() -> [MapPresence] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT sender_user_id, share_id, lat, lon, acc, seq, fixed_at
                  FROM map_presence ORDER BY fixed_at DESC
                """)
        } ?? []
        return rows.map(decodePresence)
    }

    /// Overwrite the single latest fix for one sender, in place. A fix with a sequence not
    /// strictly newer than what we hold is DROPPED — an out-of-order relay frame must never
    /// render as a jump backwards.
    @discardableResult
    static func upsertFix(senderUserId: String, shareId: String, coordinate: CLLocationCoordinate2D,
                          accuracy: CLLocationAccuracy, seq: Int, fixedAt: Date) -> Bool {
        // Drop stale/out-of-order frames for the same share.
        if let existing = presence(for: senderUserId), existing.shareId == shareId, seq <= existing.seq {
            return false
        }
        db.write { database in
            try database.execute(sql: """
                INSERT INTO map_presence
                    (sender_user_id, share_id, lat, lon, acc, seq, fixed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(sender_user_id) DO UPDATE SET
                    share_id = excluded.share_id,
                    lat      = excluded.lat,
                    lon      = excluded.lon,
                    acc      = excluded.acc,
                    seq      = excluded.seq,
                    fixed_at = excluded.fixed_at
                """, arguments: [senderUserId, shareId, coordinate.latitude, coordinate.longitude,
                                 accuracy, seq, Int64(fixedAt.timeIntervalSince1970)])
        }
        return true
    }

    static func presence(for senderUserId: String) -> MapPresence? {
        let row = db.read { database -> Row? in
            try Row.fetchOne(database, sql: """
                SELECT sender_user_id, share_id, lat, lon, acc, seq, fixed_at
                  FROM map_presence WHERE sender_user_id = ?
                """, arguments: [senderUserId])
        } ?? nil
        return row.map(decodePresence)
    }

    /// Erase a contact's cached position — used when a `map_off` arrives or their share
    /// expires. This is the load-bearing distinction from an age-out: an explicit stop
    /// ERASES the last position, an age-out KEEPS it.
    static func erasePresence(senderUserId: String) {
        db.write { database in
            try database.execute(sql: "DELETE FROM map_presence WHERE sender_user_id = ?",
                                 arguments: [senderUserId])
        }
    }

    /// Cold-start / periodic hygiene: drop anything older than the 8-hour stale window.
    /// Nothing older than that is ever drawn or listed, so keeping it only leaks a stale
    /// position across relaunches (§8: "wipes the local cache … for anything older than 8 h").
    static func pruneAged(now: Date = Date()) {
        let cutoff = Int64(now.addingTimeInterval(-MapPresenceState.staleWindow).timeIntervalSince1970)
        db.write { database in
            try database.execute(sql: "DELETE FROM map_presence WHERE fixed_at < ?", arguments: [cutoff])
        }
    }

    /// The kill switch / ghost cold-wipe: discard every cached contact position.
    static func clearPresence() {
        db.write { database in try database.execute(sql: "DELETE FROM map_presence") }
    }

    // MARK: - Row mapping

    private static func decodePresence(_ row: Row) -> MapPresence {
        let senderUserId: String = row["sender_user_id"]
        let shareId: String = row["share_id"]
        let lat: Double = row["lat"] ?? 0
        let lon: Double = row["lon"] ?? 0
        let acc: Double = row["acc"] ?? 0
        let seq: Int = row["seq"] ?? 0
        let fixedAt: Int64 = row["fixed_at"] ?? 0
        return MapPresence(
            senderUserId: senderUserId,
            shareId: shareId,
            coordinate: CLLocationCoordinate2D(latitude: lat, longitude: lon),
            accuracy: acc,
            seq: seq,
            fixedAt: Date(timeIntervalSince1970: TimeInterval(fixedAt))
        )
    }
}
