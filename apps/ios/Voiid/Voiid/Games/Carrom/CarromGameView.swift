//
//  CarromGameView.swift
//  Voiid Ui
//
//  Full-screen Carrom game view with dual-player HUD, baseline slider,
//  aim power indicator, event banner toasts, and victory celebration overlay.
//

import SwiftUI

struct CarromGameView: View {

    @StateObject private var game: CarromGame
    @EnvironmentObject private var appSession: AppSession
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var confirmQuit = false

    init() {
        _game = StateObject(wrappedValue: CarromGame())
    }

    var body: some View {
        GeometryReader { geo in
            let availableWidth = geo.size.width
            let contentHeight = max(geo.size.height, 620)
            let boardSize = min(availableWidth - 32, min(contentHeight * 0.49, 440))

            ZStack {
                // Background
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: 8) {
                        topBar
                        scoreboardHUD
                        Spacer(minLength: 4)

                        // Center Board
                        ZStack(alignment: .top) {
                            CarromBoardView(game: game, size: boardSize)

                            // Floating Banner Toast
                            if let banner = game.banner {
                                bannerToast(banner)
                                    .transition(.move(edge: .top).combined(with: .opacity))
                            }
                        }
                        .frame(width: boardSize, height: boardSize)

                        Spacer(minLength: 4)
                        bottomControls
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(minHeight: contentHeight)
                }
                .scrollIndicators(.hidden)

                // Match End Celebration Overlay
                if case .gameOver(let winner) = game.phase {
                    gameOverOverlay(winner: winner)
                }
            }
        }
        .fontDesign(.rounded)
        .task {
            // Physics and delayed turns belong to the view lifetime, never the drawing pass.
            while !Task.isCancelled {
                if scenePhase == .active && !confirmQuit {
                    game.stepSimulationFrame(currentTime: Date.timeIntervalSinceReferenceDate)
                } else {
                    game.pauseClock()
                }
                do { try await Task.sleep(for: .milliseconds(16)) }
                catch { return }
            }
        }
        .statusBarHidden()
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            appSession.requestHideTabBar()
        }
        .onDisappear {
            game.pauseClock()
            appSession.releaseHideTabBar()
        }
        .confirmationDialog("Leave Carrom?", isPresented: $confirmQuit, titleVisibility: .visible) {
            Button("Leave Game", role: .destructive) { dismiss() }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("Your current match progress will be lost.")
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                confirmQuit = true
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VoiidColor.surfaceCard))
                    .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            }

            .accessibilityLabel("Leave Carrom")

            Spacer()

            // Mode & Queen Status Pill
            HStack(spacing: 6) {
                Text(game.mode.rawValue.uppercased())
                    .font(VoiidFont.rounded(11, .bold))
                    .foregroundColor(VoiidColor.textSecondary)

                Circle()
                    .fill(VoiidColor.divider)
                    .frame(width: 4, height: 4)

                switch game.queenState {
                case .onBoard:
                    Text("Queen: In Play")
                        .font(VoiidFont.rounded(11, .semibold))
                        .foregroundColor(Color(ludoHex: 0xC62828))
                case .pendingCover(let turn):
                    Text("\(turn == .player1 ? (game.isBot ? "You" : "Player 1") : (game.isBot ? "Bot" : "Player 2")): Cover Queen!")
                        .font(VoiidFont.rounded(11, .heavy))
                        .foregroundColor(Color(ludoHex: 0xF59E0B))
                case .covered(let turn):
                    Text("Queen: \(turn == .player1 ? (game.isBot ? "You" : "Player 1") : (game.isBot ? "Bot" : "Player 2"))")
                        .font(VoiidFont.rounded(11, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Capsule().fill(VoiidColor.surfaceCard))
            .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))

            Spacer()

            // Restart Button
            Button {
                withAnimation {
                    game.resetBoard()
                }
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(VoiidColor.surfaceCard))
                    .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            }
            .accessibilityLabel("Restart Carrom")
        }
    }

    // MARK: - Scoreboard HUD

    private var scoreboardHUD: some View {
        HStack(spacing: 12) {
            // Player 1 Card (You)
            playerCard(
                name: "You",
                colour: "White",
                disc: CarromTheme.whitePieceMain,
                score: game.player1Score,
                isActive: game.turn == .player1,
                tint: VoiidColor.accent
            )

            Text("VS")
                .font(VoiidFont.rounded(11, .bold))
                .foregroundColor(VoiidColor.textSecondary)

            // Bot colour and progress
            playerCard(
                name: "Bot",
                colour: "Black",
                disc: CarromTheme.blackPieceMain,
                score: game.player2Score,
                isActive: game.turn == .player2,
                tint: Color(ludoHex: 0xE0503F)
            )
        }
        .padding(.horizontal, 4)
    }

    private func playerCard(name: String, colour: String, disc: Color, score: Int, isActive: Bool, tint: Color) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(isActive ? VoiidColor.textPrimary : VoiidColor.textSecondary)

                HStack(spacing: 4) {
                    Circle().fill(disc)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(VoiidColor.textSecondary.opacity(0.5), lineWidth: 1))
                    Text(colour)
                        .font(VoiidFont.rounded(11, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                }

            }

            Spacer(minLength: 0)

            Text("\(score)/9")
                .font(VoiidFont.rounded(18, .heavy))
                .foregroundColor(isActive ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VoiidColor.surfaceCard)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isActive ? tint : VoiidColor.divider, lineWidth: isActive ? 1.5 : 1)
                )
        )
    }

    // MARK: - Banner Toast

    private func bannerToast(_ banner: CarromBanner) -> some View {
        HStack(spacing: 8) {
            Image(systemName: banner.type == .success ? "checkmark.circle.fill" :
                              banner.type == .foul ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .foregroundColor(banner.type == .success ? Color.green :
                                 banner.type == .foul ? Color.red : Color.yellow)

            Text(banner.text)
                .font(VoiidFont.rounded(13, .bold))
                .foregroundColor(.white)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(
            Capsule()
                .fill(Color.black.opacity(0.88))
                .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
        )
        .padding(.top, 14)
        .allowsHitTesting(false)
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        VStack(spacing: 8) {
            // Baseline Slider with Micro-Nudge buttons
            VStack(spacing: 4) {
                HStack {
                    Text("Baseline Position")
                        .font(VoiidFont.rounded(11, .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                    Spacer()
                    if !game.isPlacementValid {
                        Text("Blocked (Overlap)")
                            .font(VoiidFont.rounded(11, .bold))
                            .foregroundColor(Color.red)
                    } else {
                        Text("Aim & Strike")
                            .font(VoiidFont.rounded(11, .medium))
                            .foregroundColor(VoiidColor.accent)
                    }
                }

                HStack(spacing: 8) {
                    // Left Nudge
                    Button {
                        game.nudgeBaseline(-0.04)
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(VoiidColor.surfaceRaised))
                    }
                    .disabled(!game.canControl)
                    .accessibilityLabel("Move striker left")

                    Slider(
                        value: Binding(
                            get: { Double(game.baselineNormX) },
                            set: { game.updateBaselineSlider(CGFloat($0)) }
                        ),
                        in: 0.0...1.0
                    )
                    .tint(game.isPlacementValid ? VoiidColor.accent : Color.red)
                    .disabled(!game.canControl)

                    // Right Nudge
                    Button {
                        game.nudgeBaseline(0.04)
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(VoiidColor.surfaceRaised))
                    }
                    .disabled(!game.canControl)
                    .accessibilityLabel("Move striker right")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(VoiidColor.surfaceCard)
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(VoiidColor.divider, lineWidth: 1))
            )

            // Power Slider & STRIKE Action Bar
            if game.turn == .player1 || !game.isBot {
                HStack(spacing: 10) {
                    // Power Setting Track
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("POWER")
                                .font(VoiidFont.rounded(9.5, .bold))
                                .foregroundColor(VoiidColor.textSecondary)
                            Spacer()
                            Text("\(Int(max(game.shotPower, 0.20) * 100))%")
                                .font(VoiidFont.rounded(11, .heavy))
                                .foregroundColor(VoiidColor.textPrimary)
                                .monospacedDigit()
                        }

                        Slider(
                            value: Binding(
                                get: { Double(max(game.shotPower, 0.20)) },
                                set: { game.setShotPower(CGFloat($0)) }
                            ),
                            in: 0.20...1.0
                        )
                        .tint(LinearGradient(
                            colors: [VoiidColor.accent, Color(ludoHex: 0xF59E0B), Color(ludoHex: 0xEF4444)],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .disabled(!game.canControl)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(VoiidColor.surfaceCard)
                            .overlay(RoundedRectangle(cornerRadius: 12).stroke(VoiidColor.divider, lineWidth: 1))
                    )

                    // Big STRIKE Button
                    Button {
                        game.fireStrike()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 14, weight: .black))
                            Text("STRIKE")
                                .font(VoiidFont.rounded(14, .heavy))
                        }
                        .foregroundColor(game.isPlacementValid && game.canControl ? VoiidColor.textOnAccent : Color.gray)
                        .frame(width: 106, height: 48)
                        .background(
                            Capsule().fill(game.isPlacementValid && game.canControl ?
                                           LinearGradient(colors: [VoiidColor.accent, Color(ludoHex: 0x0EA5E9)], startPoint: .topLeading, endPoint: .bottomTrailing) :
                                           LinearGradient(colors: [VoiidColor.surfaceRaised, VoiidColor.surfaceRaised], startPoint: .top, endPoint: .bottom))
                        )
                        .shadow(color: game.isPlacementValid && game.canControl ? VoiidColor.accent.opacity(0.4) : .clear, radius: 8, y: 3)
                    }
                    .disabled(!game.isPlacementValid || !game.canControl)
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView()
                        .tint(Color(ludoHex: 0xE0503F))
                    Text(game.phase == .inMotion ? "Pieces in motion..." : "Carrom Bot is calculating angle...")
                        .font(VoiidFont.rounded(12, .medium))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 48)
                .background(RoundedRectangle(cornerRadius: 12).fill(VoiidColor.surfaceCard))
            }
        }
        .padding(.horizontal, 6)
    }

    // MARK: - Game Over Celebration

    private func gameOverOverlay(winner: String) -> some View {
        ZStack {
            Color.black.opacity(0.72).ignoresSafeArea()

            VStack(spacing: 14) {
                Image(systemName: "trophy.fill")
                    .font(.system(size: 48))
                    .foregroundColor(Color(ludoHex: 0xF59E0B))

                Text(winner == "Draw" ? "It’s a Draw!" : winner == "You" ? "You Win!" : "\(winner) Wins!")
                    .font(VoiidFont.rounded(26, .bold))
                    .foregroundColor(VoiidColor.textPrimary)

                Text("Pocketed: \(game.player1Score) white · \(game.player2Score) black")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)

                HStack(spacing: 12) {
                    Button {
                        game.resetBoard()
                    } label: {
                        Text("Play Again")
                            .font(VoiidFont.rounded(15, .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Capsule().fill(VoiidColor.accent))
                    }

                    Button {
                        dismiss()
                    } label: {
                        Text("Exit")
                            .font(VoiidFont.rounded(15, .bold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .frame(maxWidth: .infinity)
                            .frame(height: 46)
                            .background(Capsule().fill(VoiidColor.surfaceRaised))
                    }
                }
                .padding(.top, 8)
            }
            .padding(26)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(VoiidColor.surfaceCard)
                    .overlay(RoundedRectangle(cornerRadius: 24).stroke(VoiidColor.divider, lineWidth: 1))
            )
            .padding(.horizontal, 28)
        }
        .transition(.opacity)
    }
}
