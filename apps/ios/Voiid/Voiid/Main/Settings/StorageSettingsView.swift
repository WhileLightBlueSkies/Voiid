//
//  StorageSettingsView.swift
//  Voiid
//
//  Settings › Storage (spec §5.4).
//
//  Every number on this screen is measured, never asserted. `StorageProbe.measure()`
//  walks the App Group container, reads three row counts in one GRDB read and reads
//  `URLCache.shared.currentDiskUsage`, all inside a single detached task, and hands
//  back a `Sendable` struct of plain Ints. Nothing is recomputed on a body pass.
//
//  Two rules this screen exists to honour:
//
//   1. Never render `0 B` before measurement. Until the snapshot lands, the real row
//      structure is drawn with `.redacted(reason: .placeholder)` — a shape, not a
//      number. A zero the user reads as fact and we haven't measured is a small lie,
//      and this is the one screen where a small lie discredits every other figure.
//
//   2. Offer only what can actually be reclaimed. "Clear Caches" clears exactly
//      `URLCache.shared` and orphaned `voiid_vn_*.m4a` scratch files, and is disabled
//      when those total zero. It is `VoiidColor.primary`, not destructive red, because
//      nothing it removes is unrecoverable. See `StorageProbe` for the full account of
//      what is deliberately absent (message history, database rows, keychain, media)
//      and why each one is impossible to offer honestly.
//
//  The Section 1 footer carries the single most useful fact on the screen: media is
//  never written to this device at all. `MediaService.download` returns Data,
//  `ChatEngine.fetchMedia` decrypts in memory, and `MediaCache` is two in-memory
//  dictionaries. So there is no media cache row here — there is nothing to clear, and
//  a row claiming otherwise would free zero bytes.
//

import SwiftUI

struct StorageSettingsView: View {

    /// `nil` until the first measurement completes — the redaction trigger.
    @State private var snapshot: StorageSnapshot?
    @State private var backup: BackupRow = .loading
    @State private var isMeasuring = false
    @State private var isClearing = false

    /// What the cloud-backup row currently knows. `couldNotCheck` is a real state and
    /// says so, rather than borrowing "Not set up" and misreporting a network failure
    /// as an absent backup.
    private enum BackupRow {
        case loading
        case notSetUp
        case present(bytes: Int, date: Date?)
        case couldNotCheck
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader("Storage",
                                    subtitle: "Every number here is measured on this device, "
                                            + "never estimated.")

