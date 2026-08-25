import SwiftUI

/// Seat-count picker only. Opponents and their decisions are created by the authoritative server.
struct LudoServerBotSetupView: View {
    let level: BotDifficulty
    let onOpen: (String) -> Void
    let onClose: () -> Void
    @State private var starting = false

    var body: some View {
        VStack(spacing: 16) {
            Text("Play Ludo").font(.title2.bold())
            Text("Choose the table size. Bots play on the server.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("You vs 1 bot") { start(fourSeats: false) }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("You + 3 bots") { start(fourSeats: true) }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            Button("Cancel", action: onClose).buttonStyle(.bordered)
            if starting { ProgressView().accessibilityLabel("Starting Ludo match") }
        }
        .padding(24)
        .disabled(starting)
        .navigationBarBackButtonHidden(starting)
    }

    private func start(fourSeats: Bool) {
        starting = true
        let difficulty: String
        switch level {
        case .easy: difficulty = "relaxed"
        case .moderate: difficulty = "balanced"
        case .hard: difficulty = "sharp"
        }
        Task {
            if let id = await GamesEngine.shared.createLudoBot(
                difficulty: difficulty, fourSeats: fourSeats) {
                onOpen(id)
            } else {
                starting = false
            }
        }
    }
}
