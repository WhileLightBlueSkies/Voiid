//
//  LudoGameView.swift
//  Voiid
//
//  The luxury Ludo screen: dark backdrop, wood & brass board, 3D tumbling die with direct-tap.
//

import SwiftUI

struct LudoGameView: View {
    @StateObject private var game = LudoGame()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    var difficulty: String = "easy"

    @State private var showSetup = false
    @State private var confirmQuit = false
    @State private var confirmRestart = false
    @State private var started = false
    @State private var showSettings = false

    var body: some View {
        ZStack {
            Theme.backdrop

            // The board is the screen. Everything else is sized around what it leaves, rather
            // than the board taking what four other rows leave it — which on a small phone
            // was a board squeezed under a permanent three-line instruction paragraph.
            VStack(spacing: 12) {
                header
                SeatRail(game: game).padding(.horizontal, 8)
                board
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 8)
                controls.padding(.horizontal, 8)
            }
            // The 44pt buttons already carry their own inset, so the header sits flush and
            // only the board and controls take the side margin.
            .padding(.horizontal, 6)
            .padding(.top, 4)
            .padding(.bottom, 10)
            .frame(maxWidth: 620)

            if showSetup { setup }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .onAppear {
            session.requestHideTabBar()
            if game.winner == nil, !started {
                game.start(humans: 1, difficulty: difficulty)
                started = true
            }
        }
        .onDisappear {
            game.stop()
            session.releaseHideTabBar()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background || phase == .inactive {
                game.stop()
            }
        }
        .onChange(of: reduceMotion, initial: true) { _, value in
            game.reduceMotion = value
        }
        .onChange(of: game.winner) { _, new in
            if new != nil {
                Task {
                    try? await Task.sleep(for: .milliseconds(1500))
                    showSetup = true
                }
            }
        }
        .confirmationDialog("Leave the game?", isPresented: $confirmQuit,
                            titleVisibility: .visible) {
            Button("Leave game", role: .destructive) {
                game.stop()
                dismiss()
            }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("Your progress won't be saved.")
        }
        .confirmationDialog("Restart match?", isPresented: $confirmRestart,
                            titleVisibility: .visible) {
            Button("Restart match", role: .destructive) {
                game.restart()
            }
            Button("Keep playing", role: .cancel) {}
        } message: {
            Text("This will reset the board and start a new match.")
        }
        .sheet(isPresented: $showSettings) {
            GameSettingsSheet(onClose: { showSettings = false }, showsSnakeControls: false)
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            Button {
                if showSetup { dismiss() } else { confirmQuit = true }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Theme.cream)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Quit match")

            Spacer()

            HStack(spacing: 2) {
                Button {
                    confirmRestart = true
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Theme.cream)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Restart match")

                Button {
                    showSettings = true
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .accessibilityLabel("Game settings")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Board

    private var board: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let unit = side / 15

            ZStack(alignment: .topLeading) {
                BoardCanvas(unit: unit)
                    .frame(width: side, height: side)

                // Landing markers for the current roll
                ForEach(game.pendingMoves, id: \.token) { move in
                    let c = LudoEngine.centre(seat: game.state.turn,
                                              token: move.token, rel: move.to)
                    MoveHint(seat: game.state.turn, unit: unit)
                        .position(x: c.x * unit, y: c.y * unit)
                }

                // Tokens
                ForEach(0..<4, id: \.self) { seat in
                    ForEach(0..<4, id: \.self) { token in
                        tokenView(seat: seat, token: token, unit: unit)
                    }
                }

                if let banner = game.banner {
                    Text(banner)
                        .font(Theme.display(min(38, side * 0.09)))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.8), radius: 18)
                        .frame(width: side, height: side)
                        .transition(.scale(scale: 0.7).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: side, height: side)
            .frame(maxWidth: .infinity)
            .animation(.easeOut(duration: 0.25), value: game.banner)
        }
        .aspectRatio(1, contentMode: .fit)
    }

    private func tokenView(seat: Int, token: Int, unit: CGFloat) -> some View {
        let rel = game.state.positions[seat][token]
        let centre = LudoEngine.centre(seat: seat, token: token, rel: rel)
        let stack = LudoEngine.stack(game.state, seat: seat, token: token)

        let size: CGFloat = {
            if rel == LudoPos.yard { return 0.70 }
            return stack.count > 1 ? 0.62 : 0.74
        }() * unit

        let nudge = stack.count > 1 ? (CGFloat(stack.index) * 0.13 - 0.06) * unit : 0

        return TokenView(
            seat: seat,
            diameter: size,
            isLive: game.isLive(seat: seat, token: token),
            isHopping: game.hopping == LudoGame.TokenRef(seat: seat, token: token),
            isPopping: game.popping == LudoGame.TokenRef(seat: seat, token: token)
        )
        .position(x: centre.x * unit + nudge, y: centre.y * unit - nudge * 0.5)
        .zIndex(game.isLive(seat: seat, token: token) ? 7 : 5)
        .onTapGesture { game.tap(seat: seat, token: token) }
    }

    // MARK: Controls

    private var controls: some View {
        HStack(spacing: 14) {
            // Two fixed lines: the message changes on every roll, and a row that grows and
            // shrinks with its length shifts the die and ROLL button under the player's thumb
            // mid-match.
            Text(game.message)
                .font(Theme.ui(13))
                .foregroundStyle(Theme.muted)
                .lineLimit(2, reservesSpace: true)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Direct tap supported on 3D die!
            DiceBox(roller: game.dice, side: 76, onTap: game.canRoll ? { game.roll() } : nil)
                .frame(width: 76, height: 76)

            Button {
                game.roll()
            } label: {
                Text("ROLL")
                    .font(Theme.label(12))
                    .tracking(1.8)
                    .foregroundStyle(Color(ludoHex: 0x0E1620))
                    .padding(.horizontal, 20)
                    .padding(.vertical, 13)
                    .background {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(LinearGradient(colors: [Color(ludoHex: 0xF0DFA8), Theme.brass],
                                                 startPoint: .top, endPoint: .bottom))
                            .shadow(color: Theme.brassLo, radius: 0, y: 4)
                    }
            }
            .buttonStyle(PressDown())
            .disabled(!game.canRoll)
            .opacity(game.canRoll ? 1 : 0.32)
        }
    }

    /// Shown on the setup sheet, where a player is deciding and has time to read — not
    /// pinned under the board for the whole match, where it only costs the board height.
    private var rules: some View {
        Text("Tap the die, then tap a glowing token. Outlined squares show where it will land. Sixes and captures earn another roll — three sixes forfeit the turn.")
            .font(Theme.ui(11, .regular))
            .foregroundStyle(Theme.faint)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Setup sheet

    private var setup: some View {
        ZStack {
            VoiidColor.background.opacity(0.96).ignoresSafeArea()

            VStack(spacing: 6) {
                HStack {
                    Spacer()
                    Button {
                        game.stop()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(Theme.muted)
                    }
                    .accessibilityLabel("Close")
                }
                .padding(.bottom, -6)

                Text(game.winner.map { "\(LudoEngine.seats[$0].name) wins!" } ?? "Ludo")
                    .font(Theme.display(26))
                    .foregroundStyle(Theme.cream)

                Text(game.winner == nil
                     ? "Four tokens, fifty-two squares, one die. Get all four home first."
                     : "All four tokens home. Play again?")
                    .font(Theme.ui(13, .regular))
                    .foregroundStyle(Theme.muted)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 14)

                ForEach([("easy", "Easy (vs Bots)", "Relaxed bots, gentle practice"),
                         ("moderate", "Moderate (vs Bots)", "Standard balanced match against 3 bots"),
                         ("hard", "Hard (vs Bots)", "Aggressive bots that cut and race")], id: \.0) { item in
                    Button {
                        game.start(humans: 1, difficulty: item.0)
                        showSetup = false
                    } label: {
                        VStack(spacing: 2) {
                            Text(item.1).font(Theme.ui(13, .semibold))
                                .foregroundStyle(Theme.cream)
                            Text(item.2).font(Theme.ui(11, .regular))
                                .foregroundStyle(Theme.faint)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background {
                            RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .fill(item.0 == difficulty ? Theme.ink : Theme.ink3)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                                        .strokeBorder(item.0 == difficulty ? Theme.brass : Theme.hairline, lineWidth: 1)
                                }
                        }
                    }
                    .buttonStyle(PressDown())
                }

                Button {
                    game.stop()
                    dismiss()
                } label: {
                    Text("Quit to Menu")
                        .font(Theme.ui(12, .medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.vertical, 8)
                }
                .padding(.top, 4)

                rules.padding(.top, 10)
            }
            .padding(24)
            .frame(maxWidth: 340)
            .background {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Theme.ink2)
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
            }
            .padding(24)
        }
        .transition(.opacity)
    }
}

// MARK: - Seat rail

struct SeatRail: View {
    @ObservedObject var game: LudoGame

    var body: some View {
        HStack(spacing: 8) {
            ForEach(0..<4, id: \.self) { seat in
                let active = game.state.turn == seat && game.winner == nil
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Theme.seat(seat))
                            .frame(width: 11, height: 11)
                            .shadow(color: active ? Theme.seat(seat) : .clear, radius: 7)
                        Text(LudoEngine.seats[seat].name + (game.isBot(seat) ? " · bot" : ""))
                            .font(Theme.ui(11))
                            .foregroundStyle(Theme.cream)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    HStack(spacing: 3) {
                        ForEach(0..<4, id: \.self) { pip in
                            Capsule()
                                .fill(pip < game.state.homeCount(seat)
                                      ? Theme.seat(seat) : VoiidColor.surfaceRaised)
                                .frame(height: 4)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(active ? Theme.ink3 : Theme.ink2)
                        .overlay {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(active ? Theme.seat(seat) : Theme.hairline,
                                              lineWidth: 1)
                        }
                }
                .offset(y: active ? -2 : 0)
                .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
            }
        }
    }
}

// MARK: - Button style

struct PressDown: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .offset(y: configuration.isPressed ? 3 : 0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
