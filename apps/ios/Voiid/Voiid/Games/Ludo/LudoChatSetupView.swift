import SwiftUI

enum LudoChatMode { case duelHuman, duelBot, four }

/// Compact chat entry. In a chat we already KNOW who is here, so this never asks "1 vs 1 or
/// 1 vs 3" — a direct chat starts a duel with that peer, and a group offers the table sizes its
/// member count can actually seat. Candidate identities are convenience only; the API
/// re-authorizes them.
struct LudoChatSetupView: View {
    let hasHumanPeer: Bool
    /// Human members available to seat besides the viewer. A direct chat is 1.
    var availablePeers: Int = 1
    let onStart: (LudoChatMode, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var scheme
    @State private var difficulty = "balanced"

    /// Table sizes this conversation can seat: always the peer duel, plus 4-player when the
    /// group is big enough to fill it with humans or bots.
    private var offersFourPlayer: Bool { hasHumanPeer && availablePeers >= 2 }

    var body: some View {
        let colors = LudoColors.resolve(scheme)
        NavigationStack {
            Form {
                if hasHumanPeer {
                    Section {
                        Button {
                            start(.duelHuman)
                        } label: {
                            SetupRow(
                                title: "Play here",
                                subtitle: availablePeers == 1
                                    ? "You and this chat" : "You and one member",
                                colors: colors)
                        }
                        if offersFourPlayer {
                            Button {
                                start(.four)
                            } label: {
                                SetupRow(
                                    title: "4 players",
                                    subtitle: "Members join, bots fill any empty seat",
                                    colors: colors)
                            }
                        }
                    }
                }

                Section {
                    Button {
                        start(.duelBot)
                    } label: {
                        SetupRow(
                            title: "Play a bot",
                            subtitle: "One server bot, no invite sent",
                            colors: colors)
                    }
                    Picker("Bot difficulty", selection: $difficulty) {
                        Text("Relaxed").tag("relaxed")
                        Text("Balanced").tag("balanced")
                        Text("Sharp").tag("sharp")
                    }
                }
            }
            .navigationTitle("Ludo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    private func start(_ mode: LudoChatMode) {
        dismiss()
        onStart(mode, difficulty)
    }
}

private struct SetupRow: View {
    let title: String
    let subtitle: String
    let colors: LudoColors

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundStyle(colors.textPrimary)
            Text(subtitle)
                .font(VoiidFont.rounded(12))
                .foregroundStyle(colors.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
