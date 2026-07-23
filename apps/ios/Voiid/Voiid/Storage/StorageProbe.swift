//
//  StorageProbe.swift
//  Voiid
//
//  Measures what Voiid actually occupies on this device, and clears the only two
//  things on it that are genuinely re-derivable.
//
//  WHY A PROBE TYPE AT ALL: a Storage screen is worthless unless its numbers are
//  measured rather than asserted, and measuring means a filesystem walk plus a
//  database read — both blocking, neither allowed on the main actor. Everything
//  here is computed in ONE detached task and handed back as a `Sendable` struct of
//  plain Ints, so the view renders a value it cannot recompute by accident on a
//  body pass. This mirrors the house pattern at `ICloudBackupService.runOffMain`.
//  Nothing in this file is `@MainActor`, deliberately.
//
//  WHAT IS DELIBERATELY NOT HERE
//  -----------------------------
//  There is no "clear message history", no "clear database", no keychain wipe and
//  no media-cache clear, because none of them can be offered honestly:
//
//   * `voiid_messages.json` is LIVE, not legacy. `ChatEngine.persist()` rewrites the
//     whole file on every append and receipt, the NSE writes it cross-process, and
//     `BackupManager.backupNow()` seals exactly that dictionary as the plaintext of
//     the encrypted cloud backup. Deleting it means (a) ChatEngine re-persists a
//     stale copy over you, and (b) the next backup uploads an empty store over the
//     user's last off-device copy. The server's ciphertext is already past those
//     ratchet steps and can never be decrypted again.
//   * Deleting `messages`/`conversations` rows loses the same plaintext, and
//     `LocalStore.importLegacyMessageBlobIfNeeded()` is gated on a UserDefaults flag
//     that is already true on any live install — so it never re-runs and the user is
//     left with an empty chat grid on top of a full message file.
//   * Clearing `users` NULLs `conversations.peer_user_id` (`onDelete: .setNull`), and
//     direct-chat titles are resolved from that column at read time, so every direct
//     chat degrades to "Unknown" and does not self-heal.
//   * `MediaCache` (ChatDetailView) is two in-memory dictionaries with no disk
//     backing. A "free up media" action would free zero bytes on disk.
//
//  So `clearCaches()` clears exactly `URLCache.shared` and orphaned `voiid_vn_*.m4a`
//  scratch files. Both are pure caches; both come back on their own.
//

import Foundation
import GRDB

// MARK: - Snapshot

/// One measurement of local storage. Plain `Int`s so it crosses the concurrency
/// boundary as a value with nothing to race on.
///
/// Counts are `Int?` on purpose: if the database can't be opened (missing App Group
/// entitlement, first-run failure) the honest answer is "unknown", and the screen
/// renders an em dash. Reporting `0` would be a small lie, and the whole point of
/// this screen is that its numbers are true.
struct StorageSnapshot: Sendable {
    /// Everything in the App Group container, walked file by file.
    let containerTotalBytes: Int
    /// `voiid.sqlite` + `voiid.sqlite-wal` + `voiid.sqlite-shm`, summed. Reported as
    /// ONE number: WAL siblings are real disk usage and can each reach tens of MB,
    /// but splitting them into three rows explains nothing to a person.
    let databaseBytes: Int
    /// `voiid_messages.json` — the decrypted message store the NSE and ChatEngine share.
    let messageHistoryBytes: Int

    let conversationCount: Int?
    let messageCount: Int?
    let callCount: Int?

    /// `URLCache.shared.currentDiskUsage`. Small by nature — every R2 download URL is
    /// presigned and unique per request, so almost nothing is ever a cache hit. The
    /// screen shows the real number anyway; padding it would be the lie.
    let webCacheBytes: Int
    /// Orphaned voice-note scratch files in the temporary directory.
    let temporaryFileBytes: Int

    /// Whatever in the container isn't the database or the message store — the lock
    /// file and any slack. Exists so the itemised rows visibly add up to the total
    /// instead of leaving an unexplained gap.
    var otherBytes: Int {
        max(0, containerTotalBytes - databaseBytes - messageHistoryBytes)
    }

    /// Bytes `clearCaches()` can actually reclaim. Drives the Clear button's enabled state.
    var clearableBytes: Int { webCacheBytes + temporaryFileBytes }
}

// MARK: - Probe

enum StorageProbe {

    // MARK: Measure

    /// Measure everything in a single detached task. Never call the private `measureSync`
    /// from the main actor.
    static func measure() async -> StorageSnapshot {
        await Task.detached(priority: .utility) { measureSync() }.value
    }

