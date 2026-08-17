//
//  LudoBotView.swift
//  Voiid
//
//  Practice against local bots. No server, no match row, no connection needed.
//
//  IT DRAWS THROUGH THE SAME BOARD AS THE ONLINE MATCH. `LudoBotMatch` builds a `LudoState`
//  shaped exactly like a server frame, so `LudoBoardView` renders both — a player cannot tell a
//  practice board from a real one, and a fix to one is a fix to both.
//
//  Difficulty arrives already chosen and is LOCKED for the match. It is labelled by PLAYSTYLE
//  rather than strength (§11.2): Ludo's skill ceiling is worth about ten percentage points of
//  win rate, so "Hard" would promise something the game cannot deliver.
//
//  Mirrors Android `LudoBotScreen.kt`.
//

import SwiftUI

struct LudoBotView: View {
    let level: BotDifficulty
    let skill: Double
    var onClose: (() -> Void)?

    @StateObject private var match = LudoBotMatch()
    @StateObject private var hop = LudoHop()
    @EnvironmentObject var session: AppSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lastDie = 0

    private var s: LudoState { match.state }

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            strips
            LudoBoardView(
                state: s,
                mySeat: LudoBotMatch.humanSeat,
                legal: match.canMove ? s.legal : [],
                onTapToken: { match.move(token: $0) },
                hopOverrides: hop.overrides,
                reduceMotion: reduceMotion)
                .onTapGesture { hop.skip() }
                .padding(.horizontal, VoiidSpacing.sm)
            status
            // The end screen is an OVERLAY over the board (§9.2).
            if !s.finished { dieButton }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .overlay {
            if s.finished {
                MatchEndOverlay(
                    result: botResult(),
                    onPlayAgain: { match.restart() },
                    onExit: { onClose?() })
                .transition(.opacity)
            }
        }
        .navigationTitle("Ludo")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { onClose?() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
            ToolbarItem(placement: .topBarTrailing) {
                // PLAYSTYLE, NOT STRENGTH — see LudoBot's header.
                Text(LudoBot.styleLabel(skill))
                    .font(VoiidFont.rounded(13, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .onAppear {
            session.hideTabBar = true
            match.configure(level: level, skill: skill)
            GameAudio.shared.preload(for: "ludo")
        }
        .onDisappear {
            session.hideTabBar = false
            GameAudio.shared.release(for: "ludo")
            hop.skip()
        }
        .onChange(of: match.state.die) { _, face in
            guard let face else { return }
            lastDie = face
            LudoSound.dieSettled()
        }
        .onChange(of: match.state.lastMove?.to) { _, _ in
            guard let move = match.state.lastMove else { return }
            hop.play(
                seat: move.seat, token: move.token, from: move.from, to: move.to,
                die: lastDie, reduceMotion: reduceMotion,
                onStep: { LudoSound.hopped() },
                onFinish: { LudoSound.moved(move, mySeat: LudoBotMatch.humanSeat) })
        }
        .onChange(of: match.state.finished) { _, finished in
            guard finished else { return }
            LudoSound.matchEnded(match.state, me: "you")
        }
    }

    private var strips: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ForEach(Array(s.players.enumerated()), id: \.offset) { seat, _ in
                let active = !s.finished && seat == s.turn
                let home = s.tokens.indices.contains(seat)
                    ? s.tokens[seat].filter { $0 == Ludo.home }.count : 0
                VStack(spacing: 2) {
                    HStack(spacing: 3) {
                        Image(systemName: Ludo.seatMarkers[seat % Ludo.maxSeats])
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Ludo.seatColors[seat % Ludo.maxSeats])
                        Text(seat == LudoBotMatch.humanSeat ? "You"
                                                            : Ludo.seatNames[seat % Ludo.maxSeats])
                            .font(VoiidFont.rounded(11, active ? .semibold : .regular))
                            .lineLimit(1)
                            .foregroundStyle(active ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                    }
                    Text("\(home)/\(s.tokensPerPlayer)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(VoiidColor.textSecondary.opacity(0.8))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(active ? Ludo.seatColors[seat % Ludo.maxSeats].opacity(0.18)
                                     : Color.clear))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(active ? Ludo.seatColors[seat % Ludo.maxSeats] : Color.clear,
                                lineWidth: 1.5))
                .animation(.easeInOut(duration: 0.28), value: active)
            }
        }
        .padding(.top, VoiidSpacing.xs)
    }

