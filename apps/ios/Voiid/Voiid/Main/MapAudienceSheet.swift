//
//  MapAudienceSheet.swift
//  Voiid
//
//  The per-contact allow-list surface for Feature (B), plus the first-open explainer.
//
//  GRANULARITY IS PER-CONTACT AND EXPLICIT (§8). The picker starts EMPTY and requires
//  per-person selection. There is no "everyone" and no block-list ("everyone except…")
//  mode — the block-list default is "visible to everyone I haven't excluded", which is the
//  exact Snapchat failure this design refuses.
//
//  THE CONVERSATION CONSTRAINT: the picker offers only contacts you already have a 1:1
//  conversation with, because the `map_key` control message needs a `conversation_id` to
//  ride the ratchet. Starting a chat is a normal app action; this keeps the backend surface
//  at zero new message routes.
//

import SwiftUI
import Combine   // the countdown's Timer publisher + .autoconnect()

struct MapAudienceSheet: View {
    enum Mode { case choose, manage }
    let mode: Mode

    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var directory = UserDirectory.shared

    /// Who your location goes to. Everyone / My Contacts resolve to a concrete allow-list of
    /// people you can actually reach (the map key rides a 1:1 conversation), so "Everyone" is
    /// still a bounded set — everyone you've chatted with — never the whole world.
    enum Scope: String, CaseIterable { case everyone, contacts, selected }

