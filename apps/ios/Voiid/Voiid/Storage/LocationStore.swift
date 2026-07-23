//
//  LocationStore.swift
//  Voiid
//
//  Disk persistence for location shares + the single most recent fix per (share, sender).
//  Same idiom as LocalStore: a @MainActor enum over VoiidDatabase, raw parameterized SQL,
//  epoch SECONDS at the column boundary (models carry millis), read paths that degrade to
//  empty rather than throwing.
//
//  The shareKey NEVER lives here — SQLite is plaintext at rest. Keys live in the Keychain
//  (LocationKeyStore). This store holds only routing/timing metadata + the last known fix.
//

import Foundation
import GRDB

@MainActor
enum LocationStore {

    private static var db: VoiidDatabase { VoiidDatabase.shared }
    private static func nowSeconds() -> Int64 { Int64(Date().timeIntervalSince1970) }
    private static func secs(_ millis: Double?) -> Int64? { millis.map { Int64($0 / 1000) } }

    // MARK: - Shares

    /// Record (or update) an OUTBOUND share this device is emitting.
    static func upsertOutbound(id: String, conversationId: String?, isGroup: Bool,
                               expiresAtMillis: Double, cadenceSeconds: Int, targets: [String]) {
        db.write { database in
            try database.execute(sql: """
                INSERT INTO location_shares
                    (id, kind, direction, conversation_id, peer_user_id,
                     started_at, expires_at, ended_at, cadence_seconds, state)
                VALUES (?, 'conversation', 'out', ?, NULL, ?, ?, NULL, ?, 'live')
                ON CONFLICT(id) DO UPDATE SET
                    expires_at = excluded.expires_at,
                    cadence_seconds = excluded.cadence_seconds,
                    ended_at = NULL,
                    state = 'live'
                """, arguments: [id, conversationId, nowSeconds(),
                                 secs(expiresAtMillis) ?? nowSeconds(), cadenceSeconds])
            for uid in targets {
                try database.execute(sql: """
                    INSERT INTO location_share_targets (share_id, user_id, revoked_at)
                    VALUES (?, ?, NULL)
                    ON CONFLICT(share_id, user_id) DO NOTHING
                    """, arguments: [id, uid])
            }
        }
    }

    /// Record (or update) an INBOUND share (someone is sharing with us).
    static func upsertInbound(id: String, conversationId: String?, ownerUserId: String,
                              expiresAtMillis: Double?, cadenceSeconds: Int) {
        db.write { database in
            try database.execute(sql: """
                INSERT INTO location_shares
                    (id, kind, direction, conversation_id, peer_user_id,
                     started_at, expires_at, ended_at, cadence_seconds, state)
                VALUES (?, 'conversation', 'in', ?, ?, ?, ?, NULL, ?, 'live')
                ON CONFLICT(id) DO UPDATE SET
                    expires_at = excluded.expires_at,
                    peer_user_id = excluded.peer_user_id,
                    cadence_seconds = excluded.cadence_seconds,
                    ended_at = NULL,
                    state = 'live'
                """, arguments: [id, conversationId, ownerUserId,
                                 nowSeconds(),
                                 secs(expiresAtMillis) ?? (nowSeconds() + 3600),
                                 cadenceSeconds])
        }
    }

    /// Mark a share ended (explicit stop). Idempotent.
    static func end(id: String) {
        db.write { database in
            try database.execute(sql: """
                UPDATE location_shares SET ended_at = ?, state = 'ended' WHERE id = ? AND ended_at IS NULL
                """, arguments: [nowSeconds(), id])
        }
        deleteFixes(shareId: id)
    }

    /// Extend an outbound share's expiry.
    static func extend(id: String, expiresAtMillis: Double) {
        db.write { database in
            try database.execute(sql: "UPDATE location_shares SET expires_at = ? WHERE id = ?",
                                 arguments: [secs(expiresAtMillis) ?? nowSeconds(), id])
        }
    }

