import SwiftUI

struct GroupMemberSubject: Identifiable {
    let id: String
    let name: String
    let photoURL: String?
    init(id: String, name: String, photoURL: String?) { self.id = id; self.name = name; self.photoURL = photoURL }
    init(_ member: ConvMember) { self.init(id: member.userId, name: member.name ?? "Voiid member", photoURL: member.photoURL) }
}

struct LiveGroupAvatar: View {
    let members: [ConvMember]
    var size: CGFloat = 88
    var body: some View {
        ZStack {
            if members.isEmpty {
                RoundedRectangle(cornerRadius: 26).fill(VoiidColor.fieldFill)
                Image(systemName: "person.3.fill").font(.system(size: size * 0.3)).foregroundStyle(VoiidColor.primary)
            } else if members.count == 1 {
                ProfileAvatarButton(photoURL: members[0].photoURL, name: members[0].name, size: size)
            } else {
                ForEach(Array(members.prefix(4).enumerated()), id: \.element.userId) { index, member in
                    ProfileAvatarButton(photoURL: member.photoURL, name: member.name, size: size * (members.count == 2 ? 0.66 : 0.48))
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                        .offset(offset(for: index))
                }
            }
        }.frame(width: size, height: size).accessibilityLabel("Group members")
    }
    private func offset(for index: Int) -> CGSize {
        if members.count == 2 { return CGSize(width: size * (index == 0 ? -0.16 : 0.16), height: size * (index == 0 ? -0.16 : 0.16)) }
        if members.count == 3 {
            return index == 0 ? CGSize(width: 0, height: -size * 0.24) : CGSize(width: index == 1 ? -size * 0.25 : size * 0.25, height: size * 0.25)
        }
        return CGSize(width: index % 2 == 0 ? -size * 0.25 : size * 0.25, height: index < 2 ? -size * 0.25 : size * 0.25)
    }

}

struct GroupSecurityVerificationSheet: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var members: [ConvMember] = []
    @State private var loading = true
    @State private var error: String?
    @State private var selected: GroupMemberSubject?
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error {
                    Text(error).foregroundStyle(VoiidColor.textSecondary)
                    Button("Retry") { Task { await load() } }
                }
                Section {
                    ForEach(members, id: \.userId) { member in
                        Button { selected = .init(member) } label: {
                            HStack(spacing: 12) {
                                ProfileAvatarButton(photoURL: member.photoURL, name: member.name, size: 40)
                                Text(member.name ?? "Voiid member").foregroundStyle(VoiidColor.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption).foregroundStyle(VoiidColor.textSecondary)
                            }.padding(.vertical, 4)
                        }
                    }
                } footer: { Text("Choose a member to compare the security code for your devices.") }
                if !loading && error == nil && members.isEmpty { Text("No other members to verify.") }
            }
            .scrollContentBackground(.hidden).background(VoiidColor.background).softTopEdgeEffect()
            .navigationTitle("Verify a member").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await load() }
            .sheet(item: $selected) { SafetyNumberView(peerUserId: $0.id, peerName: $0.name) }
        }.tint(VoiidColor.primary)
    }
    private func load() async {
        loading = true; error = nil; defer { loading = false }
        do { members = try await ChatService.shared.members(conversationId: conversationId).filter { $0.userId != TokenStore.shared.userId } }
        catch { self.error = error.localizedDescription }
    }
}

struct GroupMemberProfileSheet: View {
    let member: GroupMemberSubject
    @Environment(\.dismiss) private var dismiss
    @State private var profile: UserProfile?
    @State private var error: String?
    @State private var verifying = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    ProfileAvatarButton(photoURL: profile?.photoURL ?? member.photoURL, name: profile?.name ?? member.name, size: 88)
                    Text(profile?.name ?? member.name).font(VoiidFont.rounded(25, .bold))
                    if let username = profile?.username, !username.isEmpty { Text("@\(username)").foregroundStyle(VoiidColor.textSecondary) }
                    if let about = profile?.about, !about.isEmpty {
                        Text(about).font(VoiidFont.rounded(15)).frame(maxWidth: .infinity, alignment: .leading).padding(20).liveGroupCard()
                    }
                    if member.id != TokenStore.shared.userId {
                        Button { verifying = true } label: {
                            Label("Verify encryption", systemImage: "lock.shield").frame(maxWidth: .infinity).padding(18).liveGroupCard()
                        }
                    }
                    if let error { Text(error).font(.footnote).foregroundStyle(VoiidColor.textSecondary) }
                }.padding(24).frame(maxWidth: .infinity)
            }.background(VoiidColor.background).softTopEdgeEffect()
                .foregroundStyle(VoiidColor.textPrimary)
                .navigationTitle("Profile").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
                .task {
                    do { profile = try await ChatService.shared.userProfile(userId: member.id) }
                    catch { self.error = error.localizedDescription }
                }
                .sheet(isPresented: $verifying) { SafetyNumberView(peerUserId: member.id, peerName: profile?.name ?? member.name) }
        }.tint(VoiidColor.primary)
    }
}

struct LiveGroupAddMembersSheet: View {
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var contacts: [VContact] = []
    @State private var members: [ConvMember] = []
    @State private var search = ""
    @State private var loading = true
    @State private var adding: String?
    @State private var error: String?
    private var candidates: [VContact] {
        contacts.filter { contact in
            !members.contains { $0.userId == contact.userId } &&
            (search.isEmpty || contact.displayName.localizedCaseInsensitiveContains(search))
        }
    }
    var body: some View {
        NavigationStack {
            List {
                if loading { ProgressView().frame(maxWidth: .infinity) }
                if let error { Text(error).foregroundStyle(VoiidColor.error) }
                if !loading && candidates.isEmpty { Text("No more contacts to add.").foregroundStyle(VoiidColor.textSecondary) }
                ForEach(candidates) { contact in
                    Button { Task { await add(contact) } } label: {
                        HStack(spacing: 12) {
                            ProfileAvatarButton(photoURL: contact.photoURL, name: contact.displayName, size: 40)
                            Text(contact.displayName).foregroundStyle(VoiidColor.textPrimary)
                            Spacer()
                            if adding == contact.userId { ProgressView() } else { Image(systemName: "plus.circle.fill") }
                        }.padding(.vertical, 4)
                    }.disabled(adding != nil)
                }
            }.scrollContentBackground(.hidden).background(VoiidColor.background).softTopEdgeEffect()
                .searchable(text: $search, prompt: "Search contacts")
                .navigationTitle("Add members").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() }.disabled(adding != nil) } }
                .interactiveDismissDisabled(adding != nil)
                .task {
                    defer { loading = false }
                    do {
                        members = try await ChatService.shared.members(conversationId: conversationId)
                        contacts = try await ContactsService.shared.discover().matches
                    } catch { self.error = error.localizedDescription }
                }
        }.tint(VoiidColor.primary)
    }
    private func add(_ contact: VContact) async {
        guard adding == nil else { return }; adding = contact.userId; error = nil
        defer { adding = nil }
        do {
            try await GroupEngine.shared.addMember(conversationId: conversationId, userId: contact.userId,
                                                   existingMemberUserIds: members.map(\.userId))
            members = try await ChatService.shared.members(conversationId: conversationId)
            Haptics.success()
        } catch { self.error = error.localizedDescription }
    }
}
