//
//  GameLobbyView.swift
//  Voiid
//
//  The waiting room between sending an invite and the board opening.
//
//  WHY THIS EXISTS. Creating a match used to drop the creator straight onto a board that could not
//  be played — the opponent hadn't joined, so no `game_state` frame ever arrived and the screen sat
//  on "Setting up the match…" forever. Worse, from the home screen it looked like nothing had
//  happened at all. A lobby makes the actual state legible: the invite is sent, we are waiting, and
//  here is how long they have.
//
//  IT WATCHES FOR THE SAME FRAME THE BOARD DOES. The opponent joining is what makes the server build
//  and broadcast the opening state, so a non-nil game state IS the signal that the match is live —
//  no extra "they joined" message is needed, and none exists.
//
//  Mirrors Android `GameLobbyScreen.kt`.
//

import SwiftUI

/// Everything the lobby needs to describe itself, captured when the invite was sent.
///
/// Passed in rather than re-fetched: the creator already knows the game, the opponent and the
/// settings — a round-trip to learn what they just chose would be a spinner for no reason.
struct LobbyArgs: Identifiable, Hashable {
    let id: String          // matchId
    let slug: String
    let gameName: String
    let opponentName: String
    let detailLine: String
    /// TOTAL seats including the creator. Two for every 1:1 game, which is why it defaults —
    /// only a multi-seat game has to say anything.
    var seatCount: Int = 2
}

struct GameLobbyView: View {
    let args: LobbyArgs
    let onStart: () -> Void
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared

    @State private var remaining: Int64 = GameInvite.expiryMs
    @State private var expired = false
    @State private var pulse = false

    private let api = GamesAPI()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Cancel") {
                    // Leaving the lobby abandons the match: a 'waiting' row nobody will ever join
                    // is exactly what decline is for.
                    engine.leave()
                    Task { try? await api.decline(matchId: args.id) }
                    onClose()
                }
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(VoiidColor.primary)
                Spacer()
            }
            .padding(.top, VoiidSpacing.md)

            Spacer()

            // The game, as a poster — the same artwork the invite carries, so the two read as one.
            ZStack {
                Rectangle().fill(VoiidColor.primary.opacity(0.10))
                if UIImage(named: "game_\(args.slug)") != nil {
                    Image("game_\(args.slug)")
                        .resizable()
                        .scaledToFill()
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.5), location: 1)],
                        startPoint: .top, endPoint: .bottom)
                } else {
                    Image(systemName: "gamecontroller")
                        .font(.system(size: 48))
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg))

            Text(args.gameName)
                .font(VoiidFont.rounded(24, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .padding(.top, VoiidSpacing.md)
            if !args.detailLine.isEmpty {
                Text(args.detailLine)
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            if expired {
                Text(args.seatCount > 2 ? "Not everyone joined"
                                        : "\(args.opponentName) didn't join")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .padding(.top, VoiidSpacing.lg)
                Text("The invite expired. Send another whenever you like.")
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
                Button {
                    engine.leave()
                    onClose()
                } label: {
                    Text("Back to games")
                        .font(VoiidFont.rounded(16, .bold))
                        .foregroundStyle(VoiidColor.textOnPrimary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, VoiidSpacing.md)
                        .background(Capsule().fill(VoiidColor.primary))
                }
                .padding(.top, VoiidSpacing.lg)
            } else {
                // Breathing dots: a waiting state needs to look alive, or it reads as frozen.
                HStack(spacing: 6) {
                    ForEach(0..<3, id: \.self) { i in
                        Circle()
                            .fill(VoiidColor.primary)
                            .frame(width: 8, height: 8)
                            .opacity(pulse ? 1.0 - Double(i) * 0.2 : 0.35)
                    }
                }
                .padding(.top, VoiidSpacing.lg)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }

                // SEATS FILLING IN REAL TIME IS ITSELF ENGAGING (LUDO.md §12.4) — it is the
                // "who else is coming" moment, and it should be visible rather than hidden
                // behind a spinner. Only drawn for a genuinely multi-seat match; two pips for a
                // 1:1 game would be noise dressed up as information.
                if args.seatCount > 2 {
                    HStack(spacing: 6) {
                        ForEach(0..<args.seatCount, id: \.self) { seat in
                            // Seat 0 is the creator, who is by definition here. The rest are
                            // unknown until the board arrives — the server does not narrate
                            // individual joins, so this shows "you, plus N still coming" rather
                            // than inventing per-person state it does not have.
                            Circle()
                                .fill(seat == 0 ? VoiidColor.primary
                                                : VoiidColor.textSecondary.opacity(0.25))
                                .frame(width: 10, height: 10)
                        }
                    }
                    .padding(.top, VoiidSpacing.md)
                    .accessibilityLabel("\(args.seatCount) seats, 1 filled")
                }

                Text(args.seatCount > 2
                     ? "Waiting for \(args.seatCount - 1) players…"
                     : "Waiting for \(args.opponentName)…")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .padding(.top, VoiidSpacing.sm)
                Text("Invite sent in chat · expires in \(countdown(remaining))")
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.top, 4)
            }

            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .onAppear { session.hideTabBar = true }
        // Restore the bar on the way OUT. Hiding without restoring left the app with no
        // footer after quitting a game — the bar is opt-out, so every screen that hides
        // it owns putting it back.
        .onDisappear { session.hideTabBar = false }
        // ANY game state arriving means the server built the board, which only happens once
        // every seat is filled.
        //
        // EVERY GAME MUST BE LISTED HERE. This checked three states and silently omitted Snake;
        // a game left out never leaves the lobby, because the frame that means "we are live"
        // lands in a property nothing is watching. Adding a game is one more term.
        .onChange(of: engine.state == nil && engine.rps == nil && engine.cricket == nil
                  && engine.seaBattle == nil && engine.ludoV2 == nil
                  && engine.snakeFrames.isEmpty) { _, empty in
            if !empty { onStart() }
        }
        .task {
            let deadline = GameInvite.nowMs() + GameInvite.expiryMs
            while !Task.isCancelled {
                let left = deadline - GameInvite.nowMs()
                remaining = max(0, left)
                if left <= 0 { break }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            guard !Task.isCancelled else { return }
            // Nobody came. Abandon it so the row can't linger as a live invite on their side.
            expired = true
            try? await api.decline(matchId: args.id)
        }
    }

    /// "9:04" — a countdown, not a duration. Seconds zero-padded so it doesn't jitter in width.
    private func countdown(_ ms: Int64) -> String {
        let total = max(0, ms / 1000)
        return "\(total / 60):\(String(format: "%02d", total % 60))"
    }
}