                onThisDevice
                contents
                caches
                backupSection
            }
            .padding(VoiidSpacing.md)
        }
        .voiidSettingsPage()
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if isMeasuring && snapshot == nil {
                    ProgressView()
                        .tint(VoiidColor.primary)
                        .accessibilityLabel("Measuring storage")
                }
            }
        }
        .task {
            await measure()
            await loadBackup()
        }
        .refreshable {
            await measure()
            await loadBackup()
        }
    }

    // MARK: - Section 1 — On this device

    private var onThisDevice: some View {
        VoiidCardSection(
            "On this device",
            footer: """
                Your messages are stored on this device so chats open instantly and work \
                offline. Photos, videos and voice notes are never written to this device — \
                they're downloaded and decrypted only while you're looking at them.
                """
        ) {
            metric("Total", icon: "internaldrive", bytes(\.containerTotalBytes), emphasised: true)
            VoiidRowDivider()
            metric("Database", icon: "cylinder.split.1x2", bytes(\.databaseBytes))
            VoiidRowDivider()
            metric("Message history", icon: "bubble.left.and.bubble.right", bytes(\.messageHistoryBytes))
            VoiidRowDivider()
            metric("Other", icon: "folder", bytes(\.otherBytes))
        }
    }

    // MARK: - Section 2 — Contents

    private var contents: some View {
        VoiidCardSection(
            "Contents",
            footer: "Counted from this device's database. These numbers stay on your phone and aren't reported anywhere."
        ) {
            metric("Conversations", icon: "text.bubble", count(\.conversationCount))
            VoiidRowDivider()
            metric("Messages", icon: "envelope", count(\.messageCount))
            VoiidRowDivider()
            metric("Calls logged", icon: "phone", count(\.callCount))
        }
    }

    // MARK: - Section 3 — Caches

    private var caches: some View {
        VoiidCardSection(
            "Caches",
            footer: "Clearing removes only files Voiid can create or download again. Your messages, media and backups aren't affected."
        ) {
            metric("Web cache", icon: "globe", bytes(\.webCacheBytes))
            VoiidRowDivider()
            metric("Temporary files", icon: "doc", bytes(\.temporaryFileBytes))
            VoiidRowDivider()
            clearButton
        }
    }

    private var clearButton: some View {
        // Not `destructive: true`: nothing this removes is unrecoverable, so it stays on the
        // accent rather than borrowing the red that means "this cannot be undone".
        VoiidSettingsRow(
            icon: "trash",
            title: "Clear Caches",
            action: {
                Haptics.rigid()
                Task {
                    isClearing = true
                    await StorageProbe.clearCaches()
                    await measure()
                    isClearing = false
                    Haptics.success()
                }
            }
        ) {
            if isClearing {
                ProgressView().tint(VoiidColor.primary)
            }
        }
        .disabled(isClearing || (snapshot?.clearableBytes ?? 0) == 0)
        .accessibilityLabel("Clear caches")
        .accessibilityHint("Removes the web cache and leftover temporary files")
    }

    // MARK: - Section 4 — Backup

    private var backupSection: some View {
        VoiidCardSection(
            "Backup",
            footer: "Backups are stored encrypted off this device, so they don't count towards the storage above."
        ) {
            VoiidSettingsRow(icon: "icloud", title: "Cloud backup") {
                backupValue
            }

            VoiidRowDivider()

            NavigationLink(value: SettingsRoute.backup) {
                HStack(spacing: VoiidSpacing.md) {
                    VoiidRowIcon(systemName: "arrow.clockwise.icloud")
                    Text("Backup & Recovery")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                    VoiidChevron()
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    @ViewBuilder
    private var backupValue: some View {
        switch backup {
        case .loading:
            ProgressView()
                .tint(VoiidColor.primary)
                .accessibilityLabel("Checking backup")
        case .notSetUp:
            Text("Not set up")
                .font(.subheadline)
                .foregroundStyle(VoiidColor.textSecondary)
        case .couldNotCheck:
            Text("Couldn't check")
                .font(.subheadline)
                .foregroundStyle(VoiidColor.textSecondary)
        case let .present(bytes, date):
            let size = Int64(bytes).formatted(.byteCount(style: .file))
            let when = date.map { $0.formatted(date: .abbreviated, time: .omitted) }
            Text(when.map { "\(size) · \($0)" } ?? size)
                .font(.subheadline)
                .foregroundStyle(VoiidColor.textSecondary)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Rows
    //
    // Not a styling vocabulary — no card, no divider, no colours this screen invents.
    // It composes `VoiidSettingsRow` (it composed `LabeledContent` before the card rebuild;
    // the shared row now supplies the leading icon and the trailing slot) and does the two
    // things every numeric row here needs
    // identically: monospaced digits, so a refresh doesn't jitter the layout, and
    // placeholder redaction of the VALUE only, so section headers and footers stay
    // readable while the measurement is still running.

    @ViewBuilder
    private func metric(_ title: String, icon: String, _ value: String,
                        emphasised: Bool = false) -> some View {
        let measured = snapshot != nil
        VoiidSettingsRow(icon: icon, title: title) {
            Text(value)
                .font(emphasised ? .subheadline.weight(.semibold) : .subheadline)
                .foregroundStyle(emphasised ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                .monospacedDigit()
                .redacted(reason: measured ? [] : .placeholder)
                .accessibilityLabel(measured ? value : "Measuring")
        }
    }

    /// Formatted byte count, or a width-holder that is only ever seen redacted.
    private func bytes(_ keyPath: KeyPath<StorageSnapshot, Int>) -> String {
        guard let snapshot else { return "00.0 MB" }
        return Int64(snapshot[keyPath: keyPath]).formatted(.byteCount(style: .file))
    }

    /// Formatted row count. An em dash means the database could not be opened — the
    /// honest answer, where `0` would claim the tables are empty.
    private func count(_ keyPath: KeyPath<StorageSnapshot, Int?>) -> String {
        guard let snapshot else { return "0000" }
        guard let value = snapshot[keyPath: keyPath] else { return "—" }
        return value.formatted(.number)
    }

    // MARK: - Loading

    private func measure() async {
        isMeasuring = true
        snapshot = await StorageProbe.measure()
        isMeasuring = false
    }

    private func loadBackup() async {
        // Local and synchronous: no secret means backup was never set up, and there is
        // nothing to ask the server about.
        guard BackupManager.shared.hasLocalSecret else {
            backup = .notSetUp
            return
        }
        do {
            if let meta = try await BackupManager.shared.status() {
                backup = .present(bytes: meta.size_bytes, date: meta.updatedAtDate)
            } else {
                backup = .notSetUp
            }
        } catch {
            backup = .couldNotCheck
        }
    }
}
