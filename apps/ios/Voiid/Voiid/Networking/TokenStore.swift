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

    private let service = "com.voiid.auth"
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

    // MARK: - Keychain primitives

    private func save(_ key: String, _ value: String) {
        let data = Data(value.utf8)
        var query = baseQuery(key)
        SecItemDelete(query as CFDictionary)            // overwrite
        query[kSecValueData as String] = data
        // Available after first unlock; survives app restarts, not backed up off-device.
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(query as CFDictionary, nil)
    }

    private func read(_ key: String) -> String? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func delete(_ key: String) {
        SecItemDelete(baseQuery(key) as CFDictionary)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }
}
