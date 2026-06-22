//
//  GroupInfoView.swift
//  Voiid
//
//  Group info (WhatsApp-style): header (photo/name/count), shared media,
//  members list w/ admin badges + actions, add members + invite link,
//  mute, and exit group. Native back button. Dummy data.
//

import SwiftUI

struct GroupInfoView: View {
    let conversation: VConversation
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var muted = false
    @State private var members: [VMember] = []
    @State private var loadingMembers = true
    @State private var memberAction: VMember?
    @State private var viewPhoto = false
    @State private var showAllMedia = false

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.lg) {
                headerCard
                sharedMediaCard
                membersCard
                actionsCard
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.vertical, VoiidSpacing.lg)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(VoiidColor.primary)
        .onAppear { session.hideTabBar = true }
        .task { await loadMembers() }
        .fullScreenCover(isPresented: $viewPhoto) {
            ProfilePhotoViewer(title: conversation.title, imageName: conversation.photoName) { viewPhoto = false }
        }
        .sheet(isPresented: $showAllMedia) { SharedMediaSheet(title: conversation.title) }
        .confirmationDialog(memberAction?.name ?? "", isPresented: Binding(
            get: { memberAction != nil }, set: { if !$0 { memberAction = nil } }),
            titleVisibility: .visible) {
            Button("Message") {}
            Button(memberAction?.role == .admin ? "Dismiss as admin" : "Make group admin") {}
            Button("Remove from group", role: .destructive) {
                if let m = memberAction { members.removeAll { $0.id == m.id } }
            }
        }
    }

    // Header: big photo, editable name, "Group · N members"
    private var headerCard: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); viewPhoto = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    Circle().fill(VoiidColor.fieldFill).frame(width: 110, height: 110)
                        .overlay(Image("VoiidWordmark").resizable().scaledToFit().frame(width: 56).opacity(0.25))
                    Circle().fill(VoiidColor.accent).frame(width: 32, height: 32)
                        .overlay(Image(systemName: "camera.fill").font(.system(size: 13)).foregroundColor(VoiidColor.primary))
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                }
            }
            .buttonStyle(.plain)
            HStack(spacing: 6) {
                Text(conversation.title).font(VoiidFont.rounded(22, .bold)).foregroundColor(VoiidColor.textPrimary)
                Image(systemName: "pencil").font(.system(size: 14)).foregroundColor(VoiidColor.textSecondary)
            }
            Text(loadingMembers ? "Group" : "Group · \(members.count) members")
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.md)
    }

    // Shared media / links / docs
    private var sharedMediaCard: some View {
        card {
            HStack {
                Text("Media, links & docs").font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button("See all") { Haptics.tap(); showAllMedia = true }
                    .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.primary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VoiidSpacing.sm) {
                    ForEach(DummyData.sharedMedia.prefix(6)) { _ in
                        RoundedRectangle(cornerRadius: VoiidRadius.md)
                            .fill(VoiidColor.accent.opacity(0.35))
                            .frame(width: 72, height: 72)
                            .overlay(Image(systemName: "photo").foregroundColor(VoiidColor.primary))
                    }
                }
            }
        }
    }

    // Members list
    private var membersCard: some View {
        card {
            HStack {
                Text(loadingMembers ? "Members" : "\(members.count) members")
                    .font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                if loadingMembers { ProgressView() }
                else { Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.textSecondary) }
            }
            // Add members + invite link
            actionRow(icon: "person.badge.plus", text: "Add members", tint: VoiidColor.primary) {}
            actionRow(icon: "link", text: "Invite via link", tint: VoiidColor.primary) {}
            Divider().background(VoiidColor.divider.opacity(0.4))
            ForEach(members) { m in
                Button { if !m.isYou { Haptics.tap(); memberAction = m } } label: { memberRow(m) }
                    .buttonStyle(.plain)
            }
        }
    }

    private func memberRow(_ m: VMember) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidAvatar(size: 42, imageName: m.photoName).clipShape(Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(m.isYou ? "You" : m.name).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                if let s = m.statusText {
                    Text(s).font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
                }
            }
            Spacer()
            if m.role == .admin {
                Text("admin").font(VoiidFont.rounded(11, .medium)).foregroundColor(VoiidColor.primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(VoiidColor.accent.opacity(0.4)).clipShape(Capsule())
            }
        }
        .padding(.vertical, 6)
    }

    // Mute + Exit
    private var actionsCard: some View {
        card {
            Toggle(isOn: $muted) {
                Label("Mute notifications", systemImage: "bell.slash")
                    .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
            }
            .tint(VoiidColor.primary)
            Divider().background(VoiidColor.divider.opacity(0.4))
            actionRow(icon: "rectangle.portrait.and.arrow.right", text: "Exit group", tint: VoiidColor.error) {
                Haptics.rigid(); dismiss()
            }
            actionRow(icon: "hand.raised", text: "Report group", tint: VoiidColor.error) {}
        }
    }

    // MARK: data

    /// Load the real group membership from the backend (GET /conversations/:id).
    /// The creator/you is flagged via the current user id; admins show a badge.
    private func loadMembers() async {
        loadingMembers = true
        defer { loadingMembers = false }
        guard let convMembers = try? await ChatService.shared.members(conversationId: conversation.id)
        else { return }
        let myId = TokenStore.shared.userId
        members = convMembers.map { m in
            VMember(id: m.userId,
                    name: m.name ?? "VOIID user",
                    phone: "",
                    photoName: nil,
                    role: m.isAdmin ? .admin : .member,
                    statusText: nil,
                    isYou: m.userId == myId)
        }
        // Put "You" first, then admins, then everyone else (alphabetical).
        members.sort {
            if $0.isYou != $1.isYou { return $0.isYou }
            if ($0.role == .admin) != ($1.role == .admin) { return $0.role == .admin }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: helpers
    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) { content() }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private func actionRow(icon: String, text: String, tint: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            HStack(spacing: VoiidSpacing.md) {
                Image(systemName: icon).font(.system(size: 18)).foregroundColor(tint).frame(width: 24)
                Text(text).font(VoiidFont.rounded(16, .regular)).foregroundColor(tint)
                Spacer()
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
