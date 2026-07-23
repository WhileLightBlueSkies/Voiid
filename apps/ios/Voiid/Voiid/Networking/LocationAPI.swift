//
//  LocationAPI.swift
//  Voiid
//
//  The six share-session endpoints (docs/LOCATION.md §9). This is the ONLY place a share
//  is created / ended server-side. The server stores exactly "a share exists between A
//  and B until T" and nothing else — no coordinate, no key, no ciphertext ever crosses
//  these calls. The shareKey travels E2EE inside the `live_start` control MESSAGE, not
//  here.
//
//  There is deliberately NO position-update endpoint: fixes are WS-only (LocationShareEngine).
//

import Foundation

struct LocationAPI {
    private let api = APIClient()

    // MARK: - DTOs

    struct CreateBody: Encodable {
        let kind: String                 // "conversation"
        var conversation_id: String?
        let target_user_ids: [String]
        let duration_seconds: Int
    }
    struct CreateResponse: Decodable {
        let share_id: String
        var expires_at: String?          // ISO8601
    }
    struct ExtendBody: Encodable { let duration_seconds: Int }
    struct ExtendResponse: Decodable { var expires_at: String? }

    // MARK: - Calls

    /// Create a conversation share. Returns the server share_id + authoritative expiry.
    /// The server validates conversation membership (the WS process cannot).
    func createShare(conversationId: String, targetUserIds: [String],
                     durationSeconds: Int) async throws -> CreateResponse {
        try await api.request("POST", "location/shares",
                              body: CreateBody(kind: "conversation",
                                               conversation_id: conversationId,
                                               target_user_ids: targetUserIds,
                                               duration_seconds: durationSeconds))
    }

    /// Extend an owned share (owner only).
    @discardableResult
    func extendShare(_ shareId: String, durationSeconds: Int) async throws -> ExtendResponse {
        try await api.request("POST", "location/shares/\(shareId)/extend",
                              body: ExtendBody(duration_seconds: durationSeconds))
    }

    /// End an owned share (owner only). Server also publishes a loc_stop routing signal to
    /// each target and hdel's the last-fix buffer, so an offline recipient still ends it.
    func endShare(_ shareId: String) async throws {
        _ = try await api.request("DELETE", "location/shares/\(shareId)") as EmptyResponse
    }

    /// Revoke a single recipient (owner only). Caller then re-keys the remaining audience.
    func revokeTarget(_ shareId: String, userId: String) async throws {
        _ = try await api.request("DELETE", "location/shares/\(shareId)/targets/\(userId)") as EmptyResponse
    }

    /// A recipient opts out of a share (stops seeing it without asking the owner).
    func leaveShare(_ shareId: String) async throws {
        _ = try await api.request("POST", "location/shares/\(shareId)/leave",
                                  body: EmptyBody()) as EmptyResponse
    }

    private struct EmptyBody: Encodable {}
}
