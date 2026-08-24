//
//  BackupRecoveryView.swift
//  Voiid
//
//  Backup & Recovery settings: shows backup status and drives every backup flow —
//  first-time setup (PIN → recovery phrase → first backup), manual "Back up now",
//  re-showing the recovery phrase, and changing the PIN. All crypto goes through
//  BackupManager; this file is pure SwiftUI.
//

import SwiftUI

// MARK: - Settings screen

struct BackupRecoveryView: View {
    @StateObject private var manager = BackupManager.shared

    @State private var loadingStatus = true
    @State private var meta: BackupMeta?
    @State private var statusError: String?

    @State private var backingUp = false
    @State private var actionError: String?
    @State private var toast: String?

    @State private var showSetup = false
    @State private var showPhrase = false
    @State private var showChangePin = false

    // Additional destinations (iCloud / Google Drive) for the SAME encrypted blob.
    @State private var destSnapshots: [BackupDestination: BackupSnapshot] = [:]
    @State private var togglingDestination: BackupDestination?
    @State private var destError: String?

    private var isSetUp: Bool { manager.hasLocalSecret }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    // The badge is truthful: the blob is encrypted on-device before it
                    // leaves, and the footer below states the consequence.
                    VoiidSettingsHeader("Backup & Recovery",
                                        subtitle: "Back up your chats so a new device can "
                                                + "restore them.",
                                        badge: (icon: "lock.fill", text: "End-to-end encrypted"))

                    statusCard

                    if isSetUp {
                        VoiidCardSection {
                            actionRow(title: backingUp ? "Backing up…" : "Back up now",
                                      system: "arrow.up.circle", enabled: !backingUp) { backUpNow() }
                        }
                        destinationsCard
                        VoiidCardSection {
                            actionRow(title: "View recovery phrase", system: "key") { showPhrase = true }
                            VoiidRowDivider()
                            actionRow(title: "Change PIN", system: "lock.rotation") { showChangePin = true }
                        }
                    } else {
                        VoiidCardSection {
                            actionRow(title: "Set up backup", system: "checkmark.shield") { showSetup = true }
                        }
                    }

                    if let actionError {
                        Text(actionError)
                            .font(.footnote)
                            .foregroundColor(VoiidColor.error)
                            .padding(.horizontal, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Your messages are encrypted on this device before backup. Only your PIN or recovery phrase can restore them — VOIID can’t read your backup or recover it for you.")
                        .font(.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.top, VoiidSpacing.sm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(VoiidSpacing.md)
            }
            .voiidSettingsPage()

            if let toast { ToastBanner(text: toast) }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $showSetup, onDismiss: { Task { await refreshStatus() } }) {
            BackupSetupFlow { showSetup = false; flash("Backup is set up") }
        }
        .sheet(isPresented: $showPhrase) { RecoveryPhraseSheet() }
        .sheet(isPresented: $showChangePin) { ChangePinSheet { flash("PIN changed") } }
    }

    // MARK: Status card