    private static func measureSync() -> StorageSnapshot {
        // `VoiidDatabase.databaseURL` is a computed static var that calls
        // `createDirectory` as a side effect — idempotent and harmless, but one more
        // reason this runs off the main actor. It resolves to the App Group container,
        // falling back to Application Support when the entitlement is missing.
        let dbURL = VoiidDatabase.databaseURL
        let databaseBytes =
            allocatedSize(of: dbURL)
            // NOT `appendingPathExtension` — the WAL siblings are hyphen-suffixed paths.
            + allocatedSize(of: URL(fileURLWithPath: dbURL.path + "-wal"))
            + allocatedSize(of: URL(fileURLWithPath: dbURL.path + "-shm"))

        let messageHistoryBytes = AppGroup.messageStoreURL.map(allocatedSize(of:)) ?? 0

        // If the App Group entitlement is missing the database lives outside the
        // container, so a container walk would under-report. `max` keeps "Other"
        // from going negative and keeps the arithmetic on screen honest.
        let walked = AppGroup.containerURL.map(directoryAllocatedSize(of:)) ?? 0
        let containerTotal = max(walked, databaseBytes + messageHistoryBytes)

        // One read, three counts. `VoiidDatabase` is a plain final class and GRDB's
        // DatabasePool is thread-safe, so this is legal from a detached task. Do not
        // route through `LocalStore` — it is a @MainActor enum with no count helpers.
        let counts = VoiidDatabase.shared.read { db -> (Int, Int, Int) in
            let conversations = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM conversations") ?? 0
            let messages      = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM messages") ?? 0
            let calls         = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM call_history") ?? 0
            return (conversations, messages, calls)
        }

        return StorageSnapshot(
            containerTotalBytes: containerTotal,
            databaseBytes: databaseBytes,
            messageHistoryBytes: messageHistoryBytes,
            conversationCount: counts?.0,
            messageCount: counts?.1,
            callCount: counts?.2,
            // An Int property, not a filesystem walk.
            webCacheBytes: URLCache.shared.currentDiskUsage,
            temporaryFileBytes: orphanedVoiceNoteURLs().reduce(0) { $0 + allocatedSize(of: $1) }
        )
    }

    // MARK: Clear

    /// Clears the two genuinely re-derivable caches, off the main actor. Both are
    /// re-created on demand: the URL cache by the next request, a voice-note scratch
    /// file by the next recording.
    static func clearCaches() async {
        await Task.detached(priority: .utility) {
            URLCache.shared.removeAllCachedResponses()
            let fm = FileManager.default
            for url in orphanedVoiceNoteURLs() {
                try? fm.removeItem(at: url)
            }
        }.value
    }

    // MARK: Orphaned voice notes

    /// Scratch files left behind by `VoiceNote`.
    ///
    /// `VoiceNote.stop()` deletes its recording — but only *after*
    /// `guard dur >= 0.5, let url = fileURL, let data = try? Data(contentsOf: url)`,
    /// so any tap shorter than half a second, or any read failure, orphans the file
    /// forever. That is a real, slowly-growing leak and the only safe-to-delete
    /// filesystem residue the app has.
    ///
    /// Scoped by prefix AND extension: never the whole temporary directory, which is
    /// shared with URLSession downloads and anything else the system parks there.
    ///
    /// - Parameter minimumAge: skip files touched recently, so a recording that is
    ///   still being written (AVAudioRecorder updates the modification date as it
    ///   appends) is never deleted out from under the recorder.
    static func orphanedVoiceNoteURLs(minimumAge: TimeInterval = 120) -> [URL] {
        let keys: [URLResourceKey] = [
            .isRegularFileKey, .contentModificationDateKey,
            .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey,
        ]
        let tmp = FileManager.default.temporaryDirectory
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: tmp, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        let cutoff = Date().addingTimeInterval(-minimumAge)
        return items.filter { url in
            guard url.lastPathComponent.hasPrefix("voiid_vn_"),
                  url.pathExtension.lowercased() == "m4a",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true
            else { return false }
            return (values.contentModificationDate ?? .distantPast) < cutoff
        }
    }

    // MARK: Sizing

    private static let sizeKeys: Set<URLResourceKey> = [
        .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey,
    ]

    /// On-disk allocation for one file — what Settings › iPhone Storage approximates.
    /// Block-rounded, so a one-byte file reads as 4 KB; that is genuinely the space it
    /// occupies, and using the same measure for every file is what lets the itemised
    /// rows sum exactly to the container total.
    private static func allocatedSize(of url: URL) -> Int {
        guard let values = try? url.resourceValues(forKeys: sizeKeys),
              values.isRegularFile == true else { return 0 }
        return values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
    }

    /// Recursive sum for a directory.
    ///
    /// The `errorHandler` returning `true` is not optional here: the database files
    /// carry `.completeUntilFirstUserAuthentication` protection and other items may be
    /// unreadable at any moment, and a nil handler aborts the entire walk on the first
    /// failure — turning one unreadable file into a total of zero.
    private static func directoryAllocatedSize(of directory: URL) -> Int {
        let keys = Array(sizeKeys)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else { return 0 }

        var total = 0
        for case let url as URL in enumerator {
            total += allocatedSize(of: url)
        }
        return total
    }
}
