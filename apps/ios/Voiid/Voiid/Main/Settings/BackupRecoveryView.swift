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

    @State private var showRestore = false
    @State private var showSetup = false
    @State private var showPhrase = false
    /// An old PIN-protected copy of the key still on the server (from before S04).
    @State private var legacyPin = false
    @State private var showRetirePin = false
    @State private var schedulePicker: BackupSchedulePicker.Page?

    // iCloud destination for the SAME encrypted blob.
    @State private var destSnapshots: [BackupDestination: BackupSnapshot] = [:]
    @State private var togglingDestination: BackupDestination?
    @State private var destError: String?

    private var latestBackup: BackupMeta? {
        var snapshots = Array(destSnapshots.values)
        if let meta { snapshots.append(BackupSnapshot(sizeBytes: meta.size_bytes, modified: meta.updatedAtDate)) }
        guard let latest = snapshots.max(by: { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }) else { return nil }
        return BackupMeta(download_url: "", size_bytes: latest.sizeBytes,
                          updated_at: latest.modified.map { ISO8601DateFormatter().string(from: $0) } ?? "")
    }

    private var hasRestorableBackup: Bool {
        // New uploads are not a reason to restore again on a device already recovered.
        latestBackup != nil && manager.lastCompletedRestore == nil
    }

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
                    if !loadingStatus, hasRestorableBackup {
                        VoiidCardSection("Backup available", footer: "Restore saved chats using your recovery phrase. Your current chats are kept.") {
                            actionRow(title: "Restore chats", system: "arrow.down.circle", enabled: !backingUp) {
                                showRestore = true
                            }
                        }
                    }
                    destinationsCard.disabled(backingUp)

                    if isSetUp {
                        VoiidCardSection {
                            actionRow(title: backingUp ? manager.progressLabel : "Back up now",
                                      system: "arrow.up.circle", enabled: !backingUp && !manager.enabledDestinations.isEmpty) { backUpNow() }
                        }
                        scheduleCard
                        VoiidCardSection {
                            actionRow(title: "View recovery phrase", system: "key") { showPhrase = true }
                        }
                        if legacyPin {
                            VoiidCardSection("Make your backup safer",
                                             footer: "Your backup can still be opened with an old PIN. A short PIN can be guessed; your 24-word recovery phrase can’t. Save your phrase, then remove the PIN.") {
                                actionRow(title: "Remove old backup PIN", system: "lock.slash") { showRetirePin = true }
                            }
                        }
                    } else {
                        VoiidCardSection {
                            actionRow(title: "Set up backup", system: "checkmark.shield", enabled: !manager.enabledDestinations.isEmpty) { showSetup = true }
                        }
                    }

                    if let actionError {
                        Text(actionError)
                            .font(.footnote)
                            .foregroundColor(VoiidColor.error)
                            .padding(.horizontal, 4)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Text("Your messages are encrypted on this device before backup. Only your 24-word recovery phrase can restore them — VOIID can’t read your backup or recover it for you. Keep it somewhere safe.")
                        .font(.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.horizontal, 4)
                        .padding(.top, VoiidSpacing.sm)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(VoiidSpacing.md)
            }
            .softTopEdgeEffect()
            .voiidSettingsPage()

            if let toast { ToastBanner(text: toast) }
        }
        .task { await refreshStatus() }
        .sheet(isPresented: $showSetup, onDismiss: { Task { await refreshStatus() } }) {
            BackupSetupFlow { showSetup = false; flash("Backup is set up") }
        }
        .fullScreenCover(isPresented: $showRestore, onDismiss: { Task { await refreshStatus() } }) {
            RestoreMessagesView(meta: latestBackup ?? BackupMeta(download_url: "", size_bytes: 0, updated_at: "")) {
                showRestore = false
            }
        }
        .sheet(isPresented: $showPhrase) { RecoveryPhraseSheet() }
        .sheet(isPresented: $showRetirePin, onDismiss: { Task { legacyPin = await manager.hasLegacyPin() } }) {
            RetirePinFlow { flash("Old PIN removed") }
        }
        .task { legacyPin = await manager.hasLegacyPin() }
        .sheet(item: $schedulePicker) { page in
            BackupSchedulePicker(page: page, manager: manager)
        }
    }

    // MARK: Status card

    private var statusCard: some View {
        VoiidCardSection {
            HStack(spacing: VoiidSpacing.md) {
                VoiidRowIcon(systemName: isSetUp ? "checkmark.shield.fill" : "shield.slash")

                VStack(alignment: .leading, spacing: 2) {
                    Text(isSetUp && !manager.enabledDestinations.isEmpty ? "Backup is on" : "Backup is off")
                        .font(.body)
                        .foregroundColor(VoiidColor.textPrimary)

                    if let meta = latestBackup, !loadingStatus {
                        Text("Last backup \(Self.relative(meta.updatedAtDate)) · \(Self.size(meta.size_bytes))")
                            .font(.footnote)
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        // The question "is my history safe?" is really "when does this
                        // happen again?", which a last-backup time alone never answers.
                        if let next = BackupManager.shared.nextBackupDate(after: meta.updatedAtDate) {
                            Text("Next backup \(Self.relative(next))")
                                .font(.footnote)
                                .foregroundColor(VoiidColor.textSecondary)
                        } else if !BackupManager.shared.backupNetwork.isAutomatic {
                            Text("Automatic backup is off")
                                .font(.footnote)
                                .foregroundColor(VoiidColor.textSecondary)
                        }
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

    // MARK: Schedule

    /// When automatic backup runs, and what rides along in it.
    private var scheduleCard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VoiidCardSection(
                "Backup schedule",
                footer: manager.backupNetwork.isAutomatic
                    ? "Backups use Wi-Fi unless you allow mobile data. Your chosen frequency is measured from the last successful backup."
                    : "Automatic backup is off. You can still use Back up now whenever you need it."
            ) {
                VoiidSettingsRow(icon: "arrow.triangle.2.circlepath",
                                 title: "Automatic backup",
                                 detail: manager.backupNetwork.title,
                                 action: { Haptics.tap(); schedulePicker = .network }) {
                    VoiidChevron()
                }

                if manager.backupNetwork.isAutomatic {
                    VoiidRowDivider()
                    VoiidSettingsRow(icon: "calendar",
                                     title: "How often",
                                     detail: manager.backupFrequency.title,
                                     action: { Haptics.tap(); schedulePicker = .frequency }) {
                        VoiidChevron()
                    }
                }
            }

            VoiidCardSection(
                "What's included",
                footer: "Messages are always included. Photos make the backup much larger and "
                      + "slower to upload. Videos are never included — they would make the "
                      + "backup too large to finish reliably, and they stay recoverable from "
                      + "the chat itself."
            ) {
                Toggle(isOn: Binding(
                    get: { BackupManager.shared.includesPhotos },
                    set: { BackupManager.shared.includesPhotos = $0; Haptics.selection() }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Include photos").foregroundColor(VoiidColor.textPrimary)
                        Text("Off by default. Increases backup size.")
                            .font(.footnote)
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .tint(VoiidColor.primary)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
            }
        }
    }

    // MARK: iCloud destination

    private var destinationsCard: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            VoiidCardSection(
                "Backup locations",
                footer: "Choose Voiid server, iCloud, both, or neither. Turning a location off stops future uploads; existing backups stay there."
            ) {
                destinationRow(.server, available: true, unavailableNote: "")
                VoiidRowDivider()
                destinationRow(.iCloud,
                               available: ICloudBackupService.shared.isAvailable,
                               unavailableNote: "Sign in to iCloud in Settings to enable.")
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
                .disabled(!available && !isOn)
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
        meta = nil
        do { meta = try await manager.status() }
        catch { statusError = (error as? APIError)?.errorDescription ?? error.localizedDescription }
        await refreshDestinations()
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

// MARK: - Schedule choices

private struct BackupSchedulePicker: View {
    enum Page: String, Identifiable {
        case network, frequency

        var id: String { rawValue }
        var title: String { self == .network ? "Automatic backup" : "How often" }
        var explanation: String {
            self == .network
                ? "Choose which connection automatic backups can use."
                : "Choose how often to back up your chats."
        }
    }

    let page: Page
    @ObservedObject var manager: BackupManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    Text(page.explanation)
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)

                    VoiidCardSection {
                        switch page {
                        case .network:
                            ForEach(BackupManager.BackupNetwork.allCases) { option in
                                choice(title: option.title, detail: networkDetail(option),
                                       icon: networkIcon(option),
                                       selected: manager.backupNetwork == option) {
                                    manager.backupNetwork = option
                                }
                                if option != BackupManager.BackupNetwork.allCases.last {
                                    VoiidRowDivider()
                                }
                            }
                        case .frequency:
                            ForEach(BackupManager.BackupFrequency.allCases) { option in
                                choice(title: option.title,
                                       detail: option == .daily ? "Every 24 hours" : "Every 7 days",
                                       icon: option == .daily ? "sun.max" : "calendar",
                                       selected: manager.backupFrequency == option) {
                                    manager.backupFrequency = option
                                }
                                if option != BackupManager.BackupFrequency.allCases.last {
                                    VoiidRowDivider()
                                }
                            }
                        }
                    }

                    if page == .frequency {
                        Text("Timing depends on your connection and when the app can run. You can always back up manually.")
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 4)
                    }
                }
                .padding(VoiidSpacing.md)
            }
            .background(VoiidColor.background)
            .navigationTitle(page.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .fontDesign(.rounded)
        .tint(VoiidColor.accent)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
    }

    private func choice(title: String, detail: String, icon: String,
                        selected: Bool, select: @escaping () -> Void) -> some View {
        VoiidSettingsRow(icon: icon, title: title, detail: detail, action: {
            if !selected { select(); Haptics.selection() }
            dismiss()
        }) {
            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(selected ? VoiidColor.accent : VoiidColor.divider)
                .accessibilityHidden(true)
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func networkIcon(_ network: BackupManager.BackupNetwork) -> String {
        switch network {
        case .wifiOnly: "wifi"
        case .wifiAndCellular: "antenna.radiowaves.left.and.right"
        case .manualOnly: "hand.tap"
        }
    }

    private func networkDetail(_ network: BackupManager.BackupNetwork) -> String {
        switch network {
        case .wifiOnly: "Wait for Wi-Fi. Uses no mobile data."
        case .wifiAndCellular: "Use either connection. Mobile data charges may apply."
        case .manualOnly: "Only when you tap Back up now."
        }
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

// MARK: - Setup flow (recovery phrase → confirm it → first backup)

/// Setting up backup: the 24-word phrase, proof it was written down, then the first backup.
///
/// THE PHRASE IS THE ONLY WAY BACK IN (S04). There used to be a PIN here too, whose wrapped
/// key sat on the server — and a 6-digit PIN is ~20 bits, so anyone who obtained that copy
/// could try every PIN offline. It is gone. That makes the phrase load-bearing, which is why
/// setup asks for three of its words back: "I've written it down" alone is a button people
/// press without writing anything down.
struct BackupSetupFlow: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step { case phrase, confirm, working }
    @State private var step: Step = .phrase
    @State private var secret = Data()
    @State private var phrase = ""
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidBackground()
                switch step {
                case .phrase:
                    if phrase.isEmpty {
                        ProgressView().tint(VoiidColor.primary)
                    } else {
                        RecoveryPhraseView(phrase: phrase, confirmTitle: "I’ve written it down") {
                            withAnimation(.easeOut(duration: 0.2)) { step = .confirm }
                        }
                    }
                case .confirm:
                    PhraseConfirmView(phrase: phrase,
                                      onBack: { withAnimation(.easeOut(duration: 0.2)) { step = .phrase } },
                                      onConfirmed: { commit() })
                case .working:
                    VStack(spacing: VoiidSpacing.md) {
                        ProgressView().tint(VoiidColor.primary)
                        Text("Setting up backup…").font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                        if let errorText {
                            Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error)
                                .multilineTextAlignment(.center)
                            Button("Try again") { commit() }.font(VoiidFont.headline).foregroundColor(VoiidColor.primary)
                        }
                    }
                    .padding(VoiidSpacing.lg)
                }
            }
            .navigationTitle(step == .confirm ? "Check your phrase" : "Set up backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .interactiveDismissDisabled(step == .working)
        .task {
            guard phrase.isEmpty else { return }
            do {
                let made = try BackupManager.shared.newSecretAndPhrase()
                secret = made.secret; phrase = made.phrase
            } catch {
                errorText = "Couldn’t generate a recovery phrase. Please try again."
                step = .working
            }
        }
    }

    private func commit() {
        guard !phrase.isEmpty else { dismiss(); return }
        step = .working; errorText = nil
        Task {
            do {
                try await BackupManager.shared.commitSetup(secret: secret)
                Haptics.success()
                onDone()
            } catch {
                errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
        }
    }
}

/// Three words of the phrase, typed back, before anything depends on it.
///
/// Positions are picked at random from across the phrase (one from each third), so the check
/// cannot be passed by remembering the first line. Typing is forgiving about case and spaces,
/// strict about the word.
struct PhraseConfirmView: View {
    let phrase: String
    var onBack: () -> Void
    var onConfirmed: () -> Void

    @State private var positions: [Int] = []
    @State private var answers: [String] = ["", "", ""]
    @State private var wrong: Set<Int> = []
    @FocusState private var focused: Int?

    private var words: [String] { phrase.split(separator: " ").map(String.init) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Type these words from your phrase")
                        .font(VoiidFont.rounded(20, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text("This is the only way to restore your chats on a new phone, so it’s worth one check.")
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textSecondary)
                }

                ForEach(Array(positions.enumerated()), id: \.offset) { index, position in
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Word \(position + 1)")
                            .font(VoiidFont.rounded(13, .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                        TextField("", text: $answers[index], prompt: Text("word \(position + 1)").foregroundColor(VoiidColor.placeholder))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .textContentType(.oneTimeCode)
                            .focused($focused, equals: index)
                            .submitLabel(index == 2 ? .done : .next)
                            .onSubmit { if index < 2 { focused = index + 1 } else { check() } }
                            .font(VoiidFont.rounded(17))
                            .foregroundColor(VoiidColor.textPrimary)
                            .padding(.horizontal, 14)
                            .frame(height: 48)
                            .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(wrong.contains(index) ? VoiidColor.error : VoiidColor.divider, lineWidth: 1))
                            .onChange(of: answers[index]) { _, _ in wrong.remove(index) }
                        if wrong.contains(index) {
                            Text("That’s not word \(position + 1).")
                                .font(VoiidFont.footnote)
                                .foregroundColor(VoiidColor.error)
                        }
                    }
                }

                VoiidPrimaryButton(title: "Confirm",
                                   enabled: answers.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    check()
                }
                Button("Show the phrase again") { Haptics.tap(); onBack() }
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                    .frame(maxWidth: .infinity)
            }
            .padding(VoiidSpacing.lg)
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            guard positions.isEmpty, words.count >= 3 else { return }
            let third = words.count / 3
            positions = (0..<3).map { Int.random(in: ($0 * third)..<(($0 + 1) * third)) }
            focused = 0
        }
    }

    private func check() {
        wrong = Set(positions.indices.filter { i in
            answers[i].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() != words[positions[i]].lowercased()
        })
        if wrong.isEmpty {
            Haptics.success()
            onConfirmed()
        } else {
            Haptics.error()
            focused = wrong.min()
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

// MARK: - Remove the old PIN

/// For an account whose key still has an old PIN-protected copy on the server: show the
/// phrase, check it, then delete that copy. After this only the phrase restores the backup —
/// which is exactly the point, and why the phrase is checked first.
struct RetirePinFlow: View {
    let onDone: () -> Void
    @Environment(\.dismiss) private var dismiss

    private enum Step { case phrase, confirm, working }
    @State private var step: Step = .phrase
    @State private var phrase: String?
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidBackground()
                if let phrase {
                    switch step {
                    case .phrase:
                        RecoveryPhraseView(phrase: phrase, confirmTitle: "I’ve saved my phrase") {
                            withAnimation(.easeOut(duration: 0.2)) { step = .confirm }
                        }
                    case .confirm:
                        PhraseConfirmView(phrase: phrase,
                                          onBack: { withAnimation(.easeOut(duration: 0.2)) { step = .phrase } },
                                          onConfirmed: { retire() })
                    case .working:
                        VStack(spacing: VoiidSpacing.md) {
                            ProgressView().tint(VoiidColor.primary)
                            Text("Removing the old PIN…").font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                            if let errorText {
                                Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error)
                                    .multilineTextAlignment(.center)
                                Button("Try again") { retire() }.font(VoiidFont.headline).foregroundColor(VoiidColor.primary)
                            }
                        }
                        .padding(VoiidSpacing.lg)
                    }
                } else if let errorText {
                    Text(errorText).font(VoiidFont.subhead).foregroundColor(VoiidColor.error).padding()
                } else {
                    ProgressView().tint(VoiidColor.primary)
                }
            }
            .navigationTitle("Remove old PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(step == .working) } }
        }
        .interactiveDismissDisabled(step == .working)
        .task {
            do {
                phrase = try BackupManager.shared.currentPhrase()
                if phrase == nil { errorText = "Backup isn’t set up on this device." }
            } catch { errorText = "Couldn’t load your recovery phrase." }
        }
    }

    private func retire() {
        step = .working; errorText = nil
        Task {
            do {
                try await BackupManager.shared.retireLegacyPin()
                Haptics.success()
                onDone()
                dismiss()
            } catch {
                errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
        }
    }
}
