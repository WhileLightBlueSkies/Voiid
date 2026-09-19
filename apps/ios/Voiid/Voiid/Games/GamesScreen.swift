//
//  GamesScreen.swift
//  Voiid
//
//  The streamlined arcade hub: single screen, instant play, honest playable library.
//

import SwiftUI

struct GamesScreen: View {

    @State private var store = GamesStore()
    @EnvironmentObject private var session: AppSession

    private enum Step: Hashable {
        case ludo(difficulty: String)
        case snake(mode: String)
        case carrom
    }

    @State private var path: [Step] = []
    @State private var setup: Game?
    @State private var showSettings = false
    /// The Social Profile handle being opened from the header avatar.
    @State private var openHandle: String?
    @State private var selectedUpcoming: Game?

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiidSpacing.xl) {
                        continueRow
                        library
                        comingSoon
                    }
                    .padding(.top, VoiidSpacing.sm)
                }
                .scrollIndicators(.hidden)
                .softScrollEdge()
                .contentMargins(.bottom, max(session.bottomInset, 96), for: .scrollContent)
            }
            // A REAL nav bar, as Communities has — not a hand-drawn header row.
            //
            // This tab used to hide the bar and draw its own title and buttons. That is why
            // the gear and the avatar sat bare here while the same controls in Communities
            // sat in the system's glass pill: the pill is something the toolbar gives its
            // items, so a hand-drawn row can never get it, and no amount of restyling the
            // row would have closed the gap.
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Games")
                        .font(VoiidFont.screenTitle)
                        .foregroundStyle(VoiidColor.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button { Haptics.tap(); showSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Game settings")
                }
                // The same identity, in the same corner, as Clips and Communities.
                ToolbarItem(placement: .primaryAction) {
                    SocialProfileButton(diameter: 30) { openHandle = $0 }
                }
            }
            .sheet(item: $setup) { game in
                GameSetupSheet(game: game) { mode in
                    start(game, mode: mode)
                }
            }
            .sheet(isPresented: $showSettings) {
                GameSettingsSheet(onClose: { showSettings = false })
            }
            .sheet(item: $selectedUpcoming) { game in
                UpcomingGameSheet(game: game, onClose: { selectedUpcoming = nil })
            }
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .ludo(let difficulty): LudoGameView(difficulty: difficulty)
                case .snake(let mode):       SnakeGameView(mode: mode)
                case .carrom:                CarromGameView()
                }
            }
            .navigationDestination(item: $openHandle) { handle in
                SocialProfileView(handle: handle)
            }
        }
    }

    private func open(_ game: Game) {
        guard game.isPlayable else { return }
        Haptics.tap()
        setup = game
    }

    private func start(_ game: Game, mode: GameMode) {
        switch game.id {
        case "ludo":  path.append(.ludo(difficulty: mode.id))
        case "snake": path.append(.snake(mode: mode.id))
        case "carrom": path.append(.carrom)
        default:      break
        }
    }

    // MARK: Continue

    /// The "continue last played" row. The title and the header actions moved to the real
    /// toolbar above, so what is left here is content, not chrome.
    private var continueRow: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            if let last = store.lastPlayed {
                Button {
                    open(last)
                } label: {
                    HStack(spacing: VoiidSpacing.sm + 2) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(VoiidColor.accent))

                        VStack(alignment: .leading, spacing: 0) {
                            Text("Continue \(last.title)")
                                .font(VoiidFont.rounded(14.5, .semibold))
                                .foregroundColor(VoiidColor.textPrimary)
                            Text(last.lastPlayed ?? "")
                                .font(VoiidFont.rounded(11.5))
                                .foregroundColor(VoiidColor.textSecondary)
                        }

                        Spacer(minLength: 0)

                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .padding(VoiidSpacing.sm + 2)
                    .background(VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                              style: .continuous)
                        .stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: Library

    private var library: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            sectionTitle("Play")

            VStack(spacing: VoiidSpacing.sm + 2) {
                ForEach(store.playable) { game in
                    GameCard(game: game) { open(game) }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Coming soon

    private var comingSoon: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            sectionTitle("Coming soon")

            VStack(spacing: 8) {
                ForEach(store.upcoming) { game in
                    Button {
                        Haptics.tap()
                        selectedUpcoming = game
                    } label: {
                        HStack(spacing: VoiidSpacing.sm + 2) {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(LinearGradient(colors: [game.tintA.opacity(0.35),
                                                              game.tintB.opacity(0.2)],
                                                     startPoint: .topLeading,
                                                     endPoint: .bottomTrailing))
                                .frame(width: 42, height: 42)
                                .overlay {
                                    Image(systemName: game.symbol)
                                        .font(.system(size: 16))
                                        .foregroundColor(.white.opacity(0.75))
                                }

                            VStack(alignment: .leading, spacing: 1) {
                                Text(game.title)
                                    .font(VoiidFont.rounded(14.5, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Text(game.pitch)
                                    .font(VoiidFont.rounded(12))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 0)

                            Text("Soon")
                                .font(VoiidFont.rounded(11, .semibold))
                                .foregroundColor(VoiidColor.textSecondary)
                                .padding(.horizontal, 9)
                                .frame(height: 26)
                                .background(Capsule().fill(VoiidColor.surfaceRaised))
                        }
                        .padding(VoiidSpacing.sm + 2)
                        .background(VoiidColor.surfaceCard.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                    style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                  style: .continuous)
                            .stroke(VoiidColor.divider.opacity(0.6), lineWidth: 1))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Shared

    private func sectionTitle(_ text: String, count: Int? = nil) -> some View {
        HStack(spacing: 7) {
            Text(text)
                .font(VoiidFont.rounded(18, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            if let count {
                Text("\(count)")
                    .font(VoiidFont.rounded(11, .bold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(minWidth: 20, minHeight: 20)
                    .background(Circle().fill(VoiidColor.accent))
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
    }
}

// MARK: - Game Card

private struct GameCard: View {
    let game: Game
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                footer
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title). \(game.pitch)")
    }

    private var artwork: some View {
        ZStack(alignment: .bottomLeading) {
            GameArtwork(game: game, isSetup: false)

            VStack(alignment: .leading, spacing: 5) {
                Text(game.title)
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundColor(.white)
                    .shadow(color: .black.opacity(0.35), radius: 6, y: 2)

                Text(game.pitch)
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(.white.opacity(0.9))
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                    .shadow(color: .black.opacity(0.3), radius: 4, y: 1)
            }
            .padding(VoiidSpacing.md)
            .padding(.trailing, VoiidSpacing.lg)
        }
        .frame(height: 148)
        .clipped()
    }

    private var footer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            if let players = game.players {
                metaChip("person.2.fill", players)
            }
            if let minutes = game.minutes {
                metaChip("clock", minutes)
            }
            if let best = game.bestScore {
                metaChip("trophy.fill", best)
            }

            Spacer(minLength: 0)

            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(width: 34, height: 34)
                .background(Circle().fill(VoiidColor.accent))
        }
        .padding(.horizontal, VoiidSpacing.md - 2)
        .padding(.vertical, VoiidSpacing.sm + 2)
    }

    private func metaChip(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(VoiidFont.rounded(11.5, .medium))
        }
        .foregroundColor(VoiidColor.textSecondary)
    }
}

// MARK: - Upcoming Game Sheet

struct UpcomingGameSheet: View {
    let game: Game
    var onClose: () -> Void
    @State private var notified = false

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: 20) {
                    Spacer()

                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [game.tintA, game.tintB], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 96, height: 96)
                        .overlay {
                            Image(systemName: game.symbol)
                                .font(.system(size: 44))
                                .foregroundColor(.white)
                        }
                        .shadow(color: game.tintA.opacity(0.4), radius: 18)

                    VStack(spacing: 6) {
                        Text(game.title)
                            .font(VoiidFont.rounded(26, .bold))
                            .foregroundColor(VoiidColor.textPrimary)

                        Text("Coming in Season 2")
                            .font(VoiidFont.rounded(13, .bold))
                            .tracking(1)
                            .foregroundColor(VoiidColor.accent)
                    }

                    Text("Custom matchmaking, real-time board physics, and ranked seasons for \(game.title) are in final polish. Be the first to play when it goes live.")
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 28)

                    Spacer()

                    Button {
                        Haptics.tap()
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
                            notified.toggle()
                        }
                        if notified {
                            UINotificationFeedbackGenerator().notificationOccurred(.success)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: notified ? "bell.badge.fill" : "bell.fill")
                            Text(notified ? "Notification Set!" : "Notify Me at Launch")
                                .font(VoiidFont.rounded(15, .semibold))
                        }
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Capsule().fill(notified ? Color(ludoHex: 0x2FA36B) : VoiidColor.primary))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .padding(.horizontal, 24)
                    .padding(.bottom, 16)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { onClose() }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
