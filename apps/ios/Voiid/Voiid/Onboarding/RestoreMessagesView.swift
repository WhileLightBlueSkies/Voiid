//
//  RestoreMessagesView.swift
//  Voiid
//
//  The three-page restore flow, shown to a returning user right after login when a backup
//  exists for their account (a fresh install wiped the local E2E keychain, so this is exactly
//  when restore is needed).
//
//      1. UNLOCK   — the V PIN, or the 24-word recovery phrase
//      2. CHOOSE   — which backup to restore from, when more than one destination has one
//      3. RESTORING — named stages while the blob downloads and decrypts
//
//  Built to the design source (`Voiid Ui/Screens/RestoreAccountScreen`, `ChooseBackupScreen`,
//  `RestoringScreen`) through `OnboardingKit`.
//
//  ── THE V PIN IS NOT THE SMS CODE ───────────────────────────────────────────────
//  They look identical — six boxes — and they are opposites. The SMS code proves the user holds
//  the SIM; the PIN proves they are the account owner. Someone who steals a SIM passes the first
//  and fails the second, which is the entire point of asking for both.
//
//  Two consequences here:
//    * the digits are MASKED. An SMS code is fine on screen, a PIN is not.
//    * there is NO autofill and no `.oneTimeCode`. A PIN never arrives by SMS, so offering to
//      fill it from a message would be offering to fill it from an attacker's message.
//
//  ── THE PIN NEVER LEAVES THE DEVICE ─────────────────────────────────────────────
//  The screen tells the user "only you know it", and that is true rather than reassuring
//  copy: `BackupManager.restoreWithPin` uses the PIN to Argon2id-unwrap a locally-held
//  `PinWrappedSecret` (012_recovery.sql). A wrong PIN fails the GCM tag ON DEVICE. It is never
//  posted anywhere, so that sentence stays honest.
//
//  ── "RECOMMENDED" IS EARNED, NOT ASSIGNED ───────────────────────────────────────
//  The badge goes to whichever backup is NEWEST, because that is the only honest basis for
//  recommending one: restoring from the older backup silently loses everything between the two
//  dates. It is not hardcoded to the server.
//
//  ── WHAT THE RESTORING PAGE DOES AND DOES NOT CLAIM ─────────────────────────────
//  The design source drives a byte-accurate percentage from the caller. `BackupManager` reports
//  NO progress — `restoreWithPin` is one opaque async call — so a percentage here would be a
//  number the app does not have, animated on a timer. The reference is explicit that inventing
//  one is worse than showing none, so this shows the STAGES instead, which are real: each is a
//  distinct step that can fail on its own, and the list advances as they actually complete.
//  If `BackupManager` ever reports bytes, the percentage belongs here and not before.
//

import SwiftUI

struct RestoreMessagesView: View {
    let meta: BackupMeta
    /// Called when the user finishes (restored) OR skips — both proceed into the app.
    let onFinish: () -> Void

    /// Where the user is in the flow.
    private enum Step: Equatable { case unlock, phrase, choose, restoring }

    @State private var step: Step = .unlock
    /// Whether this account still has an old PIN-protected copy of its key (pre-S04). Only
    /// then is a PIN offered; every newer backup restores with the recovery phrase alone.
    @State private var legacyPin: Bool?
    @State private var errorText: String?
    @State private var busy = false

    /// Which destination to pull the sealed blob from. Defaults to the newest available backup
    /// across server / iCloud. The PIN or phrase unlocks the same master secret
    /// regardless of source.
    @State private var source: BackupDestination = .server
    @State private var candidates: [(destination: BackupDestination, snapshot: BackupSnapshot)] = []

    /// The unlocked credential, held between step 1 and step 3.
    ///
    /// The PIN is taken FIRST and the source chosen second, which is the reference's order and
    /// also the safer one: a user who cannot unlock never sees a list of their own backups.
    private enum Credential: Equatable { case pin(String), phrase(String) }
    @State private var credential: Credential?
    @State private var unlockedSecret: Data?

