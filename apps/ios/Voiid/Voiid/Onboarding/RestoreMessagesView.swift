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
    @State private var errorText: String?
    @State private var busy = false

    /// Which destination to pull the sealed blob from. Defaults to the newest available backup
    /// across server / iCloud / Google Drive. The PIN or phrase unlocks the same master secret
    /// regardless of source.
    @State private var source: BackupDestination = .server
    @State private var candidates: [(destination: BackupDestination, snapshot: BackupSnapshot)] = []

    /// The unlocked credential, held between step 1 and step 3.
    ///
    /// The PIN is taken FIRST and the source chosen second, which is the reference's order and
    /// also the safer one: a user who cannot unlock never sees a list of their own backups.
    private enum Credential: Equatable { case pin(String), phrase(String) }
    @State private var credential: Credential?

    /// Which restore stage is running. Drives the list on the third page.
    @State private var stageIndex = 0

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            switch step {
            case .unlock:    UnlockPage(meta: meta,
                                        errorText: errorText,
                                        busy: busy,
                                        onSubmit: { unlock(.pin($0)) },
                                        onRecoveryPhrase: { errorText = nil; step = .phrase },
                                        onSkip: onFinish)
            case .phrase:    PhrasePage(errorText: errorText,
                                        busy: busy,
                                        onSubmit: { unlock(.phrase($0)) },
                                        onBack: { errorText = nil; step = .unlock })
            case .choose:    ChoosePage(candidates: candidates,
                                        selected: $source,
                                        errorText: errorText,
                                        onRestore: { begin() },
                                        onSetUpAsNew: onFinish)
            case .restoring: RestoringPage(stageIndex: stageIndex,
                                           source: source,
                                           errorText: errorText,
                                           onRetry: { begin() },
                                           onSkip: onFinish)
            }
        }
        .preferredColorScheme(.dark)
        .task { await loadCandidates() }
    }

    // MARK: Candidates

    private func loadCandidates() async {
        let found = await BackupManager.shared.restoreCandidates()
        candidates = found
        source = found.first?.destination ?? .server   // newest by default
    }

    // MARK: Actions

    /// Hold the credential and move on.
    ///
    /// NOTHING IS VERIFIED HERE. The PIN is only proven correct by the unwrap inside
    /// `BackupManager.restoreWithPin`, which happens on the restoring page — so a wrong PIN
    /// surfaces there rather than being checked twice against two different notions of
    /// "correct". When only one backup exists the choose page has nothing to ask, so it is
    /// skipped rather than shown with a single row and no decision.
    private func unlock(_ c: Credential) {
        credential = c
        errorText = nil
        if candidates.count > 1 {
            step = .choose
        } else {
            begin()
        }
    }

    private func begin() {
        guard let credential else { step = .unlock; return }
        errorText = nil
        stageIndex = 0
        step = .restoring

        Task {
            do {
                // The stages the user is shown map to what actually happens: the download and
                // decrypt are inside this one call, so the index advances around it rather than
                // pretending to track its internals.
                stageIndex = 1
                switch credential {
                case .pin(let pin):
                    try await BackupManager.shared.restoreWithPin(pin, from: source)
                case .phrase(let phrase):
                    try await BackupManager.shared.restoreWithPhrase(phrase, from: source)
                }
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
            } catch {
                // Wrong PIN / tampered wrap / download-decrypt failure. The attempt was
                // already reported as failed inside restoreWithPin.
                errorText = credentialIsPin
                    ? "Wrong PIN. Please try again — attempts are limited."
                    : "That recovery phrase didn't work. Check the words and try again."
                Haptics.error()
                step = credentialIsPin ? .unlock : .phrase
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

    private let pinLength = 6
    @State private var pin = ""
    @FocusState private var focused: Bool

    private var isComplete: Bool { pin.count == pinLength }

    var body: some View {
        ZStack {
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
                .padding(.bottom, 190)
            }
            .scrollIndicators(.hidden)
            .onTapGesture { focused = false }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                OnboardingFooter {
                    OnboardingKitButton(title: busy ? "Restoring…" : "Continue",
                                        enabled: isComplete && !busy) {
                        focused = false
                        onSubmit(pin)
                    }

                    Button("Set up as new instead") {
                        Haptics.tap()
                        onSkip()
                    }
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textSecondary)
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .ignoresSafeArea(edges: .bottom)
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
            Text("Backup from \(BackupRecoveryView.relative(meta.updatedAtDate)) · \(BackupRecoveryView.size(meta.size_bytes))")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    /// Six boxes over one hidden field, like the OTP screen — but MASKED and with no autofill.
    private var pinBoxes: some View {
        ZStack {
            TextField("", text: $pin)
                .keyboardType(.numberPad)
                // Deliberately NOT `.oneTimeCode`: a PIN never arrives by SMS, so offering to
                // fill it from a message would be offering to fill it from an attacker's.
                .textContentType(.password)
                .focused($focused)
                .opacity(0.01)
                .onChange(of: pin) { _, new in
                    let filtered = String(new.filter(\.isNumber).prefix(pinLength))
                    if filtered != new { pin = filtered; return }
                    if !filtered.isEmpty && filtered.count < pinLength { Haptics.selection() }
                    if filtered.count == pinLength { focused = false; Haptics.soft() }
                }

            HStack(spacing: 10) {
                ForEach(0..<pinLength, id: \.self) { index in box(at: index) }
            }
            .allowsHitTesting(false)
        }
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .accessibilityElement()
        .accessibilityLabel("Voiid PIN")
        .accessibilityValue("\(pin.count) of \(pinLength) digits entered")
    }

    private func box(at index: Int) -> some View {
        let filled = index < pin.count
        let isCursor = focused && index == min(pin.count, pinLength - 1)

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(VoiidColor.fieldFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(isCursor ? VoiidBrand.lime : VoiidColor.fieldBorder,
                            lineWidth: isCursor ? 2 : 1)
            )
            .frame(height: 62)
            .overlay {
                if filled {
                    // MASKED — a dot, never the digit. See the file header.
                    Circle()
                        .fill(VoiidColor.textPrimary)
                        .frame(width: 12, height: 12)
                } else {
                    Rectangle()
                        .fill(VoiidColor.textSecondary.opacity(0.5))
                        .frame(width: 18, height: 2)
                        .offset(y: 12)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isCursor)
            .animation(.easeOut(duration: 0.15), value: filled)
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
                    .foregroundColor(VoiidColor.textSecondary)
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
    let onBack: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
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
                Spacer()
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
                    OnboardingHeader(
                        title: .stacked("Identity", accent: "confirmed"),
                        blurb: "Choose which backup to restore on this device."
                    )

                    confirmedMark
                        .padding(.top, VoiidSpacing.md)

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

                    RestoreNoteCard(
                        icon: "clock.arrow.circlepath",
                        title: "Restore the newest one",
                        detail: "Anything created after the backup you choose will not be on this device."
                    )
                    .padding(.top, VoiidSpacing.lg)
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
                    Button("Set up as new instead") {
                        Haptics.tap()
                        onSetUpAsNew()
                    }
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textSecondary)
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
                            .foregroundColor(VoiidColor.textPrimary)

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
                        .foregroundColor(VoiidColor.textSecondary)
                }

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 20))
                    .foregroundColor(isSelected ? VoiidBrand.lime : VoiidColor.textSecondary)
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
        .init(id: "keys",     title: "Re-establishing keys",    icon: "checkmark.shield"),
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

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 0) {
                    // Same as the unlock page: the title already says Voiid.
                    OnboardingHeader(
                        title: .stacked("Restoring your", accent: "Voiid"),
                        blurb: "Keep the app open. This can take a few minutes on a large backup.",
                        showsWordmark: false
                    )

                    Text(source.title)
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.top, 2)

                    stageList
                        .padding(.top, VoiidSpacing.lg)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.md)
                    }

                    RestoreNoteCard(
                        icon: "lock.shield",
                        title: "Decrypted on this device",
                        detail: "Your backup is unlocked here with your PIN. Voiid's servers never see the contents."
                    )
                    .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, failed ? 190 : VoiidSpacing.xxl)
            }
            .scrollIndicators(.hidden)

            if failed {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    OnboardingFooter {
                        OnboardingKitButton(title: "Try again", enabled: true, action: onRetry)
                        Button("Skip for now") {
                            Haptics.tap()
                            onSkip()
                        }
                        .font(VoiidFont.rounded(15))
                        .foregroundColor(VoiidColor.textSecondary)
                        .buttonStyle(PressableButtonStyle())
                    }
                }
                .ignoresSafeArea(edges: .bottom)
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
                    .fill(done || active ? VoiidBrand.lime.opacity(0.10) : Color.white.opacity(0.04))
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
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.6))
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(stage.title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(done || active ? VoiidColor.textPrimary
                                                    : VoiidColor.textSecondary)
                Text(done ? "Completed" : (active ? "In progress" : "Waiting"))
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
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
                    .foregroundColor(VoiidColor.textPrimary)
                Text(detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
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
