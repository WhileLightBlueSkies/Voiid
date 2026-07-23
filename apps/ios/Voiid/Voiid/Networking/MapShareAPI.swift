//
//  MapShareAPI.swift
//  Voiid
//
//  The Map's thin client for the location-share HTTP surface (`/v1/location/shares`,
//  `kind: "map"`). The server stores ONE small row — "a map share exists, owned by you,
//  with this audience, until T" — and NOTHING else: no coordinate, no key, no ciphertext,
//  no last-seen, no update count (§6). The key appears in neither request nor response.
//
//  WHY TALK TO THE SERVER AT ALL for a local-first feature: two load-bearing reasons (§6).
//  (a) The WS relay process has no database, so `POST /shares` is the ONLY place audience
//  membership is validated and abuse is rate-limited. (b) It lets a reinstalled/relinked
//  device discover "you still have a map share running — stop it", rather than broadcasting
//  silently forever.
//
//  EVERY call here is best-effort from the UI's point of view: the local ghost/visibility
//  state and the `expires_at` both clients hold are the real guarantees. A failed POST must
//  never leave the UI claiming you are visible when the server never recorded it — the
//  engine treats a failed create as "not visible" and surfaces it honestly.
//
//  These endpoints are shared with Feature (A); this file only ever sends `kind: "map"`
//  bodies and reads back the fields the Map needs, so it does not depend on (A)'s client.
//

import Foundation

@MainActor
enum MapShareAPI {

    private static var api: APIClient { APIClient() }

    // Map presence has no fixed timer, but the server row carries a hard 24-hour ceiling —
    // the auto-ghost that guarantees visibility is never forgotten for a week (§3).
    static let mapDurationSeconds = 24 * 60 * 60

    // MARK: - DTOs

    private struct CreateBody: Encodable {
        let kind: String                  // "map"
        let target_user_ids: [String]
        let duration_seconds: Int
    }
    struct CreateResponse: Decodable {
        let share_id: String
        let expires_at: String?
    }
    struct ExtendBody: Encodable { let duration_seconds: Int }
    struct ExtendResponse: Decodable { let expires_at: String? }

    // MARK: - Calls

    /// Create (or replace) your map share for `targetUserIds`. The server auto-ends any
    /// prior active map share you own, so re-adding the audience after a rekey is one call.
    /// Throws on failure so the engine can decline to claim visibility it didn't record.
    @discardableResult
    static func createMapShare(targetUserIds: [String]) async throws -> CreateResponse {
        try await api.request("POST", "location/shares",
                              body: CreateBody(kind: "map",
                                               target_user_ids: targetUserIds,
                                               duration_seconds: mapDurationSeconds))
    }

    /// Push the 24-hour ceiling forward — called on foreground while visible, so an actively
    /// used map presence does not silently auto-ghost mid-use.
    @discardableResult
    static func extend(shareId: String) async throws -> ExtendResponse {
        try await api.request("POST", "location/shares/\(shareId)/extend",
                              body: ExtendBody(duration_seconds: mapDurationSeconds))
    }

    /// End your map share. Idempotent server-side; the server also publishes a `loc_stop`
    /// routing signal to each target and clears the last-fix buffer.
    static func endShare(shareId: String) async {
        _ = try? await api.request("DELETE", "location/shares/\(shareId)", as: EmptyResponse.self)
    }

    /// Revoke one recipient from your map share (they picked you, now you remove them, or
    /// vice-versa). After this the engine mints a fresh key and redistributes to the rest.
    static func revokeTarget(shareId: String, userId: String) async {
        _ = try? await api.request("DELETE", "location/shares/\(shareId)/targets/\(userId)",
                                   as: EmptyResponse.self)
    }

    /// Stop seeing a contact without asking them (a viewer opt-out).
    static func leave(shareId: String) async {
        _ = try? await api.request("POST", "location/shares/\(shareId)/leave",
                                   body: EmptyBody(), as: EmptyResponse.self)
    }

    private struct EmptyBody: Encodable {}
}
