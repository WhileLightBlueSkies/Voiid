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

    private var isSetUp: Bool { manager.hasLocalSecret }

    var body: some View {
        ZStack {
            VoiidBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    statusCard

                    if isSetUp {
                        actionButton(title: backingUp ? "Backing up…" : "Back up now",
                                     system: "arrow.up.circle", enabled: !backingUp) { backUpNow() }
                        actionButton(title: "View recovery phrase", system: "key") { showPhrase = true }
                        actionButton(title: "Change PIN", system: "lock.rotation") { showChangePin = true }
                    } else {
                        actionButton(title: "Set up backup", system: "checkmark.shield",
                                     prominent: true) { showSetup = true }
                    }

                    if let actionError {
                        Text(actionError)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                    }

                    Text("Your messages are encrypted on this device before backup. Only your PIN or recovery phrase can restore them — VOIID can’t read your backup or recover it for you.")
                        .font(VoiidFont.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.top, VoiidSpacing.sm)
                }
                .padding(VoiidSpacing.lg)
            }

            if let toast { ToastBanner(text: toast) }
        }
        .navigationTitle("Backup & Recovery")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshStatus() }
        .sheet(isPresented: $showSetup, onDismiss: { Task { await refreshStatus() } }) {
            BackupSetupFlow { showSetup = false; flash("Backup is set up") }
        }
        .sheet(isPresented: $showPhrase) { RecoveryPhraseSheet() }
        .sheet(isPresented: $showChangePin) { ChangePinSheet { flash("PIN changed") } }
    }

    // MARK: Status card

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: isSetUp ? "checkmark.shield.fill" : "shield.slash")
                    .foregroundColor(isSetUp ? VoiidColor.success : VoiidColor.textSecondary)
                Text(isSetUp ? "Backup is on" : "Backup is off")
                    .font(VoiidFont.headline)
                    .foregroundColor(VoiidColor.textPrimary)
            }
            if loadingStatus {
                ProgressView().tint(VoiidColor.primary)
            } else if let meta {
                Text("Last backup \(Self.relative(meta.updatedAtDate)) · \(Self.size(meta.size_bytes))")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            } else if let statusError {
                Text(statusError).font(VoiidFont.subhead).foregroundColor(VoiidColor.error)
            } else {
                Text(isSetUp ? "No backup uploaded yet." : "Set up backup to protect your chats.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private func actionButton(title: String, system: String, prominent: Bool = false,
                              enabled: Bool = true, action: @escaping () -> Void) -> some View {
        Button(action: { Haptics.tap(); action() }) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: system)
                Text(title).font(VoiidFont.headline)
                Spacer()
                if !prominent { Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)) }
            }
            .foregroundColor(prominent ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 58)
            .frame(maxWidth: .infinity)
            .background(prominent ? VoiidColor.primary : VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .opacity(enabled ? 1 : 0.55)
        }
        .buttonStyle(SoftPressStyle())
        .disabled(!enabled)
    }

    // MARK: Actions

    private func refreshStatus() async {
        loadingStatus = true; statusError = nil
        do { meta = try await manager.status() }
        catch { statusError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        loadingStatus = false
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
