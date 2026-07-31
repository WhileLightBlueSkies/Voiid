//
//  TicTacToeView.swift
//  Voiid
//
//  The first game renderer (docs/GAMES.md §4). A dumb view over GamesEngine's state: it
//  draws the board the server sent and reports taps. It contains NO rules — no win check,
//  no turn logic, no "is this cell free". Every one of those questions is answered by
//  backend/games, and duplicating any of them here is how the two sides drift apart.
//
//  Plain SwiftUI views rather than Canvas, on purpose: a 3x3 grid of tappable cells is not
//  a drawing problem, and staying in ordinary views means it inherits DesignSystem tokens,
//  Dynamic Type and accessibility for free. Canvas is for the arcade games later.
//
//  Mirrors Android `TicTacToeScreen.kt`.
//

import SwiftUI

struct TicTacToeView: View {
    let matchId: String
    var onClose: (() -> Void)?

    @StateObject private var engine = GamesEngine.shared
    @EnvironmentObject var session: AppSession

    private var me: String? { TokenStore.shared.userId }

    /// My seat index, which is also my mark (0 = X, 1 = O).
    private var mySeat: Int? {
        guard let me, let players = engine.state?.players else { return nil }
        let idx = players.firstIndex(of: me)
        return idx
    }

    private var isMyTurn: Bool {
        guard let s = engine.state, let me else { return false }
        return !s.finished && s.turnUserId == me
    }

    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            if let state = engine.state {
                board(state)
                status(state)
            } else if let err = engine.joinError {
                // Truthful failure rather than an empty board that will never fill in.
                Text(err)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.error)
                    .padding(.top, VoiidSpacing.xl)
            } else {
                // The opening board is built by the server and arrives as a frame, so
                // there is a real (brief) waiting state here.
                ProgressView()
                    .padding(.top, VoiidSpacing.xl)
                Text("Setting up the board…")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Tic Tac Toe")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { engine.leave(); onClose?() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
        }
        .task { await engine.open(matchId: matchId) }
        .onAppear { session.hideTabBar = true }
        .onDisappear { session.hideTabBar = false; engine.leave() }
    }

    // MARK: - Pieces


    /// Shared with the bot game so the two modes cannot drift visually. Taps are disabled
    /// unless it is genuinely my turn — the server would reject them anyway, so this only
    /// avoids sending frames we know are pointless.
    private func board(_ state: TicTacToeState) -> some View {
        TicTacToeBoard(
            board: state.board,
            line: state.line,
            enabled: isMyTurn,
            onTap: { engine.play(cell: $0) }
        )
        .padding(.top, VoiidSpacing.md)
    }

    @ViewBuilder
    private func status(_ state: TicTacToeState) -> some View {
        let text: String = {
            if state.finished {
                guard let winner = state.winnerUserId else { return "Draw" }
                return winner == me ? "You win" : "You lose"
            }
            return isMyTurn ? "Your turn" : "Their turn"
        }()

        Text(text)
            .font(VoiidFont.rounded(16, .semibold))
            .foregroundStyle(state.finished ? VoiidColor.primary : VoiidColor.textSecondary)
            .padding(.top, VoiidSpacing.md)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
