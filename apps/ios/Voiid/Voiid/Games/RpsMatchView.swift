//
//  RpsMatchView.swift
//  Voiid
//
//  Rock Paper Scissors against a FRIEND, refereed by the server (docs/GAMES.md §4).
//
//  WHY THIS VIEW EXISTS SEPARATELY FROM TicTacToeView: the online board used to render a 3x3
//  grid for every match regardless of slug, so an RPS invite opened a tic-tac-toe board. The
//  server has refereed RPS all along — only the renderer was missing.
//
//  THE OPPONENT'S HAND IS NOT DRAWN MID-ROUND, AND CANNOT BE. The server sends `hasThrown`
//  booleans while a round is open and never the throw itself, because RPS is simultaneous:
//  leaking the first throw would let whoever moves second win every time. So this shows a
//  covered hand plus "they've thrown" — that is the entire truth available, and faking a hand
//  here would be inventing state the client was deliberately not given.
//
//  No shake animation either, for the same honest reason: the bot view shakes because it
//  knows when both throws exist and can time the reveal. Here the reveal arrives whenever the
//  opponent taps, which may be minutes later, so a shake would be a lie about timing.
//
//  Mirrors Android `RpsMatchScreen.kt`.
//

import SwiftUI

struct RpsMatchView: View {
    let matchId: String
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared

    private var me: String? { TokenStore.shared.userId }

    /// Wire name to glyph. The name is what the server's engine validates against.
    private static let options: [(name: String, glyph: String)] = [
        ("rock", "✊"), ("paper", "✋"), ("scissors", "✌️"),
    ]

    private static func glyph(for name: String?) -> String {
        switch name {
        case "rock":     return "✊"
        case "paper":    return "✋"
        case "scissors": return "✌️"
        default:         return "✊"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let s = engine.rps {
                content(s)
            } else if let err = engine.joinError {
                // Truthful failure rather than an empty board that will never fill in.
                Text(err)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.top, VoiidSpacing.xl)
            } else {
                // The opening state is built by the server and arrives as a frame, so there
                // is a real (brief) waiting state here.
                VStack(spacing: VoiidSpacing.sm) {
                    ProgressView()
                    Text("Setting up the match…")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .padding(.top, VoiidSpacing.xl)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Rock Paper Scissors")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button { engine.leave(); onClose() } label: {
                    Image(systemName: "chevron.left").foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityLabel("Back")
            }
        }
        .task { await engine.open(matchId: matchId) }
        .onAppear { session.hideTabBar = true }
        // Restore the bar on the way OUT. Hiding without restoring left the app with no
        // footer after quitting a game — the bar is opt-out, so every screen that hides
        // it owns putting it back.
        .onDisappear { session.hideTabBar = false }
    }

    @ViewBuilder
    private func content(_ s: RpsState) -> some View {
        // My seat decides which half of every by-seat array is mine. Derived once — a wrong
        // seat would silently swap the whole scoreboard.
        let mySeat = max(0, s.players.firstIndex(of: me ?? "") ?? 0)
        let theirSeat = mySeat == 0 ? 1 : 0
        let iThrew = s.hasThrown.indices.contains(mySeat) ? s.hasThrown[mySeat] : false
        let theyThrew = s.hasThrown.indices.contains(theirSeat) ? s.hasThrown[theirSeat] : false
        let last = s.history.last
        let roundOpen = last == nil || iThrew || theyThrew

        VStack(spacing: VoiidSpacing.lg) {
            HStack {
                scoreBlock("You", s.wins.indices.contains(mySeat) ? s.wins[mySeat] : 0)
                Spacer()
                Text("first to \(s.target)")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                Spacer()
                scoreBlock("Them", s.wins.indices.contains(theirSeat) ? s.wins[theirSeat] : 0)
            }
            .padding(.top, VoiidSpacing.lg)

            HStack(spacing: VoiidSpacing.md) {
                hand(throwName: iThrew && roundOpen ? nil : last?.`throws`[safe: mySeat],
                     covered: iThrew && roundOpen)
                hand(throwName: theyThrew && roundOpen ? nil : last?.`throws`[safe: theirSeat],
                     covered: theyThrew && roundOpen)
            }

            Text(status(s, mySeat: mySeat, iThrew: iThrew, theyThrew: theyThrew, last: last))
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            // Throw buttons. Disabled once I've thrown this round or the match is over — the
            // server rejects both anyway, this only avoids a pointless frame.
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(Self.options, id: \.name) { t in
                    Button { engine.throwRps(t.name) } label: {
                        Text(t.glyph)
                            .font(.system(size: 34))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoiidSpacing.md)
                            .background(
                                Capsule().fill(VoiidColor.fieldFill
                                    .opacity(!s.finished && !iThrew ? 1 : 0.4)))
                    }
                    .disabled(s.finished || iThrew)
                    .accessibilityLabel(t.name)
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.lg)
    }

    private func status(
        _ s: RpsState, mySeat: Int, iThrew: Bool, theyThrew: Bool, last: RpsState.Round?
    ) -> String {
        if s.finished {
            if s.winnerUserId == nil { return "Tie" }
            return s.winnerUserId == me ? "You win the match" : "You lose the match"
        }
        if iThrew && !theyThrew { return "Waiting for them…" }
        if !iThrew && theyThrew { return "They've thrown — your turn" }
        if iThrew { return "Revealing…" }
        if let last {
            guard let w = last.winner else { return "Tied round — throw again" }
            return w == mySeat ? "You won the round" : "They won the round"
        }
        return "Throw to begin"
    }

    private func scoreBlock(_ label: String, _ wins: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(wins)")
                .font(VoiidFont.rounded(34, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text(label)
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    /// One hand. `covered` means "thrown, but not revealed" — the honest rendering of a throw
    /// the client is not allowed to know yet.
    private func hand(throwName: String?, covered: Bool) -> some View {
        RoundedRectangle(cornerRadius: VoiidRadius.lg)
            .fill(VoiidColor.surfaceCard)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                Text(covered ? "🤛" : Self.glyph(for: throwName))
                    .font(.system(size: 64))
            )
            // A small pop when a real throw appears, so a reveal registers as an event.
            .scaleEffect(throwName != nil ? 1 : 0.92)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: throwName)
    }
}

/// Bounds-safe subscript. The server controls array lengths, so a renderer that indexes them
/// blind would crash on a malformed or future-shaped frame rather than degrade.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
