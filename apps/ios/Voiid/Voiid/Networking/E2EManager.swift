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
    private let prekeyNextIdName = "prekey_next_id"     // monotonic one-time-key id counter

    private static let targetPrekeys = 100   // refill toward this many available
    private static let lowWatermark = 20     // replenish once we drop below this
    // Start ids above the legacy 0..99 range an earlier one-shot build used, so an
    // upgrade never collides with already-stored key ids (server keys on
    // (device_id, key_id) with do-nothing-on-conflict → dupes are silently dropped).
    private static let prekeyIdBase = 100

    /// Ensure this device has a published e2e-core identity. Call after login.
    /// Safe to call repeatedly (restores existing identity, tops up prekeys).
    func bootstrap() async throws {
        if bootstrapped { return }            // once per app session
        do {
            let id = try loadOrCreateIdentity()
            identity = id
            NSLog("[VOIID] bootstrap: identity ready")
            let devId = try await withTransportRetry { try await self.register(id) }
            deviceId = devId
            NSLog("[VOIID] bootstrap: registered device=\(devId)")
            try await withTransportRetry { try await self.ensurePrekeys(id, devId: devId) }
            NSLog("[VOIID] bootstrap: prekeys ensured")
            bootstrapped = true
        } catch {
            NSLog("[VOIID] bootstrap FAILED: \(error)")
            throw error
        }
    }

    /// Top up our published one-time prekeys when the server says we're low. Every
    /// inbound session a peer starts consumes one; if they're all consumed and we
    /// never replenish, NEW peers can't message us ("peer has no available prekeys").
    /// Safe to call repeatedly (e.g. on app resume). Mirrors Android.
    func ensurePrekeys(_ id: Identity? = nil, devId: String? = nil) async throws {
        guard let id = id ?? identity, let devId = devId ?? deviceId else { return }
        let available = (try? await availableCount(deviceId: devId)) ?? 0
        NSLog("[VOIID] ensurePrekeys: available=\(available)")
        if available >= Self.lowWatermark { return }
        let max = Int(id.maxOneTimeKeys())
        let target = min(Self.targetPrekeys, max)
        let need = Swift.max(0, Swift.min(target - available, max))
        if need == 0 { return }
        // Generate `need` NEW one-time keys (returns only the new ones), persist the
        // identity BEFORE upload so a crash can't lose the private halves, then upload.
        let bundle = id.replenishPrekeys(count: UInt32(need))
        try persist(id)
        NSLog("[VOIID] ensurePrekeys: uploading \(bundle.oneTimeKeys.count) keys (need=\(need) max=\(max))")
        try await uploadPrekeys(deviceId: devId, keys: bundle.oneTimeKeys)
    }

    /// Retry a network step a few times on transport errors (timeouts / flaky net)
    /// instead of permanently failing bootstrap on the first hiccup.
    private func withTransportRetry<T>(_ op: () async throws -> T) async throws -> T {
        var lastError: Error?
        for attempt in 0..<3 {
            do { return try await op() }
            catch let APIError.transport(e) {
                lastError = APIError.transport(e)
                NSLog("[VOIID] transport error (attempt \(attempt + 1)/3): \(e.localizedDescription)")
                try? await Task.sleep(nanoseconds: UInt64((attempt + 1)) * 1_500_000_000)
            }
        }
        throw lastError ?? APIError.http(status: 0, message: "network")
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
    private struct CountResponse: Decodable { let available: Int }

    /// Register (or refresh) this device server-side; returns the device id.
    /// publishBundle(0) yields the long-term identity key WITHOUT generating any
    /// one-time keys — those are managed separately by `ensurePrekeys`.
    private func register(_ id: Identity) async throws -> String {
        let identityKey = id.publishBundle(oneTimeKeyCount: 0).identityKey
        try persist(id)
        let dev: DeviceResponse = try await api.request(
            "POST", "devices/register",
            body: RegisterDeviceBody(platform: "ios",
                                     registration_id: registrationId(),
                                     identity_public_key: identityKey))
        deviceId = dev.device_id
        kc.set(dev.device_id, deviceIdName)
        return dev.device_id
    }

    /// Our remaining unconsumed one-time prekeys on the server — scoped to THIS
    /// device (per-device, so a 2nd device doesn't see the 1st's keys and skip upload).
    private func availableCount(deviceId: String) async throws -> Int {
        let res: CountResponse = try await api.request("GET", "prekeys/count?device_id=\(deviceId)")
        return res.available
    }

    /// Upload public one-time prekeys with MONOTONIC key ids (the server keys on
    /// (device_id, key_id) with do-nothing-on-conflict, so ids must never repeat
    /// across uploads or replenished keys would be silently dropped).
    private func uploadPrekeys(deviceId: String, keys: [String]) async throws {
        guard !keys.isEmpty else { return }
        var nextId = Int(kc.string(prekeyNextIdName) ?? "") ?? Self.prekeyIdBase
        let otks = keys.map { k -> OTK in let o = OTK(key_id: nextId, public_key: k); nextId += 1; return o }
        kc.set(String(nextId), prekeyNextIdName)
        let _: EmptyResponse = try await api.request(
            "POST", "prekeys/upload", body: PrekeysBody(device_id: deviceId, one_time_prekeys: otks))
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
