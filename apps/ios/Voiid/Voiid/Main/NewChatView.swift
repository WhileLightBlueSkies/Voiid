//
//  NewChatView.swift
//  Voiid
//
//  "New chat" picker. Discovers which of the user's contacts are on VOIID
//  (privacy-preserving, hashed on-device via ContactsService), lists them to
//  start an E2EE 1:1 chat, and offers a share-sheet invite for the rest.
//

import SwiftUI
import UIKit

struct NewChatView: View {
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    /// Called with the conversation to open after starting a chat.
    var onOpen: (VConversation) -> Void

    @State private var loading = true
    @State private var error: String?
    @State private var matches: [VContact] = []
    @State private var invites: [InviteContact] = []
    @State private var search = ""
    @State private var inviteItem: InviteShare?
    @State private var starting = false

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    VStack(spacing: VoiidSpacing.md) {
                        ProgressView()
                        Text("Finding your contacts on VOIID…")
                            .font(VoiidFont.rounded(13)).foregroundColor(VoiidColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    errorState(error)
                } else {
                    list
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("New chat")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundColor(VoiidColor.primary)
                }
            }
            .task { await load() }
            .sheet(item: $inviteItem) { item in
                ShareSheet(items: [item.text])
            }
        }
    }

    private var filteredMatches: [VContact] {
        guard !search.isEmpty else { return matches }
        return matches.filter { $0.displayName.localizedCaseInsensitiveContains(search) }
    }
    private var filteredInvites: [InviteContact] {
        guard !search.isEmpty else { return invites }
        return invites.filter { $0.name.localizedCaseInsensitiveContains(search) || $0.number.contains(search) }
    }

    private var list: some View {
        List {
            if !filteredMatches.isEmpty {
                Section("On VOIID") {
                    ForEach(filteredMatches) { c in
                        Button { Task { await start(c) } } label: { contactRow(name: c.displayName, subtitle: "Tap to chat", onVoiid: true) }
                            .disabled(starting)
                    }
                }
            }
            if !filteredInvites.isEmpty {
                Section("Invite to VOIID") {
                    ForEach(filteredInvites) { c in
                        Button { inviteItem = InviteShare(text: inviteText(for: c)) } label: {
                            contactRow(name: c.name, subtitle: c.number, onVoiid: false)
                        }
                    }
                }
            }
            if filteredMatches.isEmpty && filteredInvites.isEmpty {
                Text("No contacts found.")
                    .font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .searchable(text: $search, prompt: "Search contacts")
    }

    private func contactRow(name: String, subtitle: String, onVoiid: Bool) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidAvatar(size: 40, imageName: nil).clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(VoiidFont.rounded(16, .medium)).foregroundColor(VoiidColor.textPrimary)
                Text(subtitle).font(VoiidFont.rounded(12)).foregroundColor(VoiidColor.textSecondary)
            }
            Spacer()
            if !onVoiid {
                Text("Invite").font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.primary)
            }
        }
        .contentShape(Rectangle())
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 40)).foregroundColor(VoiidColor.textSecondary)
            Text(message).font(VoiidFont.rounded(14)).foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, VoiidSpacing.xl)
            Button("Try again") { Task { await load() } }
                .foregroundColor(VoiidColor.primary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true; error = nil
        do {
            let result = try await ContactsService.shared.discover()
            matches = result.matches
            invites = result.invites
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t access contacts. Enable Contacts access in Settings."
        }
        loading = false
    }

    private func start(_ c: VContact) async {
        guard !starting else { return }
        starting = true
        if let conv = await chat.startDirectChat(with: c) {
            dismiss()
            onOpen(conv)
        }
        starting = false
    }

    private func inviteText(for c: InviteContact) -> String {
        "Hey \(c.name), let's chat privately on VOIID — end-to-end encrypted messaging. https://voiid.app"
    }
}

// Identifiable wrapper so the share sheet can be presented via .sheet(item:).
private struct InviteShare: Identifiable { let id = UUID(); let text: String }

// UIActivityViewController bridge for the invite share-sheet.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
