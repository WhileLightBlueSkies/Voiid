//
//  CricketMatchView.swift
//  Voiid
//
//  Hand Cricket against a FRIEND, refereed by the server (docs/GAMES_HAND_CRICKET.md).
//
//  A DUMB VIEW, unlike `CricketBotView`. It computes no runs, takes no wickets and decides no
//  innings — every one of those is answered by backend/games/src/engine/cricket, and duplicating
//  any of them here is how the two sides drift apart. The bot view referees because a practice
//  match never reaches a server; this one never does.
//
//  THE OPPONENT'S PICK IS NOT DRAWN WHILE THE BALL IS OPEN, AND CANNOT BE. The server sends
//  `hasPicked` booleans and never the pick, because hand cricket is simultaneous: leaking the
//  batter's number would let the bowler match it at will (a guaranteed wicket) and leaking the
//  bowler's would let the batter dodge forever. So a pending pick renders as a lock — the entire
//  truth available.
//
//  Mirrors Android `CricketMatchScreen.kt`.
//

import SwiftUI

struct CricketMatchView: View {
    let matchId: String
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared

    private var me: String? { TokenStore.shared.userId }

    /// Replays the pitch animation when a NEW ball resolves. Derived from history length rather
    /// than from the ball itself, so two identical balls in a row still animate twice.
    @State private var ballToken = 0
    @State private var lastCount = 0

    var body: some View {
        VStack(spacing: 0) {
            if let s = engine.cricket {
                content(s)
            } else if let err = engine.joinError {
                // Truthful failure rather than an empty board that will never fill in.
                Text(err)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.top, VoiidSpacing.xl)
            } else {
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
        .padding(.horizontal, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Hand Cricket")
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
        .onChange(of: engine.cricket?.history.count ?? 0) { _, n in
            if n > lastCount { ballToken += 1 }
            lastCount = n
        }
    }

    @ViewBuilder
    private func content(_ s: CricketState) -> some View {
        // My seat decides which half of every by-seat array is mine. A wrong seat would silently
        // swap the whole scoreboard.
        let mySeat = max(0, s.players.firstIndex(of: me ?? "") ?? 0)
        let theirSeat = mySeat == 0 ? 1 : 0
        let iAmBatting = s.battingSeat == mySeat
        let iPicked = s.hasPicked.indices.contains(mySeat) ? s.hasPicked[mySeat] : false
        let theyPicked = s.hasPicked.indices.contains(theirSeat) ? s.hasPicked[theirSeat] : false
        let last = s.history.last
        let ballOpen = iPicked || theyPicked

        let battingScore = s.scores.indices.contains(s.battingSeat) ? s.scores[s.battingSeat] : 0
        let battingWickets = s.wickets.indices.contains(s.battingSeat) ? s.wickets[s.battingSeat] : 0

        let event: BallEvent? = last.map {
            BallEvent.of(
                runs: $0.runs,
                wicket: $0.wicket,
                // Both picks are equal on a wicket, so either index gives the matched number the
                // animation choice depends on.
                matchedPick: $0.picks.first ?? 0)
        }

        VStack(spacing: 0) {
            Spacer(minLength: 0)

            VStack(spacing: 2) {
                Text(iAmBatting ? "You're batting" : "You're bowling")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                Text("\(battingScore)-\(battingWickets)")
                    .font(VoiidFont.rounded(40, .bold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .contentTransition(.numericText())
                Text(oversLine(s))
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            CricketPitch(event: event, ballToken: ballToken)
                .padding(.vertical, VoiidSpacing.md)

            // Picks. Mine is known to me the moment I tap; theirs is genuinely unavailable until
            // the ball resolves.
            HStack(spacing: VoiidSpacing.xl) {
                pickFace("You",
                         pick: ballOpen && iPicked ? nil : last?.picks[safe: mySeat],
                         covered: iPicked && ballOpen)
                pickFace("Them",
                         pick: ballOpen && theyPicked ? nil : last?.picks[safe: theirSeat],
                         covered: theyPicked && ballOpen)
            }

            Text(status(s, mySeat: mySeat, theirSeat: theirSeat,
                        iAmBatting: iAmBatting, iPicked: iPicked, theyPicked: theyPicked))
                .font(VoiidFont.rounded(s.finished ? 20 : 14, s.finished ? .bold : .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.top, VoiidSpacing.md)

            Spacer(minLength: 0)

            if !s.finished {
                // 0-6 in two rows: seven buttons in one row are too narrow to hit.
                VStack(spacing: VoiidSpacing.sm) {
                    HStack(spacing: VoiidSpacing.sm) {
                        ForEach(0...3, id: \.self) { n in pickButton(n, disabled: iPicked) }
                    }
                    HStack(spacing: VoiidSpacing.sm) {
                        ForEach(4...6, id: \.self) { n in pickButton(n, disabled: iPicked) }
                        Color.clear.frame(maxWidth: .infinity)
                    }
                }
                .padding(.bottom, VoiidSpacing.xl)
            }
        }
    }

    private func oversLine(_ s: CricketState) -> String {
        var line = "\(s.ballsBowled / 6).\(s.ballsBowled % 6) / \(s.ballsTotal / 6).0 ov"
        if let t = s.target { line += "  ·  needs \(t)" }
        return line
    }

    private func status(
        _ s: CricketState, mySeat: Int, theirSeat: Int,
        iAmBatting: Bool, iPicked: Bool, theyPicked: Bool
    ) -> String {
        let mine = s.scores.indices.contains(mySeat) ? s.scores[mySeat] : 0
        let theirs = s.scores.indices.contains(theirSeat) ? s.scores[theirSeat] : 0
        if s.finished {
            if s.winnerUserId == nil { return "Tied  \(mine)–\(theirs)" }
            return s.winnerUserId == me ? "You win!  \(mine)–\(theirs)"
                                        : "You lose.  \(mine)–\(theirs)"
        }
        if iPicked && !theyPicked { return "Waiting for them…" }
        if !iPicked && theyPicked { return "They've picked — your turn" }
        if iPicked { return "Revealing…" }
        return iAmBatting ? "Pick your runs" : "Pick to bowl"
    }

    private func pickFace(_ label: String, pick: Int?, covered: Bool) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: VoiidRadius.md)
                .fill(VoiidColor.surfaceCard)
                .frame(width: 64, height: 64)
                .overlay(
                    // A covered face is not "no pick" — it is a pick this client isn't allowed to
                    // see yet, and the lock says so rather than implying nothing happened.
                    Group {
                        if covered {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(VoiidColor.textSecondary)
                        } else {
                            Text(pick.map(String.init) ?? "—")
                                .font(VoiidFont.rounded(26, .bold))
                                .foregroundStyle(VoiidColor.textPrimary)
                        }
                    })
            Text(label)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private func pickButton(_ n: Int, disabled: Bool) -> some View {
        Button { engine.pickCricket(n) } label: {
            Text("\(n)")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.md)
                    .fill(VoiidColor.fieldFill.opacity(disabled ? 0.4 : 1)))
        }
        .disabled(disabled)
    }
}

/// Bounds-safe subscript. The server controls array lengths, so a renderer that indexes them blind
/// would crash on a malformed or future-shaped frame rather than degrade.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