    /// All active OUTBOUND shares (unexpired, not ended). The banner reads these.
    static func activeOutbound() -> [OutboundShare] {
        let now = nowSeconds()
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT s.id, s.conversation_id, s.expires_at, s.cadence_seconds,
                       (SELECT COUNT(*) FROM location_share_targets t
                          WHERE t.share_id = s.id AND t.revoked_at IS NULL) AS audience
                  FROM location_shares s
                 WHERE s.direction = 'out' AND s.ended_at IS NULL AND s.expires_at > ?
                 ORDER BY s.expires_at ASC
                """, arguments: [now])
        } ?? []
        return rows.map { row in
            let id: String = row["id"]
            let convId: String? = row["conversation_id"]
            let expSecs: Int64 = row["expires_at"] ?? now
            let cadence: Int = row["cadence_seconds"] ?? 15
            let audience: Int = row["audience"] ?? 0
            return OutboundShare(id: id, conversationId: convId ?? "", isGroup: false,
                                 audienceCount: audience,
                                 expiresAt: Date(timeIntervalSince1970: TimeInterval(expSecs)),
                                 cadenceSeconds: cadence)
        }
    }

    /// The non-revoked recipient user ids of an outbound share (to resume its WS stream
    /// after an app relaunch).
    static func targets(shareId: String) -> [String] {
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT user_id FROM location_share_targets
                 WHERE share_id = ? AND revoked_at IS NULL
                """, arguments: [shareId])
        } ?? []
        return rows.compactMap { $0["user_id"] }
    }

    /// Active INBOUND shares in a conversation (for rendering live markers in-chat).
    static func activeInbound(conversationId: String) -> [(shareId: String, ownerUserId: String, expiresAt: Date, cadence: Int)] {
        let now = nowSeconds()
        let rows = db.read { database -> [Row] in
            try Row.fetchAll(database, sql: """
                SELECT id, peer_user_id, expires_at, cadence_seconds
                  FROM location_shares
                 WHERE direction = 'in' AND conversation_id = ?
                   AND ended_at IS NULL AND expires_at > ?
                """, arguments: [conversationId, now])
        } ?? []
        return rows.compactMap { row in
            guard let owner: String = row["peer_user_id"] else { return nil }
            let id: String = row["id"]
            let expSecs: Int64 = row["expires_at"] ?? now
            let cadence: Int = row["cadence_seconds"] ?? 15
            return (id, owner, Date(timeIntervalSince1970: TimeInterval(expSecs)), cadence)
        }
    }

    /// True when this device holds an active inbound share with this id — the CLIENT-SIDE
    /// authorization check for a relayed loc_update (docs/LOCATION.md §9): a frame whose
    /// share_id is unknown is dropped.
    static func hasActiveInbound(shareId: String) -> Bool {
        let now = nowSeconds()
        let n = db.read { database -> Int in
            try Int.fetchOne(database, sql: """
                SELECT COUNT(*) FROM location_shares
                 WHERE id = ? AND direction = 'in' AND ended_at IS NULL AND expires_at > ?
                """, arguments: [shareId, now]) ?? 0
        } ?? 0
        return n > 0
    }

    // MARK: - Last fix (exactly one row per share+sender, overwritten in place)

    static func saveFix(_ fix: LocationFix, senderUserId: String) {
        db.write { database in
            try database.execute(sql: """
                INSERT INTO location_last_fix
                    (share_id, sender_user_id, lat, lon, acc, seq, fixed_at)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(share_id, sender_user_id) DO UPDATE SET
                    lat = excluded.lat, lon = excluded.lon, acc = excluded.acc,
                    seq = excluded.seq, fixed_at = excluded.fixed_at
                """, arguments: [fix.shareId, senderUserId, fix.lat, fix.lon, fix.acc,
                                 fix.seq, Int64(fix.timestampMillis / 1000)])
        }
    }

    /// The single most recent fix for a share (and its age), if any.
    static func lastFix(shareId: String) -> (fix: LocationFix, senderUserId: String, fixedAt: Date)? {
        let row = db.read { database -> Row? in
            try Row.fetchOne(database, sql: """
                SELECT sender_user_id, lat, lon, acc, seq, fixed_at
                  FROM location_last_fix WHERE share_id = ?
                """, arguments: [shareId])
        }
        guard let row = row.flatMap({ $0 }) else { return nil }
        let sender: String = row["sender_user_id"]
        let lat: Double = row["lat"] ?? 0
        let lon: Double = row["lon"] ?? 0
        let acc: Double? = row["acc"]
        let seq: Int = row["seq"] ?? 0
        let fixedSecs: Int64 = row["fixed_at"] ?? 0
        let fix = LocationFix(shareId: shareId, seq: seq,
                              timestampMillis: Double(fixedSecs) * 1000,
                              lat: lat, lon: lon, acc: acc)
        return (fix, sender, Date(timeIntervalSince1970: TimeInterval(fixedSecs)))
    }

    static func deleteFixes(shareId: String) {
        db.write { database in
            try database.execute(sql: "DELETE FROM location_last_fix WHERE share_id = ?",
                                 arguments: [shareId])
        }
    }
}
