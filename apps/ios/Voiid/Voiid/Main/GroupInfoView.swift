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
    /// Surfaced verbatim from the server so "only the owner can dismiss an admin" reaches
    /// the person who tried, instead of a generic failure.
    @State private var actionError: String?

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
        // Hide on appear; do NOT reset on disappear — popping back to the CHAT (also a
        // detail) must keep the bar hidden. It is restored when a root tab page appears
        // (ChatDetailView.onDisappear + each tab root's onAppear).
        .onAppear { session.hideTabBar = true }
        .task { await loadMembers() }
        .fullScreenCover(isPresented: $viewPhoto) {
            ProfilePhotoViewer(title: conversation.title, imageName: conversation.photoName) { viewPhoto = false }
        }
        .sheet(isPresented: $showAllMedia) { SharedMediaSheet(title: conversation.title, conversationId: conversation.id) }
        .alert("Couldn't do that", isPresented: Binding(
            get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
        .confirmationDialog(memberAction?.name ?? "", isPresented: Binding(
            get: { memberAction != nil }, set: { if !$0 { memberAction = nil } }),
            titleVisibility: .visible) {
            Button("Message") {}
            // WIRED. This was an empty closure: the button rendered, said the right thing,
            // and did nothing at all. The server decides whether the caller may act — an
            // admin can promote, but only the OWNER can dismiss an admin — so the error is
            // surfaced rather than the action being hidden, which would leave an admin
            // wondering why a button they can see refuses to work.
            if memberAction?.role != .owner {
                Button(memberAction?.role == .admin ? "Dismiss as admin" : "Make group admin") {
                    guard let m = memberAction else { return }
                    let next: MemberRole = m.role == .admin ? .member : .admin
                    Task { await setRole(of: m, to: next) }
                }
            }
            // Only the owner sees this, and only for someone else: handing the group over is
            // a one-way action with no undo, so it is deliberately not folded into the role
            // menu above.
            if myRole == .owner, let m = memberAction, m.role != .owner {
                Button("Transfer ownership to \(m.name)") {
                    Task { await transferOwnership(to: m) }
                }
            }
            Button("Remove from group", role: .destructive) {
                if let m = memberAction {
                    members.removeAll { $0.id == m.id }
                    // Real MLS removal: rekeys the group + broadcasts the removal commit
                    // to the remaining members so the removed user can't read new messages.
                    let remaining = members.map { $0.id }
                    let convId = conversation.id
                    let removedId = m.id
                    Task { await GroupEngine.shared.removeMember(
                        conversationId: convId, userId: removedId, remainingMemberUserIds: remaining) }
                }
            }
        }
    }

    // Header: big photo, editable name, "Group · N members"
    private var headerCard: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button { Haptics.tap(); viewPhoto = true } label: {
                ZStack(alignment: .bottomTrailing) {
                    Circle().fill(VoiidColor.fieldFill).frame(width: 110, height: 110)
                        .overlay(BrandWordmark(size: 19, color: VoiidColor.textSecondary, opacity: 0.25))
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

    /// Recent shared PHOTOS in this group, newest first — real, from the message store.
    private var recentPhotos: [MediaRef] {
        Array(ChatEngine.shared.messages(conversationId: conversation.id)
            .compactMap { $0.media }.filter { $0.mime.hasPrefix("image/") }
            .reversed().prefix(6))
    }

    // Shared media / links / docs — real conversation media (never dummy).
    private var sharedMediaCard: some View {
        card {
            HStack {
                Text("Media, links & docs").font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                if !recentPhotos.isEmpty {
                    Button("See all") { Haptics.tap(); showAllMedia = true }
                        .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.primary)
                }
            }
            if recentPhotos.isEmpty {
                Text("No media shared yet")
                    .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ForEach(recentPhotos, id: \.mediaUrl) { ref in
                            SharedMediaThumb(ref: ref)
                                .frame(width: 72, height: 72).clipped()
                                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
                        }
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
            // The owner used to render as NOTHING — this branch only knew 'admin', so the
            // one person who can transfer the group looked like an ordinary member.
            if m.role != .member {
                Text(m.role == .owner ? "owner" : "admin")
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundColor(m.role == .owner ? VoiidColor.textOnPrimary : VoiidColor.primary)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(m.role == .owner ? VoiidColor.primary : VoiidColor.accent.opacity(0.4))
                    .clipShape(Capsule())
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
    /// This device's own role in the group — what the menu above is allowed to offer.
    private var myRole: MemberRole {
        members.first(where: { $0.isYou })?.role ?? .member
    }

    /// Promote or demote, then reload so the badge and the menu agree with the server.
    /// Reloading rather than mutating locally is deliberate: the server may refuse, and a
    /// local flip would show a role the group does not actually have.
    private func setRole(of member: VMember, to role: MemberRole) async {
        do {
            try await ChatService.shared.setMemberRole(
                conversationId: conversation.id, userId: member.id, role: role.rawValue)
            await loadMembers()
        } catch {
            actionError = (error as? APIError)?.errorDescription ?? "Couldn't change that role."
        }
    }

    private func transferOwnership(to member: VMember) async {
        do {
            try await ChatService.shared.transferOwnership(
                conversationId: conversation.id, userId: member.id)
            await loadMembers()
        } catch {
            actionError = (error as? APIError)?.errorDescription ?? "Couldn't transfer ownership."
        }
    }

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
                    role: m.role,
                    statusText: nil,
                    isYou: m.userId == myId)
        }
        // "You" first, then the owner, then admins, then everyone else alphabetically.
        // Ranked rather than compared pairwise on `.admin`: that test sorted the owner in
        // with ordinary members, so the one person who runs the group sat wherever the
        // alphabet put them.
        func rank(_ r: MemberRole) -> Int { r == .owner ? 0 : (r == .admin ? 1 : 2) }
        members.sort {
            if $0.isYou != $1.isYou { return $0.isYou }
            if rank($0.role) != rank($1.role) { return rank($0.role) < rank($1.role) }
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
