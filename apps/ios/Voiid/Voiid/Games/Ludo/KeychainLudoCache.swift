//
//  KeychainLudoCache.swift
//  Voiid
//
//  Force-quit restore cache (§9): encrypted local {matchId, lastSeq, lastRenderedActionId}
//  so the board appears immediately on next launch, then is REPLACED by the server snapshot.
//  Keychain-backed (device-protected), never a plaintext plist.
//

import Foundation
import Security

final class KeychainLudoCache {
    static let shared = KeychainLudoCache()
    private let service = "com.voiid.ludo.cache"

    func save(matchId: String, dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: matchId,
        ]
        let attrs: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    func readMatchId() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let dict = item as? [String: Any],
              let account = dict[kSecAttrAccount as String] as? String else { return nil }
        return account
    }

    func clear(matchId: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: matchId,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
