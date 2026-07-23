//
//  MapKeyStore.swift
//  Voiid
//
//  Where map share keys live: the Keychain, NEVER SQLite (§6). A share key is the whole
//  authorization boundary for a stream of coordinates, so it gets the same treatment as
//  the E2E identity — `KeychainData`, the shared access-group store used across the app
//  and the NSE.
//
//  TWO directions of key:
//   - OUTBOUND: the single 32-byte key your device mints when you go visible. Every fix you
//     emit is `encryptBackup(outboundKey, fix)`. Rotated (a fresh mint) whenever you leave
//     ghost, so a ghosted period is cryptographically dark — anyone holding the old key
//     sees nothing new (§8).
//   - INBOUND: one key per contact who is visible to you, received in their `map_key`
//     control message. Used to decrypt that contact's fixes.
//
//  THE TRAP (§1): `encryptBackup` derives its AES key via HKDF with the SAME label as real
//  account backups. A map share key MUST come from `generateMasterSecret()` and MUST NEVER
//  be the user's backup master secret, or the two purposes derive the same AES key. This
//  store only ever holds freshly-minted 32-byte secrets, never `E2EManager.masterSecret()`.
//

import Foundation

@MainActor
enum MapKeyStore {

    private static let kc = KeychainData(service: "com.voiid.mapkeys")
    private static let outboundName = "outbound_map_key"
    private static let inboundPrefix = "inbound_map_key."

    // MARK: - Outbound (my own visibility key)

    /// Mint a fresh 32-byte key and store it as the current outbound map key. Returns the
    /// raw key so the caller can pack it into the `map_key` control envelope. Always fresh
    /// from `generateMasterSecret()` — never the backup master secret (see the trap above).
    static func mintOutboundKey() -> Data {
        let key = generateMasterSecret()
        kc.setData(key, outboundName)
        return key
    }

    static func outboundKey() -> Data? {
        guard let d = kc.data(outboundName), d.count == 32 else { return nil }
        return d
    }

    /// Forget the outbound key — on Ghost Mode on, on kill switch, on expiry. After this,
    /// nothing this device emits can be produced (there is no key to encrypt with), and the
    /// old key can no longer be re-derived.
    static func clearOutboundKey() { kc.delete(outboundName) }

    // MARK: - Inbound (per-contact decryption keys)

    static func setInboundKey(_ key: Data, forSender userId: String) {
        kc.setData(key, inboundPrefix + userId)
    }

    static func inboundKey(forSender userId: String) -> Data? {
        guard let d = kc.data(inboundPrefix + userId), d.count == 32 else { return nil }
        return d
    }

    /// Drop a contact's inbound key when they ghost/stop, so a resurrected stale frame can
    /// never be decrypted after they turned it off.
    static func clearInboundKey(forSender userId: String) {
        kc.delete(inboundPrefix + userId)
    }
}