    private var statusCard: some View {
        VoiidCardSection {
            HStack(spacing: VoiidSpacing.md) {
                VoiidRowIcon(systemName: isSetUp ? "checkmark.shield.fill" : "shield.slash")

                VStack(alignment: .leading, spacing: 2) {
                    Text(isSetUp ? "Backup is on" : "Backup is off")
                        .font(.body)
                        .foregroundColor(VoiidColor.textPrimary)

                    if let meta, !loadingStatus {
                        Text("Last backup \(Self.relative(meta.updatedAtDate)) · \(Self.size(meta.size_bytes))")
                            .font(.footnote)
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let statusError, !loadingStatus {
                        Text(statusError)
                            .font(.footnote)
                            .foregroundColor(VoiidColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if !loadingStatus {
                        Text(isSetUp ? "No backup uploaded yet." : "Set up backup to protect your chats.")
                            .font(.footnote)
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: VoiidSpacing.sm)

                if loadingStatus { ProgressView().tint(VoiidColor.primary) }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 11)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: Additional destinations (iCloud / Google Drive)

    private var destinationsCard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            VoiidCardSection(
                "Additional backup locations",
                footer: "The same encrypted backup is copied to each location you turn on. "
                      + "iCloud and Google only ever store the encrypted file — never your "
                      + "PIN, phrase, or messages."
            ) {
                destinationRow(.iCloud,
                               available: ICloudBackupService.shared.isAvailable,
                               unavailableNote: "Sign in to iCloud in Settings to enable.")
                VoiidRowDivider()
                destinationRow(.googleDrive,
                               available: GoogleDriveBackupService.shared.isSignedIn,
                               unavailableNote: "Requires Google sign-in setup.")
            }

            if let destError {
                Text(destError)
                    .font(.footnote)
                    .foregroundColor(VoiidColor.error)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func destinationRow(_ destination: BackupDestination, available: Bool,
                                unavailableNote: String) -> some View {
        let isOn = manager.isEnabled(destination)
        let busy = togglingDestination == destination
        HStack(spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: destination.systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(destination.title).font(.body).foregroundColor(VoiidColor.textPrimary)
                if let snap = destSnapshots[destination], isOn {
                    Text("Last backup \(Self.relative(snap.modified)) · \(Self.size(snap.sizeBytes))")
                        .font(.footnote).foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else if !available {
                    Text(unavailableNote).font(.footnote).foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: VoiidSpacing.sm)
            if busy {
                ProgressView().tint(VoiidColor.primary)
            } else {
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in toggleDestination(destination, newValue) }
                ))
                .labelsHidden()
                .tint(VoiidColor.primary)
                .disabled(!available)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .opacity(available ? 1 : 0.6)
    }

    private func toggleDestination(_ destination: BackupDestination, _ on: Bool) {
        guard togglingDestination == nil else { return }
        togglingDestination = destination; destError = nil
        Task {
            do {
                try await manager.setEnabled(destination, on)
                await refreshDestinations()
                flash(on ? "\(destination.title) on" : "\(destination.title) off")
            } catch {
                destError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
            togglingDestination = nil
        }
    }

    private func refreshDestinations() async {
        destSnapshots = await manager.snapshots()
    }

    /// One tappable row inside a card. The old hand-rolled button had a `prominent`
    /// variant (filled in the accent) for "Set up backup"; the card idiom carries that
    /// emphasis through the header and the row's own chevron instead, so there is no
    /// second visual style to keep in sync.
    ///
    /// The haptic is fired HERE rather than by `VoiidSettingsRow`: the shared row plays none,
    /// so that a caller whose action has its own heavier haptic does not get a stutter of two.
    /// Every row on this screen opens a sheet, so a plain `tap` is the right one for all four.
    private func actionRow(title: String, system: String,
                           enabled: Bool = true, action: @escaping () -> Void) -> some View {
        VoiidSettingsRow(icon: system, title: title,
                         action: { Haptics.tap(); action() }) {
            VoiidChevron()
        }
        .opacity(enabled ? 1 : 0.55)
        .disabled(!enabled)
    }

    // MARK: Actions

    private func refreshStatus() async {
        loadingStatus = true; statusError = nil
        do { meta = try await manager.status() }
        catch { statusError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        loadingStatus = false
        await refreshDestinations()
    }

    private func backUpNow() {
        guard !backingUp else { return }
        backingUp = true; actionError = nil
        Task {
            do {
                try await manager.backupNow()
                flash("Backed up")
                await refreshStatus()
            } catch {
                actionError = (error as? APIError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
            backingUp = false
        }
    }

    private func flash(_ text: String) {
        Haptics.success()
        toast = text
        Task { try? await Task.sleep(nanoseconds: 1_800_000_000); toast = nil }
    }

    // MARK: Formatting

    static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
    static func relative(_ date: Date?) -> String {
        guard let date else { return "just now" }
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }
}

// MARK: - Toast

private struct ToastBanner: View {
    let text: String
    var body: some View {
        VStack {
            Spacer()
            Text(text)
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textOnPrimary)
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.vertical, VoiidSpacing.sm)
                .background(VoiidColor.primary)
                .clipShape(Capsule())
                .padding(.bottom, VoiidSpacing.xl)
                .shadow(color: .black.opacity(0.15), radius: 8, y: 3)
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

// MARK: - Setup flow (PIN → recovery phrase → first backup)

struct BackupSetupFlow: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step { case pin, phrase, working }
    @State private var step: Step = .pin
    @State private var pin = ""
    @State private var secret = Data()
    @State private var phrase = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidBackground()
                switch step {
                case .pin:
                    PinChooseView(title: "Choose a backup PIN",
                                  subtitle: "You’ll enter this PIN to restore your chats on a new device. 4–8 digits.",
                                  errorText: errorText) { chosen in
                        beginPhrase(pin: chosen)
                    }
                case .phrase:
                    RecoveryPhraseView(phrase: phrase, confirmTitle: "I’ve written it down") {
                        commit()
                    }
                case .working:
                    VStack(spacing: VoiidSpacing.md) {
                        ProgressView().tint(VoiidColor.primary)
                        Text("Setting up backup…").font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                        if let errorText {
                            Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error)
                            Button("Try again") { commit() }.font(VoiidFont.headline).foregroundColor(VoiidColor.primary)
                        }
                    }
                }
            }
            .navigationTitle("Set up backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled(step == .working)
    }

    private func beginPhrase(pin chosen: String) {
        do {
            let made = try BackupManager.shared.newSecretAndPhrase()
            secret = made.secret; phrase = made.phrase; pin = chosen; errorText = nil
            step = .phrase
        } catch {
            errorText = "Couldn’t generate a recovery phrase. Please try again."
        }
    }

    private func commit() {
        step = .working; errorText = nil
        Task {
            do {
                try await BackupManager.shared.commitSetup(secret: secret, pin: pin)
                onDone()
            } catch {
                errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
        }
    }
}

// MARK: - Re-show recovery phrase (from local secret)

struct RecoveryPhraseSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var phrase: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidBackground()
                if let phrase {
                    RecoveryPhraseView(phrase: phrase, confirmTitle: "Done") { dismiss() }
                } else if let errorText {
                    Text(errorText).font(VoiidFont.subhead).foregroundColor(VoiidColor.error).padding()
                } else {
                    ProgressView().tint(VoiidColor.primary)
                }
            }
            .navigationTitle("Recovery phrase")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
        .task {
            do { phrase = try BackupManager.shared.currentPhrase()
                 if phrase == nil { errorText = "Backup isn’t set up on this device." } }
            catch { errorText = "Couldn’t load your recovery phrase." }
        }
    }
}

// MARK: - Change PIN

struct ChangePinSheet: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidBackground()
                if working {
                    ProgressView().tint(VoiidColor.primary)
                } else {
                    PinChooseView(title: "Choose a new PIN",
                                  subtitle: "Your recovery phrase and existing backup stay the same — only the PIN changes.",
                                  errorText: errorText) { pin in change(to: pin) }
                }
            }
            .navigationTitle("Change PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func change(to pin: String) {
        working = true; errorText = nil
        Task {
            do { try await BackupManager.shared.changePin(newPin: pin); onDone(); dismiss() }
            catch {
                errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
                working = false; Haptics.error()
            }
        }
    }
}
