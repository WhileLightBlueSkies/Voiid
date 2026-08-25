import SwiftUI

/// Player-count picker. You pick how many players sit at the table; every seat that isn't
/// yours is filled by a server-side bot. Opponents and their decisions are created by the
/// authoritative server — the client never simulates a bot.
struct LudoServerBotSetupView: View {
    let level: BotDifficulty
    let onOpen: (String) -> Void
    let onClose: () -> Void

    @Environment(\.colorScheme) private var scheme
    @State private var players = 4
    @State private var starting = false

    /// Ludo seats 2, 3 or 4. One seat is the viewer; the rest are bots.
    private let options = [2, 3, 4]

    var body: some View {
        let colors = LudoColors.resolve(scheme)
        VStack(spacing: 20) {
            VStack(spacing: 6) {
                Text("Play Ludo")
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundStyle(colors.textPrimary)
                Text("Pick how many players. Bots fill the rest and play on the server.")
                    .font(VoiidFont.rounded(13))
                    .foregroundStyle(colors.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: 10) {
                ForEach(options, id: \.self) { count in
                    PlayerCountChip(
                        count: count,
                        selected: players == count,
                        colors: colors,
                        action: { players = count })
                }
            }

            // Says the composition plainly so "3 players" is never ambiguous.
            Text(compositionLine)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundStyle(colors.textSecondary)
                .accessibilityLabel(compositionLine)

            Button { start() } label: {
                Text(starting ? "Starting…" : "Start game")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(starting)

            Button("Cancel", action: onClose)
                .buttonStyle(.bordered)
                .disabled(starting)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(colors.screenBackground.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
    }

    private var compositionLine: String {
        let bots = players - 1
        return "You + \(bots) bot\(bots == 1 ? "" : "s")"
    }

    private func start() {
        guard !starting else { return }
        starting = true
        let difficulty: String
        switch level {
        case .easy: difficulty = "relaxed"
        case .moderate: difficulty = "balanced"
        case .hard: difficulty = "sharp"
        }
        Task {
            if let id = await GamesEngine.shared.createLudoBot(
                difficulty: difficulty, players: players) {
                onOpen(id)
            } else {
                starting = false
            }
        }
    }
}

/// One seat-count option. Selection is a filled chip; the count is the affordance, so no
/// separate label row is needed.
private struct PlayerCountChip: View {
    let count: Int
    let selected: Bool
    let colors: LudoColors
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 2) {
                Text("\(count)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("players")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .frame(width: 84, height: 68)
            .foregroundStyle(selected ? Color.white : colors.textPrimary)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(selected ? colors.timerActive : colors.podSurface))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) players")
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