    /// Which restore stage is running. Drives the list on the third page.
    @State private var stageIndex = 0
    @State private var confirmSkip = false

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            switch step {
            case .unlock where legacyPin == nil:
                ProgressView().tint(VoiidBrand.lime)
            case .unlock:    UnlockPage(meta: meta,
                                        errorText: errorText,
                                        busy: busy,
                                        onSubmit: { unlock(.pin($0)) },
                                        onRecoveryPhrase: { guard !busy else { return }; errorText = nil; step = .phrase },
                                        onSkip: { guard !busy else { return }; confirmSkip = true })
            case .phrase:    PhrasePage(errorText: errorText,
                                        busy: busy,
                                        onSubmit: { unlock(.phrase($0)) },
                                        onBack: legacyPin == true
                                            ? { guard !busy else { return }; errorText = nil; step = .unlock }
                                            : nil,
                                        onSkip: { guard !busy else { return }; confirmSkip = true })
            case .choose:    ChoosePage(candidates: candidates,
                                        selected: $source,
                                        errorText: errorText,
                                        onRefresh: { Task { await loadCandidates() } },
                                        onRestore: { begin() },
                                        onSetUpAsNew: { confirmSkip = true })
            case .restoring: RestoringPage(stageIndex: stageIndex,
                                           source: source,
                                           errorText: errorText,
                                           onRetry: { begin() },
                                           onSkip: { guard !busy else { return }; confirmSkip = true })
            }
        }
        .confirmationDialog("Continue without restoring?", isPresented: $confirmSkip, titleVisibility: .visible) {
            Button("Continue without restoring") { onFinish() }
            Button("Cancel", role: .cancel) { }
        } message: { Text("Previous chats will not be restored on this device. Your saved backups stay in their current locations.") }
        .interactiveDismissDisabled(true)
        .task { await loadCandidates() }
        .task {
            let legacy = await BackupManager.shared.hasLegacyPin()
            legacyPin = legacy
            if !legacy, step == .unlock { step = .phrase }
        }
    }

    // MARK: Candidates

    private func loadCandidates() async {
        let found = await BackupManager.shared.restoreCandidates()
        candidates = found
        source = BackupManager.shared.pendingRestoreSource.flatMap { saved in found.contains(where: { $0.destination == saved }) ? saved : nil } ?? found.first?.destination ?? .server   // newest by default
    }

    // MARK: Actions

    /// Verify the PIN before allowing backup selection.
    private func unlock(_ c: Credential) {
        guard !busy else { return }
        busy = true
        credential = nil
        unlockedSecret = nil
        errorText = nil
        Task {
            defer { busy = false }
            do {
                switch c {
                case .pin(let pin):
                    unlockedSecret = try await BackupManager.shared.unlockBackupPin(pin)
                case .phrase(let phrase):
                    do { unlockedSecret = try phraseToMasterSecret(phrase: phrase.trimmingCharacters(in: .whitespacesAndNewlines)) }
                    catch { throw BackupRestoreError.invalidPhrase }
                }
                credential = c
                step = .choose
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
        }
    }

    private func begin() {
        guard !busy else { return }
        guard credential != nil else { step = .unlock; return }
        busy = true
        errorText = nil
        stageIndex = 0
        step = .restoring

        Task {
            defer { busy = false }
            do {
                // The stages the user is shown map to what actually happens: the download and
                // decrypt are inside this one call, so the index advances around it rather than
                // pretending to track its internals.
                stageIndex = 1
                guard let secret = unlockedSecret else { step = .unlock; return }
                try await BackupManager.shared.restore(with: secret, from: source) { stageIndex = $0 }
                unlockedSecret = nil
                self.credential = nil
                stageIndex = RestoreStage.all.count      // every stage complete
                Haptics.success()
                // A beat on the completed list, so the last stage is legible rather than
                // flashing past on its way out.
                try? await Task.sleep(for: .milliseconds(650))
                onFinish()
            } catch let e as RecoveryError {
                // Locked / not-set — surface directly (not a wrong-PIN case).
                errorText = e.errorDescription
                Haptics.error()
                step = .unlock
            } catch let e as BackupRestoreError {
                errorText = e.errorDescription
                Haptics.error()
                step = credentialIsPin ? .unlock : .phrase
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
                // Retain the credential for a transfer/disk retry without blaming the PIN.
                step = .restoring
            }
        }
    }

    private var credentialIsPin: Bool {
        if case .pin = credential { return true }
        return false
    }
}

// MARK: - 1. Unlock

/// The V PIN. Masked, no autofill — see the file header.
private struct UnlockPage: View {
    let meta: BackupMeta
    let errorText: String?
    let busy: Bool
    let onSubmit: (String) -> Void
    let onRecoveryPhrase: () -> Void
    let onSkip: () -> Void

    private let pinLength = PinRules.maxLen
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var isComplete: Bool { PinRules.valid(pin) }

