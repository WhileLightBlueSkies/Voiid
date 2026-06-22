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
    @State private var error: String?
    @State private var contacts: [VContact] = []
    @State private var selected: Set<String> = []        // selected contact userIds
    @State private var groupName = ""
    @State private var search = ""
    @State private var creating = false

    private var canCreate: Bool {
        !groupName.trimmingCharacters(in: .whitespaces).isEmpty && !selected.isEmpty && !creating
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
            .navigationTitle("New group")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundColor(VoiidColor.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await create() } } label: {
                        if creating { ProgressView() } else { Text("Create") }
                    }
                    .foregroundColor(canCreate ? VoiidColor.primary : VoiidColor.textSecondary)
                    .disabled(!canCreate)
                }
            }
            .task { await load() }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            // Group name field
            HStack(spacing: VoiidSpacing.md) {
                Circle().fill(VoiidColor.fieldFill).frame(width: 48, height: 48)
                    .overlay(Image(systemName: "person.3.fill").foregroundColor(VoiidColor.primary))
                TextField("", text: $groupName,
                          prompt: Text("Group name").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.rounded(17, .medium)).foregroundColor(VoiidColor.textPrimary)
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.vertical, VoiidSpacing.md)

            if !selected.isEmpty {
                Text("\(selected.count) selected")
                    .font(VoiidFont.rounded(12)).foregroundColor(VoiidColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VoiidSpacing.lg)
            }

            List {
                if filtered.isEmpty {
                    Text("No contacts on VOIID to add.")
                        .font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
                } else {
                    Section("Add members") {
                        ForEach(filtered) { c in
                            Button { toggle(c) } label: { row(c) }.buttonStyle(.plain)
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .searchable(text: $search, prompt: "Search contacts")
        }
    }

    private func row(_ c: VContact) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidAvatar(size: 40, imageName: nil).clipShape(Circle())
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

    private func toggle(_ c: VContact) {
        Haptics.selection()
        if selected.contains(c.userId) { selected.remove(c.userId) } else { selected.insert(c.userId) }
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
        let name = groupName.trimmingCharacters(in: .whitespaces)
        if let conv = await chat.createGroup(name: name, members: chosen) {
            dismiss()
            onCreate(conv)
        }
        creating = false
    }
}
