//
//  ForwardSheet.swift
//  Voiid
//
//  Forward a message: pick one or more chats/groups -> send (with Forwarded tag).
//

import SwiftUI

struct ForwardSheet: View {
    let message: VMessage
    var onForward: ([String]) -> Void          // conversation ids
    @EnvironmentObject var chat: ChatStore
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<String>()
    @State private var query = ""

    private var all: [VConversation] { chat.directConversations + chat.groupConversations }
    private var results: [VConversation] {
        query.isEmpty ? all : all.filter { $0.title.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // search
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
                    TextField("", text: $query, prompt: Text("Search").foregroundColor(VoiidColor.placeholder))
                        .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                }
                .padding(.horizontal, VoiidSpacing.md).frame(height: 46)
                .background(VoiidColor.fieldFill).clipShape(Capsule())
                .padding(VoiidSpacing.lg)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { c in
                            Button { toggle(c.id) } label: {
                                HStack(spacing: VoiidSpacing.md) {
                                    VoiidAvatar(size: 44, imageName: c.photoName).clipShape(Circle())
                                    Text(c.title).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                                    Spacer()
                                    Image(systemName: selected.contains(c.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 22))
                                        .foregroundColor(selected.contains(c.id) ? VoiidColor.primary : VoiidColor.textSecondary.opacity(0.5))
                                }
                                .padding(.horizontal, VoiidSpacing.lg).padding(.vertical, VoiidSpacing.sm)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .scrollDismissesKeyboard(.immediately)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Forward to").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") { Haptics.success(); onForward(Array(selected)); dismiss() }
                        .disabled(selected.isEmpty).fontWeight(.semibold)
                }
            }
        }
    }

    private func toggle(_ id: String) {
        Haptics.selection()
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }
}
