import SwiftUI

enum LudoChatMode { case duelHuman, duelBot, four }

/// Compact chat entry. Candidate identities are convenience only; the API re-authorizes them.
struct LudoChatSetupView: View {
    let hasHumanPeer: Bool
    let onStart: (LudoChatMode, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var difficulty = "balanced"

    var body: some View {
        NavigationStack {
            Form {
                Picker("Bot difficulty", selection: $difficulty) {
                    Text("Relaxed").tag("relaxed")
                    Text("Balanced").tag("balanced")
                    Text("Sharp").tag("sharp")
                }
                Section("Mode") {
                    if hasHumanPeer { Button("1 vs 1") { start(.duelHuman) } }
                    Button("1 vs bot") { start(.duelBot) }
                    Button("4 players · fill with bots") { start(.four) }
                }
            }
            .navigationTitle("Ludo")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func start(_ mode: LudoChatMode) {
        dismiss()
        onStart(mode, difficulty)
    }
}
