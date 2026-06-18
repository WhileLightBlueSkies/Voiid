//
//  AuthService.swift
//  Voiid
//
//  Auth flow (Signal/WhatsApp-style identity-by-phone, but identity is OURS):
//   1. The app verifies the phone with Firebase Phone Auth (client SDK) and gets
//      a Firebase ID token.
//   2. We POST that token to /auth/firebase; the server verifies it and returns
//      OUR JWT, which we store in the Keychain.
//   3. From then on, every API call uses our JWT.
//
//  Until the Firebase SDK is wired into the project, `devLogin` uses the backend
//  dev bypass ("dev:<phone>") so the whole flow is testable now.
//

import Foundation

struct AuthResponse: Decodable {
    let token: String
    let user_id: String
    var profile_complete: Bool = false
}

@MainActor
final class AuthService {
    static let shared = AuthService()
    private let api = APIClient()
    private let tokens = TokenStore.shared

    private init() {}

    var isAuthenticated: Bool { tokens.isAuthenticated }
    var userId: String? { tokens.userId }

    /// Exchange a Firebase ID token for our JWT and persist it.
    /// Returns whether the user's profile is already complete (returning user) so
    /// the caller can skip the Signup/Profile screens.
    @discardableResult
    func loginWithFirebase(idToken: String) async throws -> Bool {
        let body = ["id_token": idToken]
        let res: AuthResponse = try await api.request("POST", "auth/firebase", body: body, auth: false)
        tokens.jwt = res.token
        tokens.userId = res.user_id
        return res.profile_complete
    }

    /// DEV ONLY: log in via the backend dev bypass (no Firebase needed).
    /// Requires AUTH_DEV_BYPASS=1 on the server. `phone` is E.164, e.g. "+9199...".
    @discardableResult
    func devLogin(phone: String) async throws -> Bool {
        try await loginWithFirebase(idToken: "dev:\(phone)")
    }

    func logout() {
        tokens.clear()
    }
}
