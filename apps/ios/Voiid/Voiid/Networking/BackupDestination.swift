//
//  BackupDestination.swift
//  Voiid
//
//  The destination-agnostic layer for the encrypted backup blob. The blob is and
//  stays the `encryptBackup(masterSecret, plaintext)` ciphertext (e2e-core) — the
//  destinations below are just *storage locations* for that opaque blob. None of
//  them ever see the master secret or the plaintext:
//
//    - `.server`      → our R2-backed backend (BackupService), the always-available
//                       default. Never regresses if the user has no Google/iCloud.
//    - `.iCloud`      → the app's private iCloud Documents container
//                       (ICloudBackupService). Apple only stores ciphertext.
//    - `.googleDrive` → the user's own Drive `appDataFolder`
//                       (GoogleDriveBackupService). Google only stores ciphertext.
//
//  Each destination is an opt-in the user toggles independently in Backup &
//  Recovery settings; `.server` stays on so nothing regresses. `BackupManager`
//  fans the same blob out to every enabled destination and, on restore, prefers
//  whichever destination holds the newest snapshot.
//

import Foundation

/// The storage locations the encrypted backup blob can live in.
enum BackupDestination: String, CaseIterable, Identifiable, Sendable {
    case server
    case iCloud
    case googleDrive

    var id: String { rawValue }

    /// Human title for settings / restore rows.
    var title: String {
        switch self {
        case .server:      return "VOIID server backup"
        case .iCloud:      return "iCloud backup"
        case .googleDrive: return "Google Drive backup"
        }
    }

    /// SF Symbol for the row.
    var systemImage: String {
        switch self {
        case .server:      return "server.rack"
        case .iCloud:      return "icloud"
        case .googleDrive: return "externaldrive.badge.icloud"
        }
    }

    /// The server destination is the always-on default and can't be turned off.
    var isServer: Bool { self == .server }
}

/// A destination-agnostic view of "what backup is currently stored here", used to
/// pick the newest snapshot on restore and to show per-destination status. Deliberately
/// smaller than the server's `BackupMeta` (no presigned URL): iCloud/Drive download
/// their own bytes directly.
struct BackupSnapshot: Sendable {
    let sizeBytes: Int
    let modified: Date?
}

/// The contract every backup destination fulfils. `uploadBackup` and `downloadBackup`
/// move the SAME encrypted blob; `fetchSnapshot` reports what (if anything) is stored,
/// returning nil when the destination is empty or unavailable (e.g. iCloud signed out,
/// Drive not authorized) — an unavailable destination is a disabled feature, never a crash.
protocol BackupDestinationService: Sendable {
    /// Upload the sealed ciphertext blob, overwriting any previous backup at this destination.
    func uploadBackup(_ blob: Data) async throws
    /// Metadata for the stored blob, or nil if none / destination unavailable.
    func fetchSnapshot() async throws -> BackupSnapshot?
    /// Download the sealed ciphertext blob previously uploaded here.
    func downloadBackup() async throws -> Data
}

// The existing server transport already speaks this shape; adapt its richer
// `BackupMeta` down to the destination-agnostic `BackupSnapshot`.
extension BackupService: BackupDestinationService {
    func fetchSnapshot() async throws -> BackupSnapshot? {
        guard let meta = try await fetchBackupMeta() else { return nil }
        return BackupSnapshot(sizeBytes: meta.size_bytes, modified: meta.updatedAtDate)
    }
}
