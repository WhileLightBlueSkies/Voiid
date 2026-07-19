//
//  TokenStore.swift
//  Voiid
//
//  Secure storage for OUR JWT (and the user id) in the iOS Keychain — never
//  UserDefaults. The chat session keys (e2e-core pickle keys) get their own
//  Keychain entries elsewhere; this is just the auth token.
//

import Foundation
import Security

/// Keychain-backed store for the auth JWT + user id. Thread-safe (Keychain is).
final class TokenStore {
    static let shared = TokenStore()

    private let jwtKey = "jwt"
    private let userIdKey = "user_id"

    private init() {}

    var jwt: String? {
        get { read(jwtKey) }
        set { newValue.map { save(jwtKey, $0) } ?? delete(jwtKey) }
    }

    var userId: String? {
        get { read(userIdKey) }
        set { newValue.map { save(userIdKey, $0) } ?? delete(userIdKey) }
    }

    var isAuthenticated: Bool { jwt != nil }

    func clear() {
        delete(jwtKey)
        delete(userIdKey)
    }

    // MARK: - Keychain primitives (shared access group so the NSE can read the JWT)

    /// Backed by the SHARED-access-group keychain store: the Notification Service
    /// Extension needs the auth JWT to call the API. Legacy app-private items are
    /// migrated into the shared group on first access (see KeychainData).
    private let kc = KeychainData(service: "com.voiid.auth")

    private func save(_ key: String, _ value: String) { kc.set(value, key) }
    private func read(_ key: String) -> String? { kc.string(key) }
    private func delete(_ key: String) { kc.delete(key) }
}