    var body: some View {
        ScrollView {
                VStack(spacing: 0) {
                    // No wordmark above: the title's accent half IS "Voiid", so the header
                    // would print the brand twice a few points apart at two different sizes.
                    OnboardingHeader(
                        title: .stacked("Welcome back to", accent: "Voiid"),
                        blurb: "Enter your Voiid PIN to restore this account.",
                        showsWordmark: false
                    )

                    backupSummary
                        .padding(.top, VoiidSpacing.md)

                    pinBoxes
                        .padding(.top, VoiidSpacing.lg)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.sm)
                    }

                    privacyNote
                        .padding(.top, VoiidSpacing.lg)

                    troubleRow
                        .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, VoiidSpacing.lg)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .onTapGesture { focused = false }

            .safeAreaInset(edge: .bottom, spacing: 0) {
                OnboardingFooter {
                    OnboardingKitButton(title: busy ? "Verifying…" : "Continue",
                                        enabled: isComplete && !busy) {
                        focused = false
                        onSubmit(pin)
                    }

                    Button("Continue without restoring") {
                        Haptics.tap()
                        onSkip()
                    }
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidBrand.textDim)
                    .buttonStyle(PressableButtonStyle())
                }
            }
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
    }

    /// What is being restored, from the real backup metadata.
    private var backupSummary: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "arrow.clockwise.icloud")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(VoiidBrand.lime)
            Text(meta.size_bytes > 0 ? "Backup from \(BackupRecoveryView.relative(meta.updatedAtDate)) · \(BackupRecoveryView.size(meta.size_bytes))" : "Choose a backup location after entering your PIN.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidBrand.textDim)
        }
        .frame(maxWidth: .infinity)
    }

    private var pinBoxes: some View {
        PinField(placeholder: "PIN", text: $pin, externalFocus: $focused)
    }

    private var privacyNote: some View {
        RestoreNoteCard(
            icon: "lock.shield",
            title: "Only you know your PIN",
            detail: "It never leaves this device. Your backup is decrypted here, so Voiid cannot read it."
        )
    }

    private var troubleRow: some View {
        Button {
            Haptics.tap()
            onRecoveryPhrase()
        } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "key")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(VoiidBrand.lime)
                Text("Forgot your PIN?")
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidBrand.textDim)
                Text("Use recovery phrase")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.lime)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - 1b. Recovery phrase

/// The 24-word fallback. Wraps the existing `PhraseEntryView`, which already handles the
/// word-by-word entry and validation, on the brand ground with a way back.
private struct PhrasePage: View {
    let errorText: String?
    let busy: Bool
    let onSubmit: (String) -> Void
    /// Back to the PIN — only for an account that still has a legacy PIN backup.
    let onBack: (() -> Void)?
    let onSkip: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if let onBack {
                    Button {
                        Haptics.tap()
                        onBack()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 15, weight: .semibold))
                            Text("PIN").font(VoiidFont.rounded(16))
                        }
                        .foregroundColor(VoiidBrand.lime)
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                Spacer()
                Button {
                    Haptics.tap()
                    onSkip()
                } label: {
                    Text("Skip").font(VoiidFont.rounded(16)).foregroundColor(VoiidBrand.textDim)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Continue without restoring")
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, VoiidSpacing.sm)

            PhraseEntryView(errorText: errorText, busy: busy, onSubmit: onSubmit)
        }
    }
}

// MARK: - 2. Choose a backup

/// Which destination to restore from. Only shown when more than one has a backup — a list with
/// one row is not a choice.
private struct ChoosePage: View {
    let candidates: [(destination: BackupDestination, snapshot: BackupSnapshot)]
    @Binding var selected: BackupDestination
    let errorText: String?
    let onRefresh: () -> Void
    let onRestore: () -> Void
    let onSetUpAsNew: () -> Void

