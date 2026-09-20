//
//  BackupManager.swift
//  Voiid
//
//  Orchestrates the encrypted backup / recovery feature end-to-end, tying the
//  e2e-core FFI (generate/wrap/unwrap/encrypt/decrypt) to the two transport
//  services and local keychain storage. The views (BackupRecoveryView, the setup
//  flow, the login-restore sheet) drive THIS — they never touch the FFI directly.
//
//  Security invariants:
//   - The master secret only exists in memory during a flow and in the shared
//     keychain (AfterFirstUnlockThisDeviceOnly) once backup is set up.
//   - The PIN is never persisted or logged; it only ever feeds wrap/unwrap.
//   - The backup blob is sealed under the master secret before upload; the server
//     stores opaque ciphertext.
//

import Foundation
import Combine

enum BackupRestoreError: LocalizedError {
    case wrongPin, invalidPhrase
    var errorDescription: String? {
        switch self {
        case .wrongPin: return "Wrong PIN. Please try again."
        case .invalidPhrase: return "Invalid recovery phrase. Check the words and try again."
        }
    }
}

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    private init() {}

    private let recovery = RecoveryService.shared
    private let backup = BackupService.shared

    /// True once this device holds the backup master secret locally (backup is set
    /// up, or a restore has completed).
    var hasLocalSecret: Bool { E2EManager.shared.masterSecret() != nil }

    private func saveSecret(_ secret: Data) throws {
        E2EManager.shared.saveMasterSecret(secret)
        guard E2EManager.shared.masterSecret() == secret else {
            throw APIError.http(status: 500, message: "Couldn’t save the backup key on this device. Keep your recovery phrase and retry.")
        }
    }

    // MARK: - Destinations

    /// The transport service for each destination. `.server` is the always-available
    /// default; `.iCloud` is the opt-in cloud location for the SAME
    /// encrypted blob.
    private func service(for destination: BackupDestination) -> BackupDestinationService {
        switch destination {
        case .server:      return backup
        case .iCloud:      return ICloudBackupService.shared
        case .googleDrive: return GoogleDriveBackupService.shared
        }
    }

    // MARK: Automatic backup schedule

    /// When an automatic backup is allowed to run.
    ///
    /// Default is `.wifiOnly`. A backup carries the user's whole message history, and doing
    /// that over mobile data without being asked spends money that is not ours to spend —
    /// so the permissive option exists, but nobody lands on it by accident.
    enum BackupNetwork: String, CaseIterable, Identifiable {
        case wifiOnly
        case wifiAndCellular
        case manualOnly

        var id: String { rawValue }

        var title: String {
            switch self {
            case .wifiOnly:        return "Wi-Fi only"
            case .wifiAndCellular: return "Wi-Fi and mobile data"
            case .manualOnly:      return "Manual only"
            }
        }

        var detail: String {
            switch self {
            case .wifiOnly:
                return "Backs up automatically, but only on Wi-Fi."
            case .wifiAndCellular:
                return "Backs up automatically on any connection. May use your data allowance."
            case .manualOnly:
                return "Never backs up on its own. You choose when, with Back up now."
            }
        }

        var isAutomatic: Bool { self != .manualOnly }
    }

    /// How often an automatic backup runs.
    enum BackupFrequency: String, CaseIterable, Identifiable {
        case daily
        case weekly

        var id: String { rawValue }
        var title: String { self == .daily ? "Daily" : "Weekly" }
        var interval: TimeInterval { self == .daily ? 86_400 : 604_800 }
    }

    private static var networkKey: String { "voiid.backup.network.\(TokenStore.shared.userId ?? "signed-out")" }
    private static var frequencyKey: String { "voiid.backup.frequency.\(TokenStore.shared.userId ?? "signed-out")" }
    private static var includePhotosKey: String { "voiid.backup.includePhotos.\(TokenStore.shared.userId ?? "signed-out")" }

    /// Bumped on any schedule change so SwiftUI redraws the settings rows.
    @Published private var scheduleRevision = 0

    var backupNetwork: BackupNetwork {
        get {
            BackupNetwork(rawValue: UserDefaults.standard.string(forKey: Self.networkKey) ?? "")
                ?? .wifiOnly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.networkKey)
            scheduleRevision += 1
        }
    }

    var backupFrequency: BackupFrequency {
        get {
            BackupFrequency(rawValue: UserDefaults.standard.string(forKey: Self.frequencyKey) ?? "")
                ?? .daily
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: Self.frequencyKey)
            scheduleRevision += 1
        }
    }

    /// Whether photo bytes ride along in the backup blob.
    ///
    /// Off by default, and video is deliberately NOT offered: a backup is a single sealed
    /// blob uploaded in one go, and video would push it to hundreds of megabytes, which
    /// fails often enough that it would make backup itself unreliable.
    var includesPhotos: Bool {
        get { UserDefaults.standard.bool(forKey: Self.includePhotosKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.includePhotosKey)
            scheduleRevision += 1
        }
    }

    /// When the next automatic backup is due, or nil when backup is manual-only or has never
    /// run. Derived rather than stored — a stored "next" date goes stale the moment the user
    /// changes frequency or backs up by hand.
    func nextBackupDate(after last: Date?) -> Date? {
        guard backupNetwork.isAutomatic, let last else { return nil }
        return last.addingTimeInterval(backupFrequency.interval)
    }

    /// UserDefaults key for the set of user-enabled optional destinations. `.server` is
    /// implicit-on and never stored.
    private static var enabledKey: String { "voiid.backup.enabledDestinations.\(TokenStore.shared.userId ?? "signed-out")" }

    /// Destinations the user has opted into, in addition to the always-on server. Published
    /// so the settings UI reacts. `.server` is always considered enabled.
    @Published private var enabledRevision = 0
    var optionalEnabled: Set<BackupDestination> {
        get { Self.loadEnabled() }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.enabledKey)
            enabledRevision += 1
        }
    }

    private static func loadEnabled() -> Set<BackupDestination> {
        let raw = UserDefaults.standard.stringArray(forKey: enabledKey) ?? []
        return Set(raw.compactMap { BackupDestination(rawValue: $0) }).intersection([.iCloud])
    }

    /// Every destination the blob should currently be written to.
    var enabledDestinations: Set<BackupDestination> { optionalEnabled.union([.server]) }

    func isEnabled(_ destination: BackupDestination) -> Bool {
        destination.isServer || optionalEnabled.contains(destination)
    }

    /// Turn an optional destination on/off. Persists the choice. The server can't be disabled.
    /// Enabling triggers an immediate backup to that destination if backup is already set up;
    /// a failure there is surfaced to the caller but never disturbs the other destinations.
    func setEnabled(_ destination: BackupDestination, _ on: Bool) async throws {
        guard !destination.isServer else { return }
        guard destination == .iCloud else {
            throw APIError.http(status: 400, message: "Use iCloud for cloud backups on iPhone.")
        }
        if on, let secret = E2EManager.shared.masterSecret() {
            let plaintext = try ChatEngine.shared.exportStore()
            let blob = try encryptBackup(secret: secret, plaintext: plaintext)
            try await service(for: destination).uploadBackup(blob)
        }
        if on { optionalEnabled.insert(destination) } else { optionalEnabled.remove(destination) }
        UserDefaults.standard.set(optionalEnabled.map(\.rawValue), forKey: Self.enabledKey)
    }

    // MARK: - Setup

    /// Step 1 of setup: mint a fresh master secret and its 24-word phrase. Nothing is
    /// persisted or uploaded yet — the caller shows the phrase and waits for the user
    /// to confirm they've written it down before calling `commitSetup`.
    func newSecretAndPhrase() throws -> (secret: Data, phrase: String) {
        let secret = generateMasterSecret()
        let phrase = try masterSecretToPhrase(secret: secret)
        return (secret, phrase)
    }

    /// Step 2 of setup: wrap the secret under the PIN, store the wrap server-side,
    /// persist the secret locally, then take a first backup. Idempotent enough to
    /// retry on transient failure.
    func commitSetup(secret: Data, pin: String) async throws {
        if E2EManager.shared.masterSecret() != secret, try await status() != nil {
            throw APIError.http(status: 409, message: "A backup already exists. Restore it before setting up a new backup.")
        }
        let wrapped = try wrapMasterSecretWithPin(secret: secret, pin: pin)
        try await recovery.putKey(wrapped)
        try saveSecret(secret)
        try await backupNow()
    }

    // MARK: - Backup

    /// Seal the current message store under the local master secret and upload the SAME
    /// ciphertext blob to every enabled destination. Requires backup to be set up (throws
    /// if there's no local secret).
    ///
    /// Defensive fan-out: the server backup is authoritative — if it's enabled and fails,
    /// that error is thrown. iCloud/Drive are best-effort: their failures are collected but
    /// do NOT disturb the server backup or crash. If the server is disabled (user chose only
    /// iCloud/Drive) and every enabled destination fails, the first failure is thrown.
    func backupNow() async throws {
        guard let secret = E2EManager.shared.masterSecret() else {
            throw APIError.http(status: 412, message: "Set up backup before backing up.")
        }
        let plaintext = try ChatEngine.shared.exportStore()
        // The blob is ALWAYS the encryptBackup ciphertext — identical bytes to every
        // destination. Google/Apple/our server only ever see this.
        let blob = try encryptBackup(secret: secret, plaintext: plaintext)

        var failures: [BackupDestination: Error] = [:]
        for destination in enabledDestinations {
            do { try await service(for: destination).uploadBackup(blob) }
            catch { failures[destination] = error }
        }

        if isEnabled(.server), let serverError = failures[.server] {
            throw serverError            // server is the default; its failure is real.
        }
        if !isEnabled(.server), failures.count == enabledDestinations.count,
           let firstError = failures.values.first {
            throw firstError             // no server fallback and everything failed.
        }
        if !failures.isEmpty {
            let names = failures.keys.map(\.title).sorted().joined(separator: ", ")
            throw APIError.http(status: 503, message: "Server backup saved, but these copies failed: \(names). Retry to update them.")
        }
    }

    /// Current server backup status (last-backup time/size), or nil when none exists. Kept
    /// for the existing UI / login-restore trigger, which key off the server.
    func status() async throws -> BackupMeta? {
        try await backup.fetchBackupMeta()
    }

    /// Per-destination snapshots for the settings UI. An unavailable/empty destination maps
    /// to nil; a destination that errors is swallowed to nil (never breaks the screen).
    func snapshots() async -> [BackupDestination: BackupSnapshot] {
        var out: [BackupDestination: BackupSnapshot] = [:]
        for destination in [BackupDestination.server, .iCloud] {
            if let snap = try? await service(for: destination).fetchSnapshot() {
                out[destination] = snap
            }
        }
        return out
    }

    /// Destinations that currently hold a backup, newest first — the restore candidates.
    func restoreCandidates() async -> [(destination: BackupDestination, snapshot: BackupSnapshot)] {
        let snaps = await snapshots()
        return snaps.map { ($0.key, $0.value) }
            .sorted { ($0.snapshot.modified ?? .distantPast) > ($1.snapshot.modified ?? .distantPast) }
    }

    // MARK: - Recovery phrase (re-show) / Change PIN

    /// The 24-word recovery phrase for the locally-stored master secret, or nil if
    /// backup isn't set up on this device.
    func currentPhrase() throws -> String? {
        guard let secret = E2EManager.shared.masterSecret() else { return nil }
        return try masterSecretToPhrase(secret: secret)
    }

    /// Re-wrap the existing local master secret under a new PIN and store it. The
    /// master secret (and therefore the recovery phrase + existing backup) is
    /// unchanged — only the PIN that unlocks it changes.
    func changePin(newPin: String) async throws {
        guard let secret = E2EManager.shared.masterSecret() else {
            throw APIError.http(status: 412, message: "Set up backup before changing the PIN.")
        }
        let wrapped = try wrapMasterSecretWithPin(secret: secret, pin: newPin)
        try await recovery.putKey(wrapped)
    }

    // MARK: - Login restore

    /// Restore via PIN. Fetches the wrap (may throw `RecoveryError.locked`/`.notSet`),
    /// unwraps with the PIN, reports the attempt result to the server (success/failure),
    /// then downloads + decrypts + merges the message store and persists the secret.
    /// A wrong PIN / tampered wrap THROWS (GCM auth) — the attempt is reported as failed
    /// before the error is re-thrown, and the caller shows the message.
    /// - Parameter source: which destination to pull the sealed blob from (default `.server`).
    ///   The PIN wrap always comes from the server recovery lock regardless of `source`.
    func restoreWithPin(_ pin: String, from source: BackupDestination = .server) async throws {
        // `getKey` can throw before we ever attempt an unwrap (locked / not-set /
        // transport) — those are NOT failed PIN attempts, so don't report them.
        let wrapped = try await recovery.getKey()
        let secret: Data
        do {
            secret = try unwrapMasterSecretWithPin(wrapped: wrapped, pin: pin)
        } catch {
            await recovery.reportAttempt(success: false)
            throw BackupRestoreError.wrongPin
        }
        await recovery.reportAttempt(success: true)
        try await restore(with: secret, from: source)
    }

    /// Restore via the 24-word recovery phrase. `phraseToMasterSecret` validates the
    /// BIP39 phrase (throws on an invalid one), then we restore as usual. No PIN
    /// attempt is reported (the phrase path doesn't touch the server lock).
    func restoreWithPhrase(_ phrase: String, from source: BackupDestination = .server) async throws {
        let secret: Data
        do { secret = try phraseToMasterSecret(phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { throw BackupRestoreError.invalidPhrase }
        try await restore(with: secret, from: source)
    }

    /// Shared tail of both restore paths: download the sealed blob, decrypt it with
    /// the recovered secret (throws if the secret is wrong — GCM auth), merge the
    /// messages into the local store, and persist the secret so future backups work.
    private func restore(with secret: Data, from source: BackupDestination = .server) async throws {
        let blob = try await service(for: source).downloadBackup()
        let plaintext = try decryptBackup(secret: secret, blob: blob)
        try await ChatEngine.shared.importStore(plaintext)
        try saveSecret(secret)
    }
}
