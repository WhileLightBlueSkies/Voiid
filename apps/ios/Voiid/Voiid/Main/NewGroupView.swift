//
//  NewGroupView.swift
//  Voiid
//
//  "New group" flow. Discovers the user's contacts on VOIID (same hashed,
//  privacy-preserving discovery as NewChatView), lets them pick members + a
//  group name, then creates the group server-side via
//  POST /conversations/create {type:'group'} and opens it.
//

import SwiftUI

struct NewGroupView: View {
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    /// Called with the new group conversation to open after creation.
    var onCreate: (VConversation) -> Void

    @State private var loading = true
    /// Raised when the picker hits the member ceiling.
    @State private var atCapacity = false
    @State private var error: String?
    @State private var contacts: [VContact] = []
    @State private var selected: Set<String> = []        // selected contact userIds
    @State private var groupName = ""
    @State private var search = ""
    @State private var creating = false
    @State private var creationError: String?

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !selected.isEmpty && !creating
    }

    private var filtered: [VContact] {
        guard !search.isEmpty else { return contacts }
        return contacts.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    loadingState
                } else if let error {
                    errorState(error)
                } else {
                    content
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .alert("That's the limit", isPresented: $atCapacity) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("A group can have up to \(Self.maxOthers + 1) people, including you.")
        }
        .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundColor(VoiidColor.primary).disabled(creating)
                }
            }
            .interactiveDismissDisabled(creating)
            .alert("Couldn't create group", isPresented: Binding(get: { creationError != nil }, set: { if !$0 { creationError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(creationError ?? "") }
            .task { await load() }
        }
    }

    private var content: some View {
        List {
            Section {
                VStack(spacing: 14) {
                    Image(systemName: "person.3.fill")
                        .font(.system(size: 30)).foregroundStyle(VoiidColor.primary)
                        .frame(width: 88, height: 88)
                        .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 26))
                    Text("A space for your people").font(VoiidFont.rounded(22, .bold))
                    Text("Choose a name and add people to start your private group.")
                        .font(VoiidFont.rounded(13)).foregroundStyle(VoiidColor.textSecondary).multilineTextAlignment(.center)
                    TextField("Group name", text: $groupName)
                        .font(VoiidFont.rounded(16, .medium)).padding(16).liveGroupCard()
                        .onChange(of: groupName) { _, value in groupName = String(value.prefix(64)) }
                    if !selected.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(contacts.filter { selected.contains($0.userId) }) { contact in
                                    Button { toggle(contact) } label: {
                                        VStack(spacing: 6) {
                                            ProfileAvatarButton(photoURL: contact.photoURL, name: contact.displayName, size: 40)
                                                .overlay(alignment: .topTrailing) { Image(systemName: "minus.circle.fill").font(.system(size: 15)).foregroundStyle(VoiidColor.primary) }
                                            Text(contact.displayName.split(separator: " ").first.map(String.init) ?? contact.displayName)
                                                .font(VoiidFont.rounded(11)).lineLimit(1)
                                        }.frame(width: 58)
                                    }.buttonStyle(.plain)
                                }
                            }.padding(.vertical, 4)
                        }
                    }
                }.frame(maxWidth: .infinity).listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
            }
            Section("Add members · \(selected.count) selected") {
                if filtered.isEmpty { Text("No contacts on Voiid to add.").font(VoiidFont.rounded(14)).foregroundStyle(VoiidColor.textSecondary) }
                ForEach(filtered) { contact in
                    Button { toggle(contact) } label: { row(contact) }.buttonStyle(.plain).disabled(creating)
                }
            }
        }
        .listStyle(.insetGrouped).scrollContentBackground(.hidden).softTopEdgeEffect()
        .searchable(text: $search, prompt: "Search contacts")
        .safeAreaInset(edge: .bottom) {
            Button { Task { await create() } } label: {
                HStack {
                    if creating { ProgressView().tint(VoiidColor.textOnPrimary) }
                    Text(creating ? "Creating group…" : "Create group").font(VoiidFont.rounded(16, .semibold))
                }.frame(maxWidth: .infinity).frame(height: 50)
                    .foregroundStyle(VoiidColor.textOnPrimary)
                    .background(VoiidColor.primary.opacity(canCreate ? 1 : 0.45), in: Capsule())
            }.buttonStyle(.plain).disabled(!canCreate).padding(16).background(VoiidColor.background)
        }
    }

    private func row(_ c: VContact) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ProfileAvatarButton(photoURL: c.photoURL, name: c.displayName, size: 40)
            Text(c.displayName).font(VoiidFont.rounded(16, .medium)).foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Image(systemName: selected.contains(c.userId) ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundColor(selected.contains(c.userId) ? VoiidColor.primary : VoiidColor.placeholder)
        }
        .contentShape(Rectangle())
    }

    private var loadingState: some View {
        VStack(spacing: VoiidSpacing.md) {
            ProgressView()
            Text("Finding your contacts on VOIID…")
                .font(VoiidFont.rounded(13)).foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 40)).foregroundColor(VoiidColor.textSecondary)
            Text(message).font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, VoiidSpacing.xl)
            Button("Try again") { Task { await load(force: true) } }.foregroundColor(VoiidColor.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// One short of the server's 1000-member cap: the creator occupies the last seat.
    private static let maxOthers = 999

    private func toggle(_ c: VContact) {
        Haptics.selection()
        if selected.contains(c.userId) {
            selected.remove(c.userId)
        } else {
            // 999 OTHERS, because you are the thousandth. The server enforces 1000 members
            // (036_group_roles.sql); refusing here means the user finds out while choosing
            // rather than after tapping Create and losing the selection to a 400.
            guard selected.count < Self.maxOthers else {
                atCapacity = true
                return
            }
            selected.insert(c.userId)
        }
    }

    private func load(force: Bool = false) async {
        loading = true; error = nil
        do {
            contacts = try await ContactsService.shared.discover(forceRefresh: force).matches
        } catch {
            self.error = (error as? APIError)?.errorDescription
                ?? "Couldn’t access contacts. Enable Contacts access in Settings."
        }
        loading = false
    }

    private func create() async {
        guard canCreate else { return }
        creating = true
        let chosen = contacts.filter { selected.contains($0.userId) }
        let name = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        if let conv = await chat.createGroup(name: name, members: chosen) {
            dismiss()
            onCreate(conv)
        } else { creationError = chat.loadError ?? "Couldn’t create this group. Try again." }
        creating = false
    }
}