    /// The newest backup earns the badge — see the file header.
    private var recommended: BackupDestination? {
        candidates
            .filter { $0.snapshot.modified != nil }
            .max(by: { ($0.snapshot.modified ?? .distantPast) < ($1.snapshot.modified ?? .distantPast) })?
            .destination
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Restore your chats").font(VoiidFont.rounded(28, .bold)).foregroundColor(VoiidBrand.text)
                        Text("Choose the backup you want to use.").font(VoiidFont.subhead).foregroundColor(VoiidBrand.textDim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 20)

                    // An empty list is reachable in principle — `fetchBackupMeta` found a
                    // server backup, then `restoreCandidates` came back with nothing because
                    // every destination went unavailable in between (signed out of iCloud,
                    // network dropped). Saying so is better than an expanse of ground with a
                    // Restore button under it that cannot work.
                    if candidates.isEmpty {
                        RestoreNoteCard(
                            icon: "exclamationmark.icloud",
                            title: "No backups available right now",
                            detail: "Check your connection and that you are signed in to iCloud, then try again."
                        )
                        .padding(.top, VoiidSpacing.lg)
                    } else {
                        VStack(spacing: 10) {
                            ForEach(candidates, id: \.destination.id) { candidate in
                                backupCard(candidate)
                            }
                        }
                        .padding(.top, VoiidSpacing.lg)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .padding(.top, VoiidSpacing.sm)
                    }

                    Button("Check again", action: onRefresh)
                        .font(VoiidFont.rounded(14)).padding(.top, 16)
                    Label("Your backup stays encrypted.", systemImage: "lock")
                        .font(VoiidFont.rounded(13)).foregroundColor(VoiidBrand.textDim).padding(.top, 20)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, 190)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                OnboardingFooter {
                    OnboardingKitButton(title: "Restore",
                                        enabled: !candidates.isEmpty,
                                        action: onRestore)

                    // DESTRUCTIVE, and deliberately not styled like the other control: no fill,
                    // no chevron, nothing promising more. It discards the backup for this device.
                    Button("Continue without restoring") {
                        Haptics.tap()
                        onSetUpAsNew()
                    }
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidBrand.textDim)
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
    }

    private var confirmedMark: some View {
        Circle()
            .fill(VoiidBrand.lime.opacity(0.10))
            .frame(width: 64, height: 64)
            .overlay {
                Image(systemName: "checkmark")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(VoiidBrand.lime)
            }
    }

    private func backupCard(_ candidate: (destination: BackupDestination, snapshot: BackupSnapshot)) -> some View {
        let isSelected = selected == candidate.destination
        let isRecommended = recommended == candidate.destination

        return Button {
            Haptics.selection()
            selected = candidate.destination
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Circle()
                    .fill(VoiidBrand.lime.opacity(0.10))
                    .frame(width: 46, height: 46)
                    .overlay {
                        Image(systemName: candidate.destination.systemImage)
                            .font(.system(size: 19, weight: .medium))
                            .foregroundColor(VoiidBrand.lime)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(candidate.destination.title)
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(VoiidBrand.text)

                        if isRecommended {
                            Text("Newest")
                                .font(VoiidFont.rounded(11, .semibold))
                                .foregroundColor(VoiidBrand.onLime)
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(VoiidBrand.lime))
                        }
                    }

                    Text(detailLine(candidate.snapshot))
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidBrand.textDim)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? VoiidBrand.lime : VoiidBrand.textDim)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 14)
            .background(VoiidBrand.card)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .stroke(isSelected ? VoiidBrand.lime : VoiidBrand.hairline,
                            lineWidth: isSelected ? 1.5 : 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// Date and size, from the real snapshot. Never invented — a fabricated "2.4 GB" on a
    /// security screen is a lie about the user's own data.
    private func detailLine(_ snapshot: BackupSnapshot) -> String {
        let size = BackupRecoveryView.size(snapshot.sizeBytes)
        guard let modified = snapshot.modified else { return size }
        return "\(BackupRecoveryView.relative(modified)) · \(size)"
    }
}

// MARK: - 3. Restoring

/// A stage of the restore.
///
/// Five named stages rather than a spinner: a single spinner over "Restoring…" tells the user
/// nothing when it sits for two minutes on a large transfer, while a list that has visibly
/// completed two stages shows progress even when the slow one is still running.
struct RestoreStage: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String

    static let all: [RestoreStage] = [
        .init(id: "unlock",   title: "Unlocking your backup",   icon: "key"),
        .init(id: "download", title: "Downloading",             icon: "arrow.down.circle"),
        .init(id: "decrypt",  title: "Decrypting on device",    icon: "lock.open"),
        .init(id: "merge",    title: "Restoring your chats",    icon: "bubble.left.and.bubble.right"),
        .init(id: "keys",     title: "Saving recovery key",    icon: "checkmark.shield"),
    ]
}

private struct RestoringPage: View {
    /// How many stages have completed. The one at this index is active.
    let stageIndex: Int
    let source: BackupDestination
    let errorText: String?
    let onRetry: () -> Void
    let onSkip: () -> Void

    private var failed: Bool { errorText != nil }

    private var complete: Bool { stageIndex >= RestoreStage.all.count }
    private var currentTitle: String {
        if failed { return "Restore paused" }
        if complete { return "Your chats are ready" }
        return RestoreStage.all[max(0, min(stageIndex, RestoreStage.all.count - 1))].title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(complete ? "Restore complete" : "Restoring chats")
                        .font(VoiidFont.rounded(28, .bold))
                        .foregroundColor(VoiidBrand.text)
                    Text("From \(source.title)")
                        .font(VoiidFont.rounded(15))
                        .foregroundColor(VoiidBrand.textDim)
                }
                .padding(.top, 24)