    @ViewBuilder
    private var status: some View {
        let text: String = {
            if s.finished {
                guard let winner = s.winnerUserId else { return "Match abandoned" }
                return winner == "you" ? "You win"
                    : "\(Ludo.seatNames[s.turn % Ludo.maxSeats]) wins"
            }
            if match.botThinking { return "\(Ludo.seatNames[s.turn % Ludo.maxSeats]) is thinking…" }
            if match.canMove { return "Pick a token" }
            if match.canRoll { return "Your turn — roll" }
            return "\(Ludo.seatNames[s.turn % Ludo.maxSeats])'s turn"
        }()

        VStack(spacing: 2) {
            Text(text)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .accessibilityAddTraits(.updatesFrequently)

            // A capture is the emotional event of Ludo, and in a 4-player game you are mostly
            // watching — a capture that is not narrated is a token that vanished.
            if let move = s.lastMove, let captured = move.captured, captured.count == 2 {
                let victim = captured[0]
                let onMe = victim == LudoBotMatch.humanSeat
                let byMe = move.seat == LudoBotMatch.humanSeat
                Text(onMe ? "Your token was sent home"
                          : byMe ? "You sent a token home"
                                 : "\(Ludo.seatNames[victim % Ludo.maxSeats]) was sent home")
                    .font(VoiidFont.rounded(11, .medium))
                    .foregroundStyle(onMe ? VoiidColor.error : VoiidColor.textSecondary)
            }
        }
    }

    @ViewBuilder
    private var dieButton: some View {
        VStack(spacing: VoiidSpacing.xs) {
            Button {
                match.roll()
                LudoSound.dieRolled()
            } label: {
                ZStack {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(match.canRoll ? VoiidColor.primary.opacity(0.16) : VoiidColor.surfaceCard)
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(match.canRoll ? VoiidColor.primary
                                                      : VoiidColor.textSecondary.opacity(0.25),
                                        lineWidth: 1.5))
                    LudoDiePips(face: s.die ?? 1)
                        .padding(12)
                        .foregroundStyle(match.canRoll || s.die != nil
                                         ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                }
                .frame(width: 64, height: 64)
            }
            .disabled(!match.canRoll)
            .accessibilityLabel(s.die.map { "Die showing \($0)" } ?? "Roll the die")

            if s.sixStreak > 0 && !s.finished {
                Text(s.sixStreak >= 2 ? "Two sixes — a third loses the turn" : "Six — roll again")
                    .font(VoiidFont.rounded(10, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }

    /// Built from local match state. Placement matters more here than a win flag: in a
    /// 4-player game "2nd of 4" is the honest result and "you lose" is not.
    private func botResult() -> MatchEndResult {
        guard s.winnerUserId != nil else { return .abandoned() }
        let seat = LudoBotMatch.humanSeat
        let home = s.tokens[seat].filter { $0 == Ludo.home }.count
        let placement = (s.finishedOrder.firstIndex(of: seat).map { $0 + 1 })
            ?? (s.finishedOrder.count + 1)
        let cap = s.lastMove?.captured
        return .ludo(
            placement: placement,
            seats: s.players.count,
            home: home,
            tokens: s.tokensPerPlayer,
            captures: (cap?.count == 2 && s.lastMove?.seat == seat) ? 1 : 0,
            lost: (cap?.count == 2 && cap?[0] == seat) ? 1 : 0,
            won: s.winnerUserId == "you")
    }
}

/// A die face as pips. Shared with the online screen's private copy by shape, not by code —
/// see LudoView. Kept here so the bot screen has no dependency on the online one.
struct LudoDiePips: View {
    let face: Int

    private static let layouts: [Int: [(Int, Int)]] = [
        1: [(1, 1)],
        2: [(0, 0), (2, 2)],
        3: [(0, 0), (1, 1), (2, 2)],
        4: [(0, 0), (2, 0), (0, 2), (2, 2)],
        5: [(0, 0), (2, 0), (1, 1), (0, 2), (2, 2)],
        6: [(0, 0), (2, 0), (0, 1), (2, 1), (0, 2), (2, 2)],
    ]

    var body: some View {
        GeometryReader { geo in
            let unit = geo.size.width / 3
            ForEach(Array((Self.layouts[face] ?? []).enumerated()), id: \.offset) { _, p in
                Circle()
                    .frame(width: unit * 0.44, height: unit * 0.44)
                    .position(x: (CGFloat(p.0) + 0.5) * unit, y: (CGFloat(p.1) + 0.5) * unit)
            }
        }
    }
}
