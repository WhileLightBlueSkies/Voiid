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

@MainActor
final class BackupManager: ObservableObject {
    static let shared = BackupManager()
    private init() {}

    private let recovery = RecoveryService.shared
    private let backup = BackupService.shared

    /// True once this device holds the backup master secret locally (backup is set
    /// up, or a restore has completed).
    var hasLocalSecret: Bool { E2EManager.shared.masterSecret() != nil }

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
        let wrapped = try wrapMasterSecretWithPin(secret: secret, pin: pin)
        try await recovery.putKey(wrapped)
        E2EManager.shared.saveMasterSecret(secret)
        try await backupNow()
    }

    // MARK: - Backup

    /// Seal the current message store under the local master secret and upload it.
    /// Requires backup to be set up (throws if there's no local secret).
    func backupNow() async throws {
        guard let secret = E2EManager.shared.masterSecret() else {
            throw APIError.http(status: 412, message: "Set up backup before backing up.")
        }
        let plaintext = ChatEngine.shared.exportStore()
        let blob = try encryptBackup(secret: secret, plaintext: plaintext)
        try await backup.uploadBackup(blob)
    }

    /// Current backup status (last-backup time/size), or nil when none exists.
    func status() async throws -> BackupMeta? {
        try await backup.fetchBackupMeta()
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
    func restoreWithPin(_ pin: String) async throws {
        // `getKey` can throw before we ever attempt an unwrap (locked / not-set /
        // transport) — those are NOT failed PIN attempts, so don't report them.
        let wrapped = try await recovery.getKey()
        let secret: Data
        do {
            secret = try unwrapMasterSecretWithPin(wrapped: wrapped, pin: pin)
        } catch {
            await recovery.reportAttempt(success: false)
            throw error
        }
        await recovery.reportAttempt(success: true)
        try await restore(with: secret)
    }

    /// Restore via the 24-word recovery phrase. `phraseToMasterSecret` validates the
    /// BIP39 phrase (throws on an invalid one), then we restore as usual. No PIN
    /// attempt is reported (the phrase path doesn't touch the server lock).
    func restoreWithPhrase(_ phrase: String) async throws {
        let secret = try phraseToMasterSecret(phrase: phrase)
        try await restore(with: secret)
    }

    /// Shared tail of both restore paths: download the sealed blob, decrypt it with
    /// the recovered secret (throws if the secret is wrong — GCM auth), merge the
    /// messages into the local store, and persist the secret so future backups work.
    private func restore(with secret: Data) async throws {
        let blob = try await backup.downloadBackup()
        let plaintext = try decryptBackup(secret: secret, blob: blob)
        ChatEngine.shared.importStore(plaintext)
        E2EManager.shared.saveMasterSecret(secret)
    }
}