                VStack(alignment: .leading, spacing: 20) {
                    HStack(spacing: 14) {
                        Image(systemName: failed ? "exclamationmark.arrow.triangle.2.circlepath" : complete ? "checkmark" : "arrow.down")
                            .font(.system(size: 24, weight: .medium))
                            .foregroundColor(VoiidBrand.lime)
                            .frame(width: 56, height: 56)
                            .background(VoiidBrand.lime.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
                        VStack(alignment: .leading, spacing: 5) {
                            Text(currentTitle).font(VoiidFont.rounded(17, .semibold)).foregroundColor(VoiidBrand.text)
                            Text(complete ? "Everything is saved on this device." : failed ? "Your saved backup is safe." : "Keep Voiid open while we finish.")
                                .font(VoiidFont.rounded(13)).foregroundColor(VoiidBrand.textDim)
                        }
                    }
                    HStack(spacing: 6) {
                        ForEach(0..<RestoreStage.all.count, id: \.self) { index in
                            Capsule().fill(index < stageIndex ? VoiidBrand.lime : index == stageIndex && !failed ? VoiidBrand.lime.opacity(0.4) : VoiidBrand.hairline)
                                .frame(height: 4)
                        }
                    }
                    Text(complete ? "All steps complete" : "Step \(min(stageIndex + 1, RestoreStage.all.count)) of \(RestoreStage.all.count)")
                        .font(VoiidFont.rounded(12, .medium)).foregroundColor(VoiidBrand.textDim)
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(VoiidBrand.card, in: RoundedRectangle(cornerRadius: 24))

                stageList
                if let errorText {
                    Text(errorText).font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.error)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label("Your chats stay end-to-end encrypted.", systemImage: "lock.shield")
                    .font(VoiidFont.rounded(12)).foregroundColor(VoiidBrand.textDim)
                    .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(VoiidBrand.ground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if failed {
                OnboardingFooter {
                    OnboardingKitButton(title: "Try again", cornerRadius: 16, action: onRetry)
                    Button("Restore later", action: onSkip)
                        .font(VoiidFont.rounded(15)).foregroundColor(VoiidBrand.textDim)
                }
            }
        }
    }

    private var stageList: some View {
        VStack(spacing: 0) {
            ForEach(Array(RestoreStage.all.enumerated()), id: \.element.id) { index, stage in
                stageRow(stage, index: index)
                if index < RestoreStage.all.count - 1 {
                    OnboardingRowDivider()
                }
            }
        }
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
    }

    private func stageRow(_ stage: RestoreStage, index: Int) -> some View {
        let done = index < stageIndex
        let active = index == stageIndex && !failed

        return HStack(spacing: VoiidSpacing.md) {
            ZStack {
                Circle()
                    .fill(done || active ? VoiidBrand.lime.opacity(0.10) : VoiidBrand.row)
                    .frame(width: 40, height: 40)

                if done {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(VoiidBrand.lime)
                } else if active {
                    ProgressView()
                        .controlSize(.small)
                        .tint(VoiidBrand.lime)
                } else {
                    Image(systemName: stage.icon)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(VoiidBrand.textDim.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(done || active ? VoiidBrand.text
                                                    : VoiidBrand.textDim)
                Text(done ? "Completed" : (failed && index == stageIndex ? "Needs attention" : active ? "In progress" : "Next"))
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .animation(.easeOut(duration: 0.2), value: done)
        .animation(.easeOut(duration: 0.2), value: active)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Shared

/// The reassurance card used on all three pages, so they cannot drift apart.
private struct RestoreNoteCard: View {
    let icon: String
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.text)
                Text(detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 14)
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Review the production layout without starting a restore or changing user data.
struct RestoreDesignPreview: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection = 1
    var body: some View {
        NavigationStack {
            RestoringPage(stageIndex: selection == 6 ? 1 : selection, source: .iCloud,
                          errorText: selection == 6 ? "Couldn’t download your backup. Check your connection and try again." : nil,
                          onRetry: { selection = 1 }, onSkip: { dismiss() })
                .navigationTitle("Design preview")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                    ToolbarItem(placement: .primaryAction) {
                        Menu("State") {
                            Button("Downloading") { selection = 1 }
                            Button("Restoring") { selection = 3 }
                            Button("Complete") { selection = 5 }
                            Button("Error") { selection = 6 }
                        }
                    }
                }
        }
        .tint(VoiidBrand.lime)
    }
}
#endif
