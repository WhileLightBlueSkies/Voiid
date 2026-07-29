//
//  ProfileKeyStore.swift
//  Voiid
//
//  ENCRYPTED PROFILE PHOTOS — key custody and distribution (see 021_profile_keys.sql).
//
//  Avatars were the one media surface stored in the CLEAR: `uploadProfilePhoto` PUT a raw JPEG
//  to R2, so anyone with bucket access — including us — could open every user's face. Chat
//  photos, videos, voice notes and Moments have always been encrypted on-device.
//
//  WHY AVATARS NEED THEIR OWN MECHANISM. A chat photo has ONE known audience, so a fresh
//  per-attachment key rides the ratchet with the message. An avatar has no fixed audience — it
//  is shown to anyone who might contact you, including someone who found your @username and
//  has never had a session with you. There is no single message to attach a key to. The key is
//  therefore per-USER and long-lived, wrapped once per recipient DEVICE (Signal's model).
//
//  ⚠️ BLOCKED ON UNIFFI REGENERATION. `generateProfileKey` and `encryptMediaWithKey` exist in
//  packages/e2e-core (with tests) but are NOT yet in the generated Swift bindings, so the two
//  call sites below are marked and will not compile until someone regenerates. Everything
//  else here — storage, fan-out, fetch, rotation — is complete and testable.
//

import Foundation

@MainActor
final class ProfileKeyStore {
    static let shared = ProfileKeyStore()
    private init() {}

    // MARK: - My own key

    /// Keychain, not UserDefaults: this key decrypts an avatar for every contact who holds a
    /// wrapped copy, so it is a long-lived secret and belongs with the other long-lived
    /// secrets. Losing it is recoverable (rotate + re-upload); leaking it is not.
    /// Same helper the map and E2E stores use, on its own service so a wipe here cannot touch
    /// ratchet material.
    private static let kc = KeychainData(service: "com.voiid.profilekeys")
    private static let myKeyAccount = "self"
    private static let myVersionKey = "voiid.profile.key.version"

    /// My profile key, minting one on first use.
    ///
    /// Version starts at 1 — the server's `profile_key_version` defaults to 0, so "0" is
    /// unambiguously "this user has never published a key".
    func myKey() -> (key: String, version: Int)? {
        guard let existing = Self.kc.string(Self.myKeyAccount) else { return nil }
        let version = UserDefaults.standard.integer(forKey: Self.myVersionKey)
        return (existing, max(1, version))
    }

    /// Mint a NEW profile key and bump the version. Called on first avatar upload and on every
    /// rotation. The caller must then re-encrypt the avatar AND re-wrap to every contact —
    /// a rotation that is not fanned out leaves every contact unable to decrypt.
    func rotateKey() -> (key: String, version: Int) {
        // ⚠️ UNIFFI: `generateProfileKey()` is exported from e2e-core but not yet in the
        // generated bindings. Uncomment once regenerated.
        // let key = generateProfileKey()
        let key = Self.temporaryLocalKey()
        let next = UserDefaults.standard.integer(forKey: Self.myVersionKey) + 1
        Self.kc.set(key, Self.myKeyAccount)
        UserDefaults.standard.set(next, forKey: Self.myVersionKey)
        return (key, next)
    }

    /// Stand-in until the bindings land. Produces a correctly-shaped base64 32-byte key using
    /// the platform CSPRNG, so the surrounding plumbing can be exercised end-to-end. It is
    /// cryptographically fine — it is simply not the same code path the Rust core uses, and
    /// must be deleted the moment `generateProfileKey()` is available.
    private static func temporaryLocalKey() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64EncodedString()
    }

    // MARK: - Other people's keys

    /// Wrapped keys received from contacts: ownerUserId → (key, version).
    ///
    /// Cached in memory and mirrored to the keychain, because an avatar must render on the
    /// first frame offline — re-fetching per view would make every contact list flash blank.
    private var peerKeys: [String: (key: String, version: Int)] = [:]

    func key(for userId: String) -> String? {
        if let cached = peerKeys[userId] { return cached.key }
        guard let stored = Self.kc.string("peer.\(userId)") else { return nil }
        let version = UserDefaults.standard.integer(forKey: "voiid.profile.key.version.\(userId)")
        peerKeys[userId] = (stored, version)
        return stored
    }

    /// The version we hold for a peer. Compared against the `profile_key_version` on their
    /// profile: if theirs is higher, our copy is stale and must be re-fetched. Without this a
    /// rotation is only detectable by a failed decrypt, which is indistinguishable from a
    /// corrupt download.
    func version(for userId: String) -> Int {
        UserDefaults.standard.integer(forKey: "voiid.profile.key.version.\(userId)")
    }

    func store(key: String, version: Int, for userId: String) {
        peerKeys[userId] = (key, version)
        Self.kc.set(key, "peer.\(userId)")
        UserDefaults.standard.set(version, forKey: "voiid.profile.key.version.\(userId)")
    }

    /// Sign-out wipe. These are other people's secrets held on this device; leaving them
    /// behind would let the next account on this phone decrypt the previous one's contacts.
    func clear() {
        for userId in peerKeys.keys {
            UserDefaults.standard.removeObject(forKey: "voiid.profile.key.version.\(userId)")
        }
        peerKeys.removeAll()
        // wipeService clears EVERY key on this service in one call — safer than iterating,
        // which would miss any peer key not currently in the in-memory map (e.g. after a
        // relaunch where nothing has been read yet).
        Self.kc.wipeService()
        UserDefaults.standard.removeObject(forKey: Self.myVersionKey)
    }
}
