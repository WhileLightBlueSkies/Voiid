//
//  RestoreMessagesView.swift
//  Voiid
//
//  Login-restore flow, shown to a returning user right after login when the server
//  has a backup for their account (a fresh install wiped the local E2E keychain, so
//  this is exactly when restore is needed). Two recovery paths — PIN or the 24-word
//  recovery phrase — plus a "Skip" that proceeds without restoring. On success it
//  merges the restored messages, persists the master secret, and calls `onFinish`.
//

import SwiftUI

struct RestoreMessagesView: View {
    let meta: BackupMeta
    /// Called when the user finishes (restored) OR skips — both proceed into the app.
    let onFinish: () -> Void

    private enum Step { case choose, pin, phrase, working }
    @State private var step: Step = .choose
    @State private var errorText: String?
    @State private var busy = false

    // Which destination to pull the sealed blob from. Defaults to the newest available
    // backup across server / iCloud / Google Drive. The PIN/phrase still unlock the same
    // master secret regardless of source.
    @State private var source: BackupDestination = .server
    @State private var candidates: [(destination: BackupDestination, snapshot: BackupSnapshot)] = []

    var body: some View {
        ZStack {
            VoiidBackground()
            switch step {
            case .choose: chooser
            case .pin:
                PinEntryView(title: "Enter your PIN",
                             subtitle: "Restore your chats from your encrypted backup.",
                             errorText: errorText, busy: busy) { restoreWithPin($0) }
            case .phrase:
                PhraseEntryView(errorText: errorText, busy: busy) { restoreWithPhrase($0) }
            case .working:
                VStack(spacing: VoiidSpacing.md) {
                    ProgressView().tint(VoiidColor.primary)
                    Text("Restoring your chats…").font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                }
            }
        }
    }

    // MARK: Chooser

    private var chooser: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            Spacer().frame(height: VoiidSpacing.lg)
            Image(systemName: "arrow.clockwise.icloud")
                .font(.system(size: 44, weight: .light))
                .foregroundColor(VoiidColor.primary)
            Text("Restore your messages?").font(VoiidFont.title).foregroundColor(VoiidColor.textPrimary)
            Text("We found a backup from \(BackupRecoveryView.relative(meta.updatedAtDate)) (\(BackupRecoveryView.size(meta.size_bytes))). Restore it to get your chats back on this device.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)

            if candidates.count > 1 { sourcePicker }

            if let errorText { Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error) }

            Spacer()

            VoiidPrimaryButton(title: "Enter PIN") { Haptics.tap(); errorText = nil; step = .pin }
            Button("Use recovery phrase instead") { Haptics.tap(); errorText = nil; step = .phrase }
                .font(VoiidFont.headline).foregroundColor(VoiidColor.primary)
                .frame(maxWidth: .infinity)
            Button("Skip for now") { Haptics.tap(); onFinish() }
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                .frame(maxWidth: .infinity)
                .padding(.top, VoiidSpacing.xs)
        }
        .padding(VoiidSpacing.lg)
        .task { await loadCandidates() }
    }

    /// Lets the user choose which location to restore from when more than one has a backup.
    private var sourcePicker: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text("Restore from").font(VoiidFont.footnote).foregroundColor(VoiidColor.textSecondary)
            ForEach(candidates, id: \.destination.id) { candidate in
                Button {
                    Haptics.tap(); source = candidate.destination
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: source == candidate.destination ? "largecircle.fill.circle" : "circle")
                            .foregroundColor(source == candidate.destination ? VoiidColor.primary : VoiidColor.textSecondary)
                        Image(systemName: candidate.destination.systemImage).foregroundColor(VoiidColor.textSecondary)
                        Text(candidate.destination.title).font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                        Text(BackupRecoveryView.relative(candidate.snapshot.modified))
                            .font(VoiidFont.footnote).foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, VoiidSpacing.xs)
    }

    private func loadCandidates() async {
        let found = await BackupManager.shared.restoreCandidates()
        candidates = found
        source = found.first?.destination ?? .server   // newest by default
    }

    // MARK: Actions

    private func restoreWithPin(_ pin: String) {
        busy = true; errorText = nil
        Task {
            do {
                try await BackupManager.shared.restoreWithPin(pin, from: source)
                finishRestored()
            } catch let e as RecoveryError {
                // Locked / not-set — surface directly (not a wrong-PIN case).
                errorText = e.errorDescription
                busy = false; Haptics.error()
            } catch {
                // Wrong PIN / tampered wrap / download-decrypt failure. The attempt was
                // already reported as failed inside restoreWithPin.
                errorText = "Wrong PIN. Please try again — attempts are limited."
                busy = false; Haptics.error()
            }
        }
    }

    private func restoreWithPhrase(_ phrase: String) {
        busy = true; errorText = nil
        Task {
            do {
                try await BackupManager.shared.restoreWithPhrase(phrase, from: source)
                finishRestored()
            } catch {
                errorText = "That recovery phrase didn’t work. Check the words and try again."
                busy = false; Haptics.error()
            }
        }
    }

    private func finishRestored() {
        busy = false
        Haptics.success()
        step = .working
        onFinish()
    }
}
