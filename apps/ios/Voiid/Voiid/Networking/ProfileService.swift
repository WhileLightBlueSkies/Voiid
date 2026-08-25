//
//  ProfileService.swift
//  Voiid
//
//  Profile + username (the username is the Clips handle ONLY — not messaging
//  identity). Talks to /users/username-available and /users/profile/update.
//

import Foundation

struct UsernameAvailability: Decodable {
    let available: Bool
    let reason: String?
}

struct ProfileUser: Decodable {
    let id: String
    let full_name: String?
    let email: String?
    let photo_url: String?
    let username: String?
}
private struct ProfileEnvelope: Decodable { let user: ProfileUser }

@MainActor
final class ProfileService {
    static let shared = ProfileService()
    private let api = APIClient()
    private init() {}

    /// Live availability check for a candidate username (Clips handle).
    func checkUsername(_ username: String) async throws -> UsernameAvailability {
        let q = username.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? username
        return try await api.request("GET", "users/username-available?username=\(q)")
    }

    /// Save profile fields. Any subset may be provided. Throws APIError.http(409)
    /// if the username was taken between check and save.
    @discardableResult
    func updateProfile(
        fullName: String? = nil,
        email: String? = nil,
        photoURL: String? = nil,
        bio: String? = nil,
        username: String? = nil,
        lastSeenPrivacy: String? = nil,
        photoPrivacy: String? = nil,
        aboutPrivacy: String? = nil
    ) async throws -> ProfileUser {
        var body: [String: String] = [:]
        if let fullName { body["full_name"] = fullName }
        if let email { body["email"] = email }
        if let photoURL { body["photo_url"] = photoURL }
        if let bio { body["bio"] = bio }
        if let username { body["username"] = username }
        if let lastSeenPrivacy { body["last_seen_privacy"] = lastSeenPrivacy }
        if let photoPrivacy { body["photo_privacy"] = photoPrivacy }
        if let aboutPrivacy { body["about_privacy"] = aboutPrivacy }
        let env: ProfileEnvelope = try await api.request("POST", "users/profile/update", body: body)
        return env.user
    }

    /// Set or clear the availability status.
    ///
    /// A SEPARATE CALL rather than another parameter on `updateProfile`, because `nil` there
    /// means "leave this field alone" for every other field, and clearing the status needs to
    /// send an explicit JSON null. Folding a tri-state (set / clear / untouched) into a body
    /// typed `[String: String]` would either lose the clear or silently rewrite it as the
    /// empty string, which the server would then store as a status that is neither set nor
    /// absent. The route distinguishes `null` from `undefined` deliberately; this preserves
    /// that distinction rather than fighting it.
    @discardableResult
    func updateStatus(_ status: AvailabilityStatus?) async throws -> ProfileUser {
        struct Body: Encodable {
            // Explicitly `String?` and always encoded — `Encodable` writes a JSON null for a
            // nil optional property, which is exactly the "clear it" signal the route wants.
            let status_text: String?
        }
        let env: ProfileEnvelope = try await api.request(
            "POST", "users/profile/update", body: Body(status_text: status?.rawValue))
        return env.user
    }
}