    @State private var scope: Scope = .contacts
    @State private var selected: Set<String> = []
    @State private var working = false
    /// Which "Add time" option is in flight, so only that button shows a spinner rather than
    /// the whole section going inert. nil = idle.
    @State private var extending: Int?
    /// Drives the countdown text. `expires_at` is an absolute instant, so nothing changes it
    /// but the passage of time — without a tick the row would read "expires in 42m" until the
    /// sheet was reopened, which is the silent-expiry problem this surface exists to fix.
    @State private var now = Date()
    /// The audience member whose revoke is in flight, so their row alone shows progress.
    @State private var removing: String?
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// Contacts you can be visible to: everyone you have a direct conversation with. Names
    /// resolved through `UserDirectory` — never a raw id.
    private var candidates: [(userId: String, name: String, photo: String?)] {
        chat.directConversations
            .compactMap { $0.peerUserId }
            .reduce(into: [String]()) { acc, id in if !acc.contains(id) { acc.append(id) } }
            .map { (userId: $0, name: directory.displayName($0), photo: directory.photoURL($0)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// A candidate is "in my contacts" if the address book gave it a saved name.
    private func isSavedContact(_ userId: String) -> Bool {
        directory.user(userId)?.savedName?.isEmpty == false
    }

    /// The user ids the current scope resolves to.
    private var resolvedIds: [String] {
        switch scope {
        case .everyone: return candidates.map(\.userId)
        case .contacts: return candidates.filter { isSavedContact($0.userId) }.map(\.userId)
        case .selected: return Array(selected)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch mode {
                case .choose: chooser
                case .manage: manager
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(mode == .choose ? "Who can see me" : "Your Map audience")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(VoiidColor.textSecondary)
                }
            }
        }
        .tint(VoiidColor.primary)
        // The Map tab already alerts on `lastError`, but that alert is presented BEHIND this
        // sheet: a failed "Add time" tapped in here would set the flag and the user would see
        // nothing until they closed the sheet. Same binding, same copy — mirrored so a failure
        // raised in this surface is answered in this surface.
        .alert("Map", isPresented: Binding(get: { engine.lastError != nil },
                                           set: { if !$0 { engine.lastError = nil } })) {
            Button("OK", role: .cancel) { engine.lastError = nil }
        } message: {
            Text(engine.lastError ?? "")
        }
        // No colour-scheme pin: Peacock tokens resolve per theme, and a sheet that
        // forced light would be the one bright rectangle in a dark app.
        .onAppear {
            let current = Set(engine.audience.map(\.userId))
            selected = current
            // Infer which scope the current audience matches, so re-opening shows the truth.
            if !current.isEmpty {
                let all = Set(candidates.map(\.userId))
                let contactsOnly = Set(candidates.filter { isSavedContact($0.userId) }.map(\.userId))
                scope = current == all ? .everyone : (current == contactsOnly ? .contacts : .selected)
            }
        }
    }

    // MARK: - Choose (add / initial pick)

    private var chooser: some View {
        VStack(spacing: 0) {
            if candidates.isEmpty {
                emptyCandidates
            } else {
                List {
                    // Scope selector — the redesigned surface.
                    Section {
                        scopeRow(.everyone, icon: "globe",
                                 title: "Everyone",
                                 subtitle: "Everyone you’ve chatted with can see you",
                                 count: candidates.count)
                        scopeRow(.contacts, icon: "person.2.fill",
                                 title: "My Contacts",
                                 subtitle: "Only people saved in your contacts",
                                 count: candidates.filter { isSavedContact($0.userId) }.count)
                        scopeRow(.selected, icon: "person.crop.circle.badge.checkmark",
                                 title: "Only selected people",
                                 subtitle: "Pick exactly who can see you",
                                 count: selected.count)
                    } header: {
                        Text("Who can see me on the Map")
                    } footer: {
                        Text("They see your approximate location on the Map until you turn Ghost Mode on. You can change this or stop anytime.")
                    }

                    // When "Only selected", reveal the per-person checklist inline.
                    if scope == .selected {
                        Section {
                            ForEach(candidates, id: \.userId) { c in
                                Button {
                                    Haptics.selection()
                                    if selected.contains(c.userId) { selected.remove(c.userId) }
                                    else { selected.insert(c.userId) }
                                } label: {
                                    HStack(spacing: VoiidSpacing.md) {
                                        ProfileAvatarButton(photoURL: c.photo, name: c.name, size: 40)
                                        Text(c.name).font(.body).foregroundStyle(VoiidColor.textPrimary)
                                        Spacer()
                                        Image(systemName: selected.contains(c.userId) ? "checkmark.circle.fill" : "circle")
                                            .foregroundStyle(selected.contains(c.userId) ? VoiidColor.primary : VoiidColor.placeholder)
                                    }
                                }
                            }
                        } footer: {
                            Text("Only people you’ve chatted with appear here — the Map share needs an existing conversation.")
                        }
                    }
                }
                .voiidSettingsList()
                shareButton
            }
        }
    }

    /// A single tappable scope card (radio-style).
    private func scopeRow(_ s: Scope, icon: String, title: String, subtitle: String, count: Int) -> some View {
        Button {
            Haptics.selection()
            scope = s
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundColor(VoiidColor.primary).frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(VoiidFont.rounded(16, .semibold)).foregroundColor(VoiidColor.textPrimary)
                    Text(scope == s && s != .selected ? "\(subtitle) · \(count) \(count == 1 ? "person" : "people")" : subtitle)
                        .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
                }
                Spacer()
                Image(systemName: scope == s ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(scope == s ? VoiidColor.primary : VoiidColor.placeholder)
            }
            .contentShape(Rectangle())
        }
    }

    private var shareButton: some View {
        let ids = resolvedIds
        return VStack(spacing: 6) {
            Button {
                Haptics.rigid()
                working = true
                Task {
                    // Going visible REPLACES the audience with exactly this scope's people.
                    await engine.goVisible(to: ids)
                    working = false
                    dismiss()
                }
            } label: {
                Text(engine.isVisible ? "Update who can see me" : "Share my location")
                    .font(VoiidFont.rounded(16, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(ids.isEmpty ? VoiidColor.placeholder : VoiidColor.primary))
                    .foregroundColor(VoiidColor.textOnPrimary)
            }
            .disabled(ids.isEmpty || working)
            Text(ids.isEmpty
                 ? (scope == .contacts ? "No saved contacts you’ve chatted with yet." : "Pick at least one person.")
                 : "You appear to no one until you tap this.")
                .font(VoiidFont.rounded(11, .regular))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.md)
    }

    private var emptyCandidates: some View {
        VStack(spacing: VoiidSpacing.md) {
            Spacer()
            Image(systemName: "person.2.slash")
                .font(.system(size: 40)).foregroundColor(VoiidColor.placeholder)
            Text("No one to share with yet")
                .font(VoiidFont.rounded(18, .semibold)).foregroundColor(VoiidColor.textPrimary)
            Text("Start a chat with someone first — you can only share your Map location with people you’ve messaged.")
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoiidSpacing.xl)
            Spacer()
        }
    }

    // MARK: - Manage (current audience + remove + kill switch)

    private var manager: some View {
        List {
            activeShareSection

            if engine.audience.isEmpty {
                Section {
                    Text(engine.isVisible ? "You’re visible to no one." : "Ghost Mode is on — you’re hidden from everyone.")
                        .font(.body).foregroundStyle(VoiidColor.textSecondary)
                }
            } else {
                Section {
                    ForEach(engine.audience) { m in
                        HStack(spacing: VoiidSpacing.md) {
                            ProfileAvatarButton(photoURL: directory.photoURL(m.userId),
                                                name: directory.displayName(m.userId), size: 40)
                            Text(directory.displayName(m.userId)).font(.body).foregroundStyle(VoiidColor.textPrimary)
                            Spacer()
                            // Unchanged call — `removeFromAudience` is what already revokes
                            // this one target server-side and rekeys the rest. Only the
                            // wording and the in-flight state are new: "Remove" did not say
                            // that the share continues for everyone else, and the row gave no
                            // feedback across a rekey + redistribute round trip.
                            if removing == m.userId {
                                ProgressView()
                            } else {
                                Button {
                                    Haptics.tap()
                                    removing = m.userId
                                    Task {
                                        await engine.removeFromAudience(m.userId)
                                        removing = nil
                                    }
                                } label: {
                                    Text("Stop sharing")
                                        .font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.error)
                                }
                                .disabled(removing != nil)
                            }
                        }
                    }
                } header: {
                    Text("These people can see you")
                } footer: {
                    Text("Stopping one person rotates your Map key and stops sending them new locations — everyone else keeps seeing you. It can’t un-see a location they already saw.")
                }
            }

            Section {
                Button {
                    Haptics.tap()
                    dismiss()
                    // Re-present the chooser from the map after this sheet dismisses.
                    NotificationCenter.default.post(name: .voiidMapAddPeople, object: nil)
                } label: {
                    Label("Add people", systemImage: "person.badge.plus")
                        .foregroundStyle(VoiidColor.primary)
                }
            }

            Section {
                Button(role: .destructive) {
                    Haptics.rigid()
                    Task { await engine.killSwitch(); dismiss() }
                } label: {
                    Label("Stop all location sharing", systemImage: "hand.raised.fill")
                        .foregroundStyle(VoiidColor.error)
                }
            } footer: {
                Text("Ends every share and turns Ghost Mode on. Your location stops being taken at all.")
            }
        }
        .voiidSettingsList()
        .onReceive(clock) { now = $0 }
    }

