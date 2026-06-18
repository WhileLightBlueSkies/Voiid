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
        username: String? = nil
    ) async throws -> ProfileUser {
        var body: [String: String] = [:]
        if let fullName { body["full_name"] = fullName }
        if let email { body["email"] = email }
        if let photoURL { body["photo_url"] = photoURL }
        if let bio { body["bio"] = bio }
        if let username { body["username"] = username }
        let env: ProfileEnvelope = try await api.request("POST", "users/profile/update", body: body)
        return env.user
    }
}
