//
//  OpponentPickerSheet.swift
//  Voiid
//
//  Choose who to play against (docs/GAMES.md §3).
//
//  Sourced from EXISTING DIRECT CONVERSATIONS, deliberately — the whole invite model is
//  "play someone you already talk to". Groups are excluded because Tic Tac Toe is a
//  two-player game and the roster is fixed at match creation; a group picker would imply
//  a lobby this system does not have.
//
//  Mirrors Android `OpponentPickerSheet.kt`.
//

import SwiftUI

struct OpponentPickerSheet: View {
    let conversations: [VConversation]
    let onPick: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    /// Only direct chats whose peer user id we actually know — without it there is nobody
    /// to name as the opponent.
    private var candidates: [VConversation] {
        conversations.filter { $0.type == .direct && !($0.peerUserId ?? "").isEmpty }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    Text("Start a chat with someone first — games are played with people you already talk to.")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(VoiidSpacing.lg)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(candidates, id: \.id) { convo in
                                Button {
                                    if let peer = convo.peerUserId { onPick(peer) }
                                    dismiss()
                                } label: {
                                    HStack(spacing: VoiidSpacing.md) {
                                        ZStack {
                                            Circle()
                                                .fill(VoiidColor.primary.opacity(0.12))
                                                .frame(width: 40, height: 40)
                                            Text(convo.title.prefix(1).uppercased())
                                                .font(VoiidFont.rounded(16, .semibold))
                                                .foregroundStyle(VoiidColor.primary)
                                        }
                                        Text(convo.title)
                                            .font(VoiidFont.rounded(16, .regular))
                                            .foregroundStyle(VoiidColor.textPrimary)
                                        Spacer()
                                    }
                                    .padding(.vertical, VoiidSpacing.sm)
                                    .padding(.horizontal, VoiidSpacing.md)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.top, VoiidSpacing.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Play against")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
    }
}