    // MARK: - Active share (expiry + add time)

    /// The live share row: when it lapses, and the two top-up buttons.
    ///
    /// SHOWN ONLY WHEN A SERVER SHARE ACTUALLY EXISTS. `outboundShareId` — not `isVisible` —
    /// is the gate, because extend addresses a share id: while ghosted, or in the brief window
    /// where the row failed to create, there is nothing to add time to and offering the button
    /// would promise something the call cannot deliver.
    @ViewBuilder
    private var activeShareSection: some View {
        if engine.outboundShareId != nil {
            Section {
                HStack(spacing: VoiidSpacing.md) {
                    VoiidRowIcon(systemName: "clock")
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sharing ends")
                            .font(.body).foregroundStyle(VoiidColor.textPrimary)
                        Text(expiryDetail)
                            .font(.footnote).foregroundStyle(expiringSoon ? VoiidColor.error : VoiidColor.textSecondary)
                    }
                    Spacer(minLength: VoiidSpacing.sm)
                }

                addTimeRow(seconds: 15 * 60, label: "Add 15 minutes")
                addTimeRow(seconds: 60 * 60, label: "Add 1 hour")
            } header: {
                Text("Your active share")
            } footer: {
                // The 24-hour ceiling is a server rule, so say it here rather than let a tap
                // land on a smaller number than the button promised.
                Text("A Map share ends on its own so you can never be left sharing forever. Adding time tops it up, to at most 24 hours from now.")
            }
        }
    }

    /// One "+N" button. Its detail states the resulting expiry BEFORE the tap, because "add
    /// 1 hour" alone is ambiguous once the 24-hour ceiling starts clamping the result.
    private func addTimeRow(seconds: Int, label: String) -> some View {
        let projected = engine.projectedExpiry(adding: seconds)
        return VoiidSettingsRow(
            icon: "plus.circle",
            title: label,
            detail: projected.map { "Ends \(Self.clockFormatter.string(from: $0))" },
            action: extending == nil ? {
                Haptics.tap()
                extending = seconds
                Task {
                    await engine.extendOutboundShare(by: seconds)
                    // Re-tick so the countdown reflects the new ceiling immediately rather
                    // than at the next 30s beat.
                    now = Date()
                    extending = nil
                }
            } : nil
        ) {
            if extending == seconds { ProgressView() }
        }
        // The other button is disabled while one is in flight, but must not read as broken.
        .opacity(extending == nil || extending == seconds ? 1 : 0.5)
    }

    /// Time left, phrased the way the countdown is read: minutes near the end, hours before.
    private var expiryDetail: String {
        guard let exp = engine.outboundExpiresAt else {
            // The row was restored without a ceiling (the "unknown" sentinel). Say so rather
            // than invent a time.
            return "Time remaining unknown — add time to set it."
        }
        let left = exp.timeIntervalSince(now)
        guard left > 0 else { return "Expired — add time to keep sharing." }
        let mins = Int(left / 60)
        if mins < 60 { return "Expires in \(max(1, mins))m" }
        let hours = mins / 60
        let rem = mins % 60
        return rem == 0 ? "Expires in \(hours)h" : "Expires in \(hours)h \(rem)m"
    }

    /// Under an hour turns the countdown red — the point at which "it will just stop" stops
    /// being theoretical.
    private var expiringSoon: Bool {
        guard let exp = engine.outboundExpiresAt else { return false }
        return exp.timeIntervalSince(now) < 3600
    }

    private static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
}

extension Notification.Name {
    /// Posted by the manage sheet's "Add people" so the Map re-presents the chooser after
    /// the current sheet dismisses (SwiftUI cannot swap one sheet for another in place).
    static let voiidMapAddPeople = Notification.Name("voiidMapAddPeople")
}

// MARK: - First-open explainer
//
// REPLACED by the four-step flow. `MapExplainerView` was one plain screen — an SF Symbol, a
// title and two buttons — that did the intro and the audience choice at once and jumped
// straight to the iOS location prompt with no explanation. It now lives as two proper
// screens, Main/MapIntroScreen.swift and Main/MapPrivacyScreen.swift, orchestrated by
// Main/MapOnboardingFlow.swift. Nothing here replaces it, so the type is simply gone.
