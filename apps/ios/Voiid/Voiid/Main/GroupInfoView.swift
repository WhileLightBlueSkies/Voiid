import SwiftUI

struct GroupInfoView: View {
    let conversation: VConversation
    @Binding var pendingCall: CallKind?
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var members: [ConvMember] = []
    @State private var loading = true
    @State private var muted = false
    @State private var adding = false
    @State private var media = false
    @State private var verifying = false
    @State private var profile: GroupMemberSubject?
    @State private var error: String?
    @State private var busy = false
    @State private var removal: GroupMemberSubject?
    @State private var transfer: GroupMemberSubject?

    private var myRole: MemberRole { members.first { $0.userId == TokenStore.shared.userId }?.role ?? .member }
    private var canManage: Bool { myRole == .owner || myRole == .admin }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                VStack(spacing: 12) {
                    LiveGroupAvatar(members: members, size: 88)
                    Text(conversation.title).font(VoiidFont.rounded(27, .bold)).multilineTextAlignment(.center)
                    Text(loading ? "Loading members…" : "\(members.count) members · Private group")
                        .font(VoiidFont.rounded(13)).foregroundStyle(VoiidColor.textSecondary)
                }.frame(maxWidth: .infinity).padding(.vertical, 6)
                HStack(spacing: 10) {
                    quickAction("bubble.left", "Message") { dismiss() }
                    quickAction("phone", "Voice") { pendingCall = .voice; dismiss() }
                    quickAction("video", "Video") { pendingCall = .video; dismiss() }
                }
                VStack(spacing: 0) {
                    row("photo.on.rectangle", "Shared media", "Photos, links & files") { media = true }
                    Divider().padding(.leading, 52)
                    Menu {
                        if muted { Button("Unmute") { MuteStore.unmute(conversation.id); muted = false } }
                        ForEach(MuteStore.Duration.allCases) { duration in
                            Button("Mute for \(duration.title)") { MuteStore.mute(conversation.id, for: duration); muted = true }
                        }
                    } label: { rowLabel("bell", "Notifications", muted ? "Muted" : "All messages") }
                    Divider().padding(.leading, 52)
                    row("lock.shield", "Verify encryption", "Compare security codes with members") { verifying = true }
                }.liveGroupCard()
                VStack(alignment: .leading, spacing: 12) {
                    Text("MEMBERS · \(members.count)").font(VoiidFont.rounded(11, .semibold)).tracking(1.2).foregroundStyle(VoiidColor.textSecondary)
                    VStack(spacing: 0) {
                        if canManage { row("person.badge.plus", "Add members", "") { adding = true } }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(24) }
                        ForEach(members, id: \.userId) { member in
                            memberRow(member)
                        }
                        if !loading && members.isEmpty {
                            Button("Reload members") { Task { await load() } }.padding(20)
                        }
                    }.liveGroupCard()
                }
                Label("Only group members can read messages and listen to calls.", systemImage: "lock.fill")
                    .font(VoiidFont.rounded(12)).foregroundStyle(VoiidColor.textSecondary).multilineTextAlignment(.center)
            }.padding(20)
        }
        .softTopEdgeEffect()
        .background(VoiidColor.background.ignoresSafeArea())
        .foregroundStyle(VoiidColor.textPrimary)
        .navigationTitle("Group info").navigationBarTitleDisplayMode(.inline)
        .tint(VoiidColor.primary)
        .onAppear { session.hideTabBar = true; muted = MuteStore.isMuted(conversation.id) }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $media) { SharedMediaSheet(title: conversation.title, conversationId: conversation.id) }
        .sheet(isPresented: $verifying) { GroupSecurityVerificationSheet(conversationId: conversation.id) }
        .sheet(item: $profile) { GroupMemberProfileSheet(member: $0) }
        .sheet(isPresented: $adding, onDismiss: { Task { await load() } }) {
            LiveGroupAddMembersSheet(conversationId: conversation.id)
        }
        .alert("Couldn't complete action", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(error ?? "") }
        .confirmationDialog("Remove \(removal?.name ?? "member")?", isPresented: Binding(get: { removal != nil }, set: { if !$0 { removal = nil } }), titleVisibility: .visible) {
            Button("Remove from group", role: .destructive) {
                guard let target = removal else { return }
                perform {
                    try await GroupEngine.shared.removeMember(conversationId: conversation.id, userId: target.id,
                                                              remainingMemberUserIds: members.filter { $0.userId != target.id }.map(\.userId))
                }
            }
        }
        .confirmationDialog("Transfer ownership to \(transfer?.name ?? "member")?", isPresented: Binding(get: { transfer != nil }, set: { if !$0 { transfer = nil } }), titleVisibility: .visible) {
            Button("Transfer ownership") {
                guard let target = transfer else { return }
                perform { try await ChatService.shared.transferOwnership(conversationId: conversation.id, userId: target.id) }
            }
        } message: { Text("You will remain an admin. Only the new owner can transfer ownership again.") }
    }

    private func memberRow(_ member: ConvMember) -> some View {
        HStack(spacing: 12) {
            Button { profile = .init(member) } label: {
                HStack(spacing: 12) {
                    ProfileAvatarButton(photoURL: member.photoURL, name: member.name, size: 40)
                    Text(member.userId == TokenStore.shared.userId ? "You" : member.name ?? "Voiid member")
                        .font(VoiidFont.rounded(15, .medium)).foregroundStyle(VoiidColor.textPrimary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Spacer(minLength: 4)
            if member.role != .member {
                Text(member.role == .owner ? "Owner" : "Admin")
                    .font(VoiidFont.rounded(11, .medium)).foregroundStyle(VoiidColor.primary)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                    .background(VoiidColor.primary.opacity(0.12), in: Capsule())
            }
            if canManage && member.userId != TokenStore.shared.userId && member.role != .owner {
                Menu {
                    if myRole == .owner || member.role == .member {
                        Button(member.role == .admin ? "Remove admin role" : "Make admin") {
                            perform { try await ChatService.shared.setMemberRole(conversationId: conversation.id, userId: member.userId,
                                                                                role: member.role == .admin ? "member" : "admin") }
                        }
                        Button("Remove member", role: .destructive) { removal = .init(member) }
                    }
                    if myRole == .owner { Button("Transfer ownership") { transfer = .init(member) } }
                } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                    .disabled(busy).accessibilityLabel("Manage \(member.name ?? "member")")
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func quickAction(_ icon: String, _ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 9) {
                Image(systemName: icon).font(.system(size: 21))
                Text(title).font(VoiidFont.rounded(12, .semibold))
            }.foregroundStyle(VoiidColor.primary).frame(maxWidth: .infinity).padding(.vertical, 16)
        }.buttonStyle(.plain).liveGroupCard()
    }
    private func row(_ icon: String, _ title: String, _ subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { rowLabel(icon, title, subtitle) }.buttonStyle(.plain)
    }
    private func rowLabel(_ icon: String, _ title: String, _ subtitle: String) -> some View {
        HStack(spacing: 13) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(VoiidColor.primary).frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(VoiidFont.rounded(15, .medium)).foregroundStyle(VoiidColor.textPrimary)
                if !subtitle.isEmpty { Text(subtitle).font(VoiidFont.rounded(12)).foregroundStyle(VoiidColor.textSecondary) }
            }
            Spacer()
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(VoiidColor.textSecondary)
        }.padding(16).contentShape(Rectangle())
    }
    private func perform(_ action: @escaping () async throws -> Void) {
        guard !busy else { return }; busy = true
        Task {
            defer { busy = false }
            do { try await action(); await load() }
            catch { self.error = error.localizedDescription }
        }
    }
    private func load() async {
        loading = true; defer { loading = false }
        do {
            members = try await ChatService.shared.members(conversationId: conversation.id)
            members.sort {
                if ($0.userId == TokenStore.shared.userId) != ($1.userId == TokenStore.shared.userId) { return $0.userId == TokenStore.shared.userId }
                return ($0.name ?? "").localizedCaseInsensitiveCompare($1.name ?? "") == .orderedAscending
            }
        } catch { self.error = error.localizedDescription }
    }
}

extension View {
    func liveGroupCard() -> some View {
        background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(VoiidColor.divider, lineWidth: 1))
    }
}
