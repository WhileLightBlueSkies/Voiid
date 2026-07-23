//
//  LocationKeyStore.swift
//  Voiid
//
//  Where live-share keys live: the platform secure store (Keychain), NEVER SQLite
//  (docs/LOCATION.md §6). One share == one 32-byte `shareKey` from
//  `generateMasterSecret()`, distributed to the audience inside a durable E2EE control
//  message. Every fix in the share is `encryptBackup(shareKey, fix)`.
//
//  TRAP (docs/LOCATION.md §1): `encryptBackup` derives its AES key via
//  HKDF-SHA256(secret, "VOIID backup key v1") — the SAME label as real account backups.
//  A shareKey MUST come from `generateMasterSecret()` and MUST NEVER be a user's backup
//  master secret, or the two purposes would derive the same AES key. This store only ever
//  holds freshly-minted share keys, and lives in its own Keychain service so it can never
//  be confused with the backup secret.
//
//  Keys are deleted on stop, on expiry, and on rekey — the removed key then decrypts
//  nothing further.
//

import Foundation

final class LocationKeyStore {
    static let shared = LocationKeyStore()
    // A dedicated service, distinct from com.voiid.e2e (identity/backup) — keeping share
    // keys namespaced away from the backup master secret is a structural guard against
    // the shared-HKDF-label trap above.
    private let kc = KeychainData(service: "com.voiid.location.keys")
    private init() {}

    private func name(_ shareId: String) -> String { "sharekey_\(shareId)" }

    /// Store a freshly-minted (or rekeyed) shareKey as raw base64.
    func setKey(base64: String, shareId: String) { kc.set(base64, name(shareId)) }

    /// Store raw key bytes.
    func setKey(_ data: Data, shareId: String) { kc.setData(data, name(shareId)) }

    /// The raw 32-byte key for a share, if held.
    func key(shareId: String) -> Data? {
        // Stored as base64 (setKey(base64:)) OR raw (setKey(_:)); accept either.
        if let d = kc.data(name(shareId)) {
            if d.count == 32 { return d }
            if let s = String(data: d, encoding: .utf8), let raw = Data(base64Encoded: s) { return raw }
            return d
        }
        return nil
    }

    func deleteKey(shareId: String) { kc.delete(name(shareId)) }
}
