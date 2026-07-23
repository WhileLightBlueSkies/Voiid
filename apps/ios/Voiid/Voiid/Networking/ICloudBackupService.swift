//
//  ICloudBackupService.swift
//  Voiid
//
//  iCloud destination for the encrypted backup blob. Uses the app's private iCloud
//  Documents (ubiquity) container — NO external SDK, iOS-native only. The single
//  fixed file `voiid-backup.enc` inside `Documents/` holds the exact
//  `encryptBackup(masterSecret, plaintext)` ciphertext; Apple only ever stores the
//  opaque blob (the master secret and plaintext never leave the device).
//
//  Requires the iCloud Documents capability + a ubiquity container entitlement
//  (`iCloud.com.voiid.app`) on the target — see Voiid/Voiid.entitlements. When iCloud
//  is signed-out / unavailable the container URL is nil; every method degrades
//  gracefully (feature disabled, never a crash): `fetchSnapshot` returns nil, and
//  upload/download throw a clear, catchable error that the caller treats as
//  "iCloud not available" without disturbing the server backup.
//

import Foundation

/// Errors specific to the iCloud destination. All are non-fatal: the caller keeps the
/// server backup working and simply reports iCloud as unavailable.
enum ICloudBackupError: LocalizedError {
    case unavailable
    case noBackup
    case downloadTimedOut

    var errorDescription: String? {
        switch self {
        case .unavailable:      return "iCloud isn’t available. Sign in to iCloud in Settings to use iCloud backup."
        case .noBackup:         return "No iCloud backup was found."
        case .downloadTimedOut: return "Timed out downloading the iCloud backup. Check your connection and try again."
        }
    }
}

/// Writes/reads the encrypted blob to the app's iCloud Documents container.
///
/// `Sendable` via `@unchecked`: it holds only immutable constants and does all its
/// filesystem work through `FileManager`/`NSFileCoordinator`, which are thread-safe.
final class ICloudBackupService: BackupDestinationService, @unchecked Sendable {
    static let shared = ICloudBackupService()
    private init() {}

    /// Ubiquity container id. MUST match the `com.apple.developer.icloud-container-identifiers`
    /// / `ubiquity-container-identifiers` entitlement (Voiid/Voiid.entitlements).
    static let containerID = "iCloud.com.voiid.app"

    /// Fixed backup filename inside the container's `Documents/`.
    private static let filename = "voiid-backup.enc"

    /// Max seconds to wait for an evicted ubiquitous item to download before giving up.
    private static let downloadTimeout: TimeInterval = 30

    /// `true` if the current user has iCloud available for this container. Cheap best-effort
    /// check; the authoritative signal is whether `containerURL` resolves.
    var isAvailable: Bool { FileManager.default.ubiquityIdentityToken != nil }

    // MARK: URLs (resolved off the main actor — these calls can block on first use)

    /// The container's `Documents/` URL, creating the directory if needed. Nil when iCloud
    /// is signed-out / the entitlement isn't provisioned.
    private func documentsURL() -> URL? {
        let fm = FileManager.default
        guard let container = fm.url(forUbiquityContainerIdentifier: Self.containerID) else {
            return nil
        }
        let docs = container.appendingPathComponent("Documents", isDirectory: true)
        if !fm.fileExists(atPath: docs.path) {
            try? fm.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }

    private func backupURL() -> URL? { documentsURL()?.appendingPathComponent(Self.filename) }

    // MARK: BackupDestinationService

    /// Coordinated write of the ciphertext blob to `Documents/voiid-backup.enc`, replacing
    /// any previous backup. Runs off the main actor because ubiquity-URL resolution can block.
    func uploadBackup(_ blob: Data) async throws {
        try await runOffMain {
            guard let url = self.backupURL() else { throw ICloudBackupError.unavailable }
            var coordinatorError: NSError?
            var writeError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forReplacing,
                                   error: &coordinatorError) { writeURL in
                do { try blob.write(to: writeURL, options: .atomic) }
                catch { writeError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let writeError { throw writeError }
        }
    }

    /// Size + modified time of the stored blob, or nil if none / iCloud unavailable.
    /// Never throws for the "unavailable" case — iCloud being off is a normal state.
    func fetchSnapshot() async throws -> BackupSnapshot? {
        try await runOffMain {
            guard let url = self.backupURL() else { return nil }
            let fm = FileManager.default
            // The item may be present but not yet downloaded; either way its metadata is
            // readable from the ubiquitous placeholder.
            guard fm.fileExists(atPath: url.path) else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey,
                                                           .totalFileSizeKey,
                                                           .contentModificationDateKey])
            let size = values?.totalFileSize ?? values?.fileSize ?? 0
            return BackupSnapshot(sizeBytes: size, modified: values?.contentModificationDate)
        }
    }

    /// Trigger + await download of a possibly-evicted ubiquitous item, then coordinated read.
    func downloadBackup() async throws -> Data {
        try await runOffMain {
            guard let url = self.backupURL() else { throw ICloudBackupError.unavailable }
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { throw ICloudBackupError.noBackup }

            // Kick off download if the item is only a placeholder locally.
            try? fm.startDownloadingUbiquitousItem(at: url)

            // Poll the download status until current (or timeout). Simpler and just as
            // reliable here as an NSMetadataQuery for a single known file.
            let deadline = Date().addingTimeInterval(Self.downloadTimeout)
            while Date() < deadline {
                let values = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
                if let status = values?.ubiquitousItemDownloadingStatus,
                   status == .current || status == .downloaded {
                    break
                }
                try? await Task.sleep(nanoseconds: 300_000_000)
            }

            var coordinatorError: NSError?
            var readData: Data?
            var readError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(readingItemAt: url, options: [], error: &coordinatorError) { readURL in
                do { readData = try Data(contentsOf: readURL) }
                catch { readError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let readError { throw readError }
            guard let data = readData else { throw ICloudBackupError.downloadTimedOut }
            return data
        }
    }

    /// Delete the iCloud backup (used by "disable iCloud backup" — the blob is the user's).
    func deleteBackup() async throws {
        try await runOffMain {
            guard let url = self.backupURL() else { return }
            let fm = FileManager.default
            guard fm.fileExists(atPath: url.path) else { return }
            var coordinatorError: NSError?
            var deleteError: Error?
            let coordinator = NSFileCoordinator()
            coordinator.coordinate(writingItemAt: url, options: .forDeleting,
                                   error: &coordinatorError) { deleteURL in
                do { try fm.removeItem(at: deleteURL) }
                catch { deleteError = error }
            }
            if let coordinatorError { throw coordinatorError }
            if let deleteError { throw deleteError }
        }
    }

    // MARK: Helpers

    /// Run blocking FileManager/ubiquity work off the main thread.
    private func runOffMain<T: Sendable>(_ work: @escaping @Sendable () async throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try await work() }.value
    }
}
