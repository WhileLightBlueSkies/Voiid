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
        UserDefaults.standard.removeObject(forKey: "voiid.restore.completed.\(res.user_id)")
        UserDefaults.standard.set(!res.profile_complete, forKey: "voiid.recovery.ready.\(res.user_id)")
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

    /// End the session on the SERVER, then locally.
    ///
    /// Clearing the keychain alone left the JWT valid for the rest of its 30 days: anyone
    /// who recovered it could still send, fetch and upload keys as this device. The server
    /// now revokes the device session, drops its prekeys and closes its socket.
    ///
    /// Local state is cleared FIRST and synchronously, so the UI can route to onboarding
    /// immediately and a user with no network still ends up logged out. The revoke is
    /// therefore fired with the credential captured by value — reading it back from the
    /// store would find nothing, and the session would live out its full 30 days.
    ///
    /// Best-effort by design: if it never lands, the device remains revocable from the
    /// linked-devices screen on another device.
    func logout() {
        let credential = tokens.jwt
        tokens.clear()
        guard let credential else { return }
        let client = api
        Task.detached {
            _ = try? await client.request("POST", "auth/logout", body: nil,
                                          bearer: credential, as: EmptyResponse.self)
        }
    }
}
