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
        .onAppear { selected = Set(engine.audience.map(\.userId)) }
    }

    // MARK: - Choose (add / initial pick)

    private var chooser: some View {
        VStack(spacing: 0) {
            if candidates.isEmpty {
                emptyCandidates
            } else {
                List {
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
                        Text("Only people you’ve chatted with appear here. Each person you pick can see your approximate location on the Map until you turn Ghost Mode on.")
                    }
                }
                .voiidSettingsList()
                shareButton
            }
        }
    }

    private var shareButton: some View {
        VStack(spacing: 6) {
            Button {
                Haptics.rigid()
                working = true
                Task {
                    let ids = Array(selected)
                    if engine.isVisible { await engine.addToAudience(ids) }
                    else { await engine.goVisible(to: ids) }
                    working = false
                    dismiss()
                }
            } label: {
                Text(engine.isVisible ? "Update who can see me" : "Share my location")
                    .font(VoiidFont.rounded(16, .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Capsule().fill(selected.isEmpty ? VoiidColor.placeholder : VoiidColor.primary))
                    .foregroundColor(VoiidColor.textOnPrimary)
            }
            .disabled(selected.isEmpty || working)
            Text("You appear to no one until you tap this.")
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
                             "No one can see you on the Map until you choose them by name. There’s no ‘share with everyone’.")
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
