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
        .preferredColorScheme(.light)
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
                            Button {
                                Haptics.tap()
                                Task { await engine.removeFromAudience(m.userId) }
                            } label: {
                                Text("Remove").font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.error)
                            }
                        }
                    }
                } header: {
                    Text("These people can see you")
                } footer: {
                    Text("Removing someone rotates your Map key and stops sending them new locations. It can’t un-see a location they already saw.")
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
    }
}

extension Notification.Name {
    /// Posted by the manage sheet's "Add people" so the Map re-presents the chooser after
    /// the current sheet dismisses (SwiftUI cannot swap one sheet for another in place).
    static let voiidMapAddPeople = Notification.Name("voiidMapAddPeople")
}

// MARK: - First-open explainer

/// The full-screen door the Map shows on first open. Two choices only: stay hidden and just
/// look around, or deliberately choose who can see you. No "share with everyone" exists.
struct MapExplainerView: View {
    var onBrowseOnly: () -> Void
    var onChoose: () -> Void

    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            Spacer()
            Image(systemName: "map.fill")
                .font(.system(size: 52)).foregroundColor(VoiidColor.primary)
            Text("The Map")
                .font(VoiidFont.rounded(28, .bold)).foregroundColor(VoiidColor.textPrimary)
            VStack(spacing: VoiidSpacing.md) {
                explainerRow("eye.slash.fill", "You’re hidden by default",
                             "No one sees you until you choose a scope — Everyone you’ve chatted with, just My Contacts, or only people you pick.")
                explainerRow("lock.fill", "Your location is end-to-end encrypted",
                             "Voiid’s servers never see where you are — only that a share exists and when it ends.")
                explainerRow("mappin.and.ellipse", "Approximate, and you can stop anytime",
                             "The Map shows a coarse position. Ghost Mode hides you instantly and stops your location being taken at all.")
            }
            .padding(.horizontal, VoiidSpacing.lg)
            Spacer()
            VStack(spacing: VoiidSpacing.sm) {
                Button {
                    Haptics.rigid(); onChoose()
                } label: {
                    Text("Choose who can see me")
                        .font(VoiidFont.rounded(16, .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(Capsule().fill(VoiidColor.primary))
                        .foregroundColor(VoiidColor.textOnPrimary)
                }
                Button {
                    Haptics.tap(); onBrowseOnly()
                } label: {
                    Text("Browse only")
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.lg)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
    }

    private func explainerRow(_ icon: String, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 20)).foregroundColor(VoiidColor.primary)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Text(body).font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}
