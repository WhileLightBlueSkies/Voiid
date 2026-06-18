//
//  E2EManager.swift
//  Voiid
//
//  Owns the device's e2e-core Identity (the root of all E2EE). On login it:
//   - restores the Identity from an encrypted pickle (Keychain), or creates one;
//   - registers the device (identity public key) with the backend;
//   - publishes a pool of one-time prekeys so peers can start sessions with us.
//
//  The Identity pickle + its 32-byte pickle key live in the Keychain only. Per
//  the binding API: Identity.create() / .restore(pickle:pickleKey:) /
//  .publishBundle(oneTimeKeyCount:) / .toPickle(pickleKey:).
//

import Foundation
import Security

@MainActor
final class E2EManager {
    static let shared = E2EManager()
    private let api = APIClient()
    private init() {}

    private(set) var identity: Identity?
    private(set) var deviceId: String?
    private var bootstrapped = false

    private let kc = KeychainData(service: "com.voiid.e2e")
    private let pickleKeyName = "identity_pickle_key"   // 32 random bytes
    private let pickleName = "identity_pickle"          // encrypted identity
    private let deviceIdName = "device_id"
    private let regIdName = "registration_id"

    /// Ensure this device has a published e2e-core identity. Call after login.
    /// Safe to call repeatedly (restores existing identity, re-publishes prekeys).
    func bootstrap() async throws {
        if bootstrapped { return }            // once per app session
        let id = try loadOrCreateIdentity()
        identity = id
        let bundle = id.publishBundle(oneTimeKeyCount: 100)
        try persist(id)                       // re-pickle (one-time keys advanced)
        try await publish(bundle: bundle)
        bootstrapped = true
    }

    // MARK: - Identity lifecycle

    private func loadOrCreateIdentity() throws -> Identity {
        let key = pickleKey()
        if let pickle = kc.string(pickleName) {
            do { return try Identity.restore(pickle: pickle, pickleKey: key) }
            catch { /* corrupt/old pickle — fall through and recreate */ }
        }
        let id = Identity.create()
        try persist(id, key: key)
        return id
    }

    private func persist(_ id: Identity, key: Data? = nil) throws {
        let k = key ?? pickleKey()
        let pickle = try id.toPickle(pickleKey: k)
        kc.set(pickle, pickleName)
    }

    /// Stable 32-byte pickle key (created once, kept in Keychain).
    private func pickleKey() -> Data {
        if let existing = kc.data(pickleKeyName), existing.count == 32 { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        let data = Data(bytes)
        kc.setData(data, pickleKeyName)
        return data
    }

    /// Stable per-install registration id (Signal-style integer).
    private func registrationId() -> Int {
        if let s = kc.string(regIdName), let n = Int(s) { return n }
        let n = Int.random(in: 1...0x7FFF_FFFE)
        kc.set(String(n), regIdName)
        return n
    }

    // MARK: - Publish to backend

    private struct RegisterDeviceBody: Encodable {
        let platform: String
        let registration_id: Int
        let identity_public_key: String
    }
    private struct DeviceResponse: Decodable { let device_id: String }
    private struct OTK: Encodable { let key_id: Int; let public_key: String }
    private struct PrekeysBody: Encodable { let device_id: String; let one_time_prekeys: [OTK] }

    private func publish(bundle: PublicBundle) async throws {
        let dev: DeviceResponse = try await api.request(
            "POST", "devices/register",
            body: RegisterDeviceBody(platform: "ios",
                                     registration_id: registrationId(),
                                     identity_public_key: bundle.identityKey))
        deviceId = dev.device_id
        kc.set(dev.device_id, deviceIdName)

        let otks = bundle.oneTimeKeys.enumerated().map { OTK(key_id: $0.offset, public_key: $0.element) }
        let _: EmptyResponse = try await api.request(
            "POST", "prekeys/upload", body: PrekeysBody(device_id: dev.device_id, one_time_prekeys: otks))
    }
}

// MARK: - Minimal generic Keychain store (Data + String)

final class KeychainData {
    private let service: String
    init(service: String) { self.service = service }

    func setData(_ value: Data, _ key: String) {
        var q = base(key); SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    func set(_ value: String, _ key: String) { setData(Data(value.utf8), key) }

    func data(_ key: String) -> Data? {
        var q = base(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    func string(_ key: String) -> String? { data(key).flatMap { String(data: $0, encoding: .utf8) } }

    private func base(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
