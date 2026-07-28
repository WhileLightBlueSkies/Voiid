//
//  StoryAudiencePickerView.swift
//  Voiid
//
//  Chooses a story's audience: ONE flat list of recipient user ids (§2.1 — no named lists,
//  no block-lists). Opens pre-selected with every contact you can reach ("My Contacts"),
//  and switches to "Custom" the moment you deselect anyone.
//
//  The privacy note is load-bearing and must not be softened (§2.3): the server can't read
//  your story, but it does learn who you sent it to, because the fan-out is addressed to
//  real device ids.
//

import SwiftUI

struct StoryAudiencePickerView: View {
    /// Selected recipient user ids. Bound so the composer keeps the choice.
    @Binding var selected: Set<String>
    @Environment(\.dismiss) private var dismiss

    /// One selectable recipient. Not `DirectoryUser`: a reachable peer may have NO directory
    /// row at all (you chat with them but never saved them), and such a person must still be
    /// offered — excluding them is exactly the bug this replaced.
    private struct Candidate: Identifiable {
        let userId: String
        let displayName: String
        let photoURL: String?
        var id: String { userId }
    }

    private var everyone: [Candidate] {
        UserDirectory.shared.storyReachableUserIds()
            .map { id in
                Candidate(userId: id,
                          displayName: UserDirectory.shared.displayName(id),
                          photoURL: UserDirectory.shared.photoURL(id))
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private var isMyContacts: Bool { selected.count == everyone.count }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(everyone) { u in
                        Button { toggle(u.userId) } label: {
                            HStack(spacing: VoiidSpacing.md) {
                                ProfileAvatarButton(photoURL: u.photoURL, name: u.displayName, size: 40)
                                Text(u.displayName).foregroundColor(VoiidColor.textPrimary)
                                Spacer()
                                Image(systemName: selected.contains(u.userId) ? "checkmark.circle.fill" : "circle")
                                    .foregroundColor(selected.contains(u.userId) ? VoiidColor.primary : VoiidColor.placeholder)
                            }
                        }
                        .listRowBackground(VoiidColor.surfaceCard)
                    }
                } footer: {
                    Text("Voiid can't read your story, but it does see who you send it to.")
                        .font(.footnote).foregroundColor(VoiidColor.textSecondary)
                }
            }
            .voiidSettingsList()
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(isMyContacts ? "My Contacts (\(selected.count))" : "Custom (\(selected.count))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isMyContacts ? "Clear" : "All") {
                        selected = isMyContacts ? [] : Set(everyone.map { $0.userId })
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold).foregroundStyle(VoiidColor.primary)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
