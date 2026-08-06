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
    /// In-memory device id, falling back to the persisted one from a prior bootstrap —
    /// so a message sent before `bootstrap()` finished THIS session still carries our
    /// device_id (the recipient needs it to pick the right sender device on decrypt).
    private var _deviceId: String?
    var deviceId: String? { _deviceId ?? kc.string(deviceIdName) }
    private var bootstrapped = false

    /// Reset the once-per-process bootstrap latch and the in-memory identity.
    ///
    /// `bootstrap()` opens with `if bootstrapped { return }`, so after a sign-out WITHOUT
    /// this the next account's bootstrap is a no-op: the app keeps using the previous
    /// user's `Identity` and device id even though their keychain was wiped, and publishes
    /// prekeys for an identity that no longer exists server-side. Log-out and sign-in
    /// happen in one process lifetime, so the latch must be cleared explicitly.
    func resetForSignOut() {
        identity = nil
        _deviceId = nil
        bootstrapped = false
        // The next account registers a DIFFERENT device row; the token has to be
        // published against it even though its value did not change.
        lastUploadedPushToken = nil
    }

    private let kc = KeychainData(service: "com.voiid.e2e")
    private let pickleKeyName = "identity_pickle_key"   // 32 random bytes
    private let pickleName = "identity_pickle"          // encrypted identity
    private let deviceIdName = "device_id"
    private let regIdName = "registration_id"
    private let prekeyNextIdName = "prekey_next_id"     // monotonic one-time-key id counter
    private let masterSecretName = "master_backup_secret"   // 32-byte backup/recovery master secret

    // MARK: - Backup master secret (recovery)

    /// Persist the 32-byte backup master secret in the shared keychain
    /// (AfterFirstUnlockThisDeviceOnly). A fresh install wipes it — intended, since
    /// restore re-derives it from the PIN-wrapped copy or the recovery phrase.
    func saveMasterSecret(_ secret: Data) { kc.setData(secret, masterSecretName) }

    /// The locally-stored backup master secret, or nil if backup was never set up
    /// (or this is a fresh install before restore).
    func masterSecret() -> Data? { kc.data(masterSecretName) }

    /// Forget the local backup master secret (does not touch the server copy).
    func clearMasterSecret() { kc.delete(masterSecretName) }

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
        // iOS Keychain SURVIVES app uninstall, so a reinstall would silently reuse the
        // old identity + sessions + identity pins — keyed to peers' now-dead identities,
        // making the FIRST message to each peer undecryptable. UserDefaults IS cleared on
        // uninstall, so its absence means "fresh install" → wipe all E2E Keychain state.
        if !UserDefaults.standard.bool(forKey: "voiid_e2e_installed") {
            kc.wipeService()                                  // identity, pickle key, device id, pins
            KeychainData(service: "com.voiid.sessions").wipeService()   // cached Olm sessions
            GroupEngine.shared.wipe()                          // MLS member blob + group map
            NSLog("[VOIID] fresh install detected — wiped stale Keychain E2E state")
            UserDefaults.standard.set(true, forKey: "voiid_e2e_installed")
        }
        do {
            let id = try loadOrCreateIdentity()
            identity = id
            NSLog("[VOIID] bootstrap: identity ready")
            let devId = try await withTransportRetry { try await self.register(id) }
            _deviceId = devId
            NSLog("[VOIID] bootstrap: registered device=\(devId)")
            try await withTransportRetry { try await self.ensurePrekeys(id, devId: devId) }
            NSLog("[VOIID] bootstrap: prekeys ensured")
            // MLS (group messaging): create-or-restore this device's GroupMember and
            // publish KeyPackages. Runs AFTER device registration (needs the device id).
            // Best-effort — a group-key failure must not block 1:1 bootstrap.
            await GroupEngine.shared.bootstrap()
            NSLog("[VOIID] bootstrap: MLS ready")
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

    /// Re-persist the current identity. MUST be called after acceptSession, which
    /// consumes a one-time prekey from the Account — without saving, that consumed
    /// state is lost on restart and the first inbound message becomes undecryptable.
    func persistIdentity() {
        if let id = identity { try? persist(id) }
    }

    /// Restore the identity from the SHARED keychain pickle WITHOUT any network I/O.
    /// Used by the Notification Service Extension: it must never register/replace the
    /// device (that's the app's job) — it only needs the existing Identity to accept
    /// inbound sessions and decrypt. Returns false if there's no identity yet (not
    /// logged in / migration hasn't run) so the NSE can fall back to a placeholder.
    @discardableResult
    func loadForExtension() -> Bool {
        if identity != nil { return true }
        guard let pickle = kc.string(pickleName) else { return false }
        do {
            identity = try Identity.restore(pickle: pickle, pickleKey: pickleKey())
            return true
        } catch {
            NSLog("[VOIID] NSE loadForExtension failed: \(error)")
            return false
        }
    }

    /// Re-restore the identity from the shared keychain pickle so THIS process picks up
    /// one-time-key consumption performed by the OTHER process (app/NSE). Called under
    /// the cross-process lock before accepting inbound sessions — without it, both
    /// processes could consume the same one-time key and desync.
    func reloadIdentity() {
        guard let pickle = kc.string(pickleName) else { return }
        if let restored = try? Identity.restore(pickle: pickle, pickleKey: pickleKey()) {
            identity = restored
        }
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

    // MARK: - APNs alert token
    //
    // `devices.push_token` is what every NON-VoIP wake push is addressed to: message
    // pushes, the ring fallback the backend uses when VoIP is unconfigured or this
    // device has no PushKit token, and group-call invites (which have no VoIP path at
    // all). iOS hands the token over asynchronously and it can change (reinstall,
    // restore from backup), so it is captured here and re-published when it moves.

    /// Latest APNs alert token as lowercase hex. UserDefaults rather than the Keychain:
    /// the Keychain survives uninstall, and a resurrected token addresses a dead install.
    private var pushToken: String? {
        get { UserDefaults.standard.string(forKey: Self.pushTokenKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.pushTokenKey) }
    }
    /// The token the server last accepted — lets us skip no-op re-registrations.
    private var lastUploadedPushToken: String?
    private static let pushTokenKey = "voiid.apns_push_token"

    /// Record the token APNs just issued and publish it. Called from the AppDelegate,
    /// which can fire either side of `bootstrap()` — so this both stores it for the
    /// register inside bootstrap and, when we already have an identity, re-registers now.
    func registerPushToken(_ deviceToken: Data) {
        let hex = deviceToken.map { String(format: "%02x", $0) }.joined()
        if hex != pushToken {
            pushToken = hex
            lastUploadedPushToken = nil
        }
        uploadPushTokenIfNeeded()
    }

    /// Re-publish the stored token when the server hasn't taken it yet. No-ops without a
    /// token, a JWT (not signed in) or an identity — in that last case bootstrap's own
    /// `register` carries the token instead. There is no alert-token-only endpoint; the
    /// device upsert is the single place the backend accepts it.
    func uploadPushTokenIfNeeded(force: Bool = false) {
        guard let hex = pushToken, TokenStore.shared.jwt != nil, let id = identity else { return }
        if !force, lastUploadedPushToken == hex { return }
        Task {
            do { _ = try await withTransportRetry { try await self.register(id) } }
            catch { NSLog("[VOIID] push token publish failed: \(error.localizedDescription)") }
        }
    }

    // MARK: - Publish to backend

    private struct RegisterDeviceBody: Encodable {
        let platform: String
        let registration_id: Int
        let identity_public_key: String
        // Push routing: attached to the SAME device row (the upsert keys on
        // (user_id, registration_id)) so the backend can address a wake push here.
        let push_token: String?
        let push_provider: String?
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
        // Carry whatever APNs token we already hold, so registration/refresh also
        // attaches this device's alert-push endpoint in one call (mirrors Android).
        let token = pushToken
        let dev: DeviceResponse = try await api.request(
            "POST", "devices/register",
            body: RegisterDeviceBody(platform: "ios",
                                     registration_id: registrationId(),
                                     identity_public_key: identityKey,
                                     push_token: token,
                                     push_provider: token == nil ? nil : "apns"))
        _deviceId = dev.device_id
        kc.set(dev.device_id, deviceIdName)
        lastUploadedPushToken = token
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

// MARK: - Minimal generic Keychain store (Data + String), shared across processes

/// Generic-password store scoped to a keychain `service`. All items are placed in
/// the SHARED keychain access group (`SharedKeychain.group`) so the Notification
/// Service Extension (a separate process) can read the same identity/session state.
/// Legacy items written by older builds live in the app-PRIVATE default group and
/// are copied into the shared group once, lazily, on first access (`migrateIfNeeded`).
final class KeychainData {
    private let service: String
    /// Shared access group (`TEAMID.com.voiid.shared`) or nil if unresolved (then we
    /// fall back to app-private behaviour so a mis-provisioned build still works).
    private let accessGroup = SharedKeychain.group
    private var migrated = false

    init(service: String) { self.service = service }

    func setData(_ value: Data, _ key: String) {
        migrateIfNeeded()
        var q = base(key); SecItemDelete(q as CFDictionary)
        q[kSecValueData as String] = value
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(q as CFDictionary, nil)
    }
    func set(_ value: String, _ key: String) { setData(Data(value.utf8), key) }

    func data(_ key: String) -> Data? {
        migrateIfNeeded()
        var q = base(key); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }
    func string(_ key: String) -> String? { data(key).flatMap { String(data: $0, encoding: .utf8) } }
    func delete(_ key: String) { SecItemDelete(base(key) as CFDictionary) }

    /// Delete EVERY item in this Keychain service — in BOTH the shared access group
    /// AND the legacy app-private default group. iOS Keychain survives app uninstall,
    /// so a reinstall would otherwise reuse a stale identity/sessions; call on a
    /// detected fresh install for a truly clean slate (and suppress the legacy→shared
    /// migration that would otherwise copy the stale items back in).
    func wipeService() {
        migrated = true   // nothing to migrate after a wipe
        // Shared group.
        if let accessGroup {
            SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                           kSecAttrService as String: service,
                           kSecAttrAccessGroup as String: accessGroup] as CFDictionary)
        }
        // Legacy app-private default group (no access group specified).
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service] as CFDictionary)
    }

    private func base(_ key: String) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        return q
    }

    /// One-time copy of this service's app-private items into the shared access group,
    /// so existing installs keep decrypting after the app-group upgrade. Idempotent:
    /// items already in the shared group are skipped (errSecDuplicateItem). Legacy
    /// copies are left in place (app-private, harmless) rather than risk data loss.
    private func migrateIfNeeded() {
        guard !migrated, let accessGroup else { migrated = true; return }
        migrated = true
        // Enumerate ALL entitled items for this service, with their access group.
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let items = out as? [[String: Any]] else { return }
        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                  let data = item[kSecValueData as String] as? Data else { continue }
            // Skip items already in the shared group.
            if (item[kSecAttrAccessGroup as String] as? String) == accessGroup { continue }
            var add: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
                kSecAttrAccessGroup as String: accessGroup,
                kSecValueData as String: data,
                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            ]
            let status = SecItemAdd(add as CFDictionary, nil)
            if status == errSecDuplicateItem { add[kSecValueData as String] = nil }  // already shared
        }
    }
}
