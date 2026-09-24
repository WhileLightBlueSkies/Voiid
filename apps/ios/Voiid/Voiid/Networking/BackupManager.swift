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

    @Published private(set) var progressLabel = "Preparing backup…"
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

    /// Account-scoped destination preferences; the explicit key stores all choices, including none.
    private static var enabledKey: String { "voiid.backup.enabledDestinations.\(TokenStore.shared.userId ?? "signed-out")" }

    /// Publish changes so all destination toggles and backup actions update together.
    @Published private var enabledRevision = 0
    var optionalEnabled: Set<BackupDestination> {
        get { Self.loadEnabled() }
        set {
            UserDefaults.standard.set(newValue.map(\.rawValue), forKey: Self.enabledKey + ".explicit")
            enabledRevision += 1
        }
    }

    private static func loadEnabled() -> Set<BackupDestination> {
        let defaults = UserDefaults.standard
        let choiceKey = enabledKey + ".explicit"
        if let saved = defaults.stringArray(forKey: choiceKey) {
            return Set(saved.compactMap(BackupDestination.init(rawValue:))).intersection([.server, .iCloud])
        }
        // Preserve existing installations' destinations; new setup begins with no selection.
        let legacy = Set((defaults.stringArray(forKey: enabledKey) ?? []).compactMap(BackupDestination.init(rawValue:)))
        let migrated = E2EManager.shared.masterSecret() == nil ? legacy : legacy.union([.server])
        defaults.set(migrated.map(\.rawValue), forKey: choiceKey)
        return migrated.intersection([.server, .iCloud])
    }

    var enabledDestinations: Set<BackupDestination> { optionalEnabled }
    func isEnabled(_ destination: BackupDestination) -> Bool { enabledDestinations.contains(destination) }

    func setEnabled(_ destination: BackupDestination, _ on: Bool) async throws {
        guard destination == .server || destination == .iCloud else {
            throw APIError.http(status: 400, message: "Use iCloud for cloud backups on iPhone.")
        }
        if on && destination == .iCloud && !ICloudBackupService.shared.isAvailable {
            throw APIError.http(status: 400, message: "Sign in to iCloud in Settings first.")
        }
        var choices = enabledDestinations
        if on { choices.insert(destination) } else { choices.remove(destination) }
        optionalEnabled = choices
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

    /// Step 2 of setup, once the person has proved they wrote the phrase down: persist the
    /// secret locally and take a first backup. The phrase is the ONLY way back in — no PIN
    /// wrap is created (S04: a short PIN wrapped key could be guessed offline by anyone who
    /// got hold of it). Idempotent enough to retry on transient failure.
    func commitSetup(secret: Data) async throws {
        guard !enabledDestinations.isEmpty else { throw APIError.http(status: 400, message: "Choose a backup location first.") }
        if E2EManager.shared.masterSecret() != secret {
            let serverCopy = try await status()
            let cloudCopy = ICloudBackupService.shared.isAvailable ? try await service(for: .iCloud).fetchSnapshot() : nil
            if serverCopy != nil || cloudCopy != nil {
                throw APIError.http(status: 409, message: "A backup already exists. Restore it before setting up a new backup.")
            }
        }
        try saveSecret(secret)
        // A wrap left from an older version would still be guessable; the new phrase has
        // replaced it. Best-effort — the backup itself does not depend on this.
        try? await recovery.deleteKey()
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
        let destinations = enabledDestinations
        guard !destinations.isEmpty else { throw APIError.http(status: 400, message: "Backup is off. Choose a location first.") }
        guard let secret = E2EManager.shared.masterSecret() else {
            throw APIError.http(status: 412, message: "Set up backup before backing up.")
        }
        progressLabel = "Encrypting your chats…"
        let plaintext = try ChatEngine.shared.exportStore()
        // The blob is ALWAYS the encryptBackup ciphertext — identical bytes to every
        // destination. Google/Apple/our server only ever see this.
        let blob = try await Task.detached(priority: .userInitiated) { try encryptBackup(secret: secret, plaintext: plaintext) }.value

        var failures: [BackupDestination: Error] = [:]
        for destination in destinations.sorted(by: { $0.rawValue < $1.rawValue }) {
            do {
                progressLabel = "Uploading to \(destination == .server ? "Voiid server" : "iCloud")…"
                try await service(for: destination).uploadBackup(blob)
            }
            catch { failures[destination] = error }
        }

        if destinations.contains(.server), let serverError = failures[.server] {
            throw serverError            // server is the default; its failure is real.
        }
        if !destinations.contains(.server), failures.count == destinations.count,
           let firstError = failures.values.first {
            throw firstError             // no server fallback and everything failed.
        }
        if !failures.isEmpty {
            let names = failures.keys.map(\.title).sorted().joined(separator: ", ")
            throw APIError.http(status: 503, message: "Backup failed for these locations: \(names). Retry to update them.")
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

    /// Whether this account still has an old PIN-protected copy of its key on the server.
    func hasLegacyPin() async -> Bool {
        (try? await recovery.hasPinWrap()) ?? false
    }

    /// Delete the old PIN-protected copy, after the person has saved their phrase. From then
    /// on only the 24-word phrase can restore their backup.
    func retireLegacyPin() async throws {
        try await recovery.deleteKey()
    }

    /// Device-local, account-scoped completion; never mark a skipped or failed restore.
    var lastCompletedRestore: Date? {
        guard let account = TokenStore.shared.userId else { return nil }
        return UserDefaults.standard.object(forKey: "voiid.restore.completed.\(account)") as? Date
    }

    var pendingRestoreSource: BackupDestination? {
        UserDefaults.standard.string(forKey: "voiid.restore.source.\(TokenStore.shared.userId ?? "")").flatMap(BackupDestination.init(rawValue:))
    }

    // MARK: - Login restore

    /// Restore via PIN. Fetches the wrap (may throw `RecoveryError.locked`/`.notSet`),
    /// unwraps with the PIN, reports the attempt result to the server (success/failure),
    /// then downloads + decrypts + merges the message store and persists the secret.
    /// A wrong PIN / tampered wrap THROWS (GCM auth) — the attempt is reported as failed
    /// before the error is re-thrown, and the caller shows the message.
    /// - Parameter source: which destination to pull the sealed blob from (default `.server`).
    ///   The PIN wrap always comes from the server recovery lock regardless of `source`.
    func restoreWithPin(_ pin: String, from source: BackupDestination = .server, onProgress: (Int) -> Void = { _ in }) async throws {
        _ = enabledDestinations // Resolve migration before saving a restored key.
        onProgress(0)
        let secret = try await unlockBackupPin(pin)
        try await restore(with: secret, from: source, onProgress: onProgress)
    }

    /// Authenticate before presenting backup selection; keep the key in memory only.
    func unlockBackupPin(_ pin: String) async throws -> Data {
        // `getKey` can throw before we ever attempt an unwrap (locked / not-set /
        // transport) — those are NOT failed PIN attempts, so don't report them.
        let wrapped = try await recovery.getKey()
        let secret: Data
        do {
            secret = try await Task.detached(priority: .userInitiated) { try unwrapMasterSecretWithPin(wrapped: wrapped, pin: pin) }.value
        } catch {
            await recovery.reportAttempt(success: false)
            throw BackupRestoreError.wrongPin
        }
        await recovery.reportAttempt(success: true)
        return secret
    }

    /// Restore via the 24-word recovery phrase. `phraseToMasterSecret` validates the
    /// BIP39 phrase (throws on an invalid one), then we restore as usual. No PIN
    /// attempt is reported (the phrase path doesn't touch the server lock).
    func restoreWithPhrase(_ phrase: String, from source: BackupDestination = .server, onProgress: (Int) -> Void = { _ in }) async throws {
        _ = enabledDestinations // Resolve migration before saving a restored key.
        onProgress(0)
        let secret: Data
        do { secret = try phraseToMasterSecret(phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines)) }
        catch { throw BackupRestoreError.invalidPhrase }
        try await restore(with: secret, from: source, onProgress: onProgress)
    }

    /// Shared tail of both restore paths: download the sealed blob, decrypt it with
    /// the recovered secret (throws if the secret is wrong — GCM auth), merge the
    /// messages into the local store, and persist the secret so future backups work.
    func restore(with secret: Data, from source: BackupDestination = .server, onProgress: (Int) -> Void) async throws {
        _ = enabledDestinations // Resolve migration before saving a restored key.
        UserDefaults.standard.set(source.rawValue, forKey: "voiid.restore.source.\(TokenStore.shared.userId ?? "")")
        onProgress(1)
        let blob = try await service(for: source).downloadBackup()
        onProgress(2)
        let plaintext = try await Task.detached(priority: .userInitiated) { try decryptBackup(secret: secret, blob: blob) }.value
        onProgress(3)
        try await ChatEngine.shared.importStore(plaintext)
        onProgress(4)
        try saveSecret(secret)
        if let account = TokenStore.shared.userId {
            UserDefaults.standard.set(Date(), forKey: "voiid.restore.completed.\(account)")
            // Commit routing at the successful restore boundary, before any UI delay/dismissal.
            UserDefaults.standard.set(true, forKey: "voiid.recovery.ready.\(account)")
        }
    }
}
