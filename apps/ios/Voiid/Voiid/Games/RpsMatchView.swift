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
//  THE SHAKE HAS ONE HONEST WINDOW, AND ONLY ONE. While a single player has thrown, the reveal
//  arrives whenever the opponent taps — which may be minutes later — so a wind-up there would be
//  a lie about timing, and there is none. But once BOTH `hasThrown` flags are true the resolved
//  frame is imminent AND KNOWN TO BE IMMINENT, so the client can legitimately run the three-beat
//  wind-up and reveal at the end of it. If the frame lands early it is held until the wind-up
//  ends; if it has not landed after ~600 ms the wind-up gives up and the reveal happens on
//  arrival. That is exactly the trade SeaBattleMotion makes for the shell (§9), and it invents
//  no state the client was not given.
//
//  Mirrors Android `RpsMatchScreen.kt`.
//

import SwiftUI

struct RpsMatchView: View {
    let matchId: String
    let onClose: () -> Void
    /// Open a freshly-minted rematch. Nil hides the Rematch button — a caller that cannot
    /// navigate to a new match must not offer one.
    var onRematch: ((String) -> Void)?

    @EnvironmentObject var session: AppSession
    @ObservedObject private var engine = GamesEngine.shared

    /// True while the shared wind-up is running — see the header. Drives the forearm swing and,
    /// crucially, HOLDS THE REVEAL: the resolved round is not shown until this clears.
    @State private var winding = false
    @State private var shakeUp = false
    /// Round count at the moment the wind-up started, so a frame that arrives mid-wind-up is
    /// recognised as the one being waited for rather than as a new round.
    @State private var windingFrom = 0

    private var me: String? { TokenStore.shared.userId }

    /// Both players have committed a throw for the CURRENT round, so the resolved frame is
    /// imminent. The one condition under which the wind-up is honest — see the header.
    private var bothThrown: Bool {
        guard let s = engine.rps, !s.finished else { return false }
        return s.hasThrown.count >= 2 && s.hasThrown.allSatisfy { $0 }
    }

    /// Wire name to glyph. The name is what the server's engine validates against.
    private static let options: [(name: String, glyph: String)] = [
        ("rock", "✊"), ("paper", "✋"), ("scissors", "✌️"),
    ]

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
        // THE HANDS STAY VISIBLE BEHIND THE VERDICT (§9.2).
        .overlay {
            if let s = engine.rps, s.finished {
                MatchEndOverlay(
                    result: rpsResult(s),
                    matchId: matchId,
                    onRematch: { newId in engine.leave(); onRematch?(newId) },
                    onExit: { engine.leave(); onClose() })
                .transition(.opacity)
            }
        }
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
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "rps")
        }
        // Restore the bar on the way OUT. Hiding without restoring left the app with no
        // footer after quitting a game — the bar is opt-out, so every screen that hides
        // it owns putting it back.
        .onDisappear {
            session.hideTabBar = false
            GameAudio.shared.release(for: "rps")
        }
        // A new resolved round appeared: the reveal just happened. History only grows, so a
        // count increase is unambiguous — unlike Tic Tac Toe there is nothing to diff, a round
        // is atomic (both throws resolve together, never one cell at a time).
        // BOTH PLAYERS HAVE THROWN: the resolved frame is imminent and known to be, so the
        // wind-up may run. This is the ONLY condition under which it does.
        .onChange(of: bothThrown) { _, both in
            guard both, !winding, let s = engine.rps, !s.finished else { return }
            winding = true
            windingFrom = s.history.count
            Task {
                for i in 0..<(HandRig.pumpCount * 2) {
                    try? await Task.sleep(
                        nanoseconds: UInt64(HandRig.pumpBeat * 1_000_000_000))
                    shakeUp.toggle()
                    if i % 2 == 0 {
                        GameAudio.shared.play("hand_pump",
                                              pitch: RpsBotView.pumpPitches[i / 2], gain: 0.5)
                    }
                }
                winding = false
            }
            // A SAFETY RELEASE. If the server's frame has not arrived by the time the wind-up
            // would have finished plus a margin, stop pretending and let the reveal happen on
            // arrival — a wind-up that outlives its own justification is the lie the header
            // rules out.
            Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                winding = false
            }
        }
        .onChange(of: engine.rps?.history.count) { oldCount, newCount in
            guard let oldCount, let newCount, newCount > oldCount,
                  let s = engine.rps, let round = s.history.last else { return }
            GameAudio.shared.play("hand_reveal", gain: 0.7)
            let mySeat = max(0, s.players.firstIndex(of: me ?? "") ?? 0)
            if let winner = round.winner {
                GameAudio.shared.play(winner == mySeat ? "round_win" : "round_lose", gain: 0.65)
                // THE SHARED SOUND (§3): your throw was COUNTERED. Layered under the round
                // stinger, never instead of it.
                if winner != mySeat { GameAudio.shared.play(GameAudio.catchShared, gain: 0.5) }
            } else {
                GameAudio.shared.play("round_tie", gain: 0.5)
            }
        }
        // No dedicated RPS match-end sound in the catalogue (docs/GAMES_AUDIO.md §9) — the
        // final round's own round_win/round_lose/round_tie above already carries the outcome,
        // so nothing else fires here on `finished`.
    }

    /// Built entirely from the frame — no new wire field (§9.8).
    ///
    /// RPS PLAYS TO A TARGET, so a finished match with equal scores is a genuine tie rather
    /// than an abandonment: `winnerUserId` is nil in both cases, so the score decides which.
    private func rpsResult(_ s: RpsState) -> MatchEndResult {
        let mySeat = max(0, s.players.firstIndex(of: me ?? "") ?? 0)
        let theirSeat = mySeat == 0 ? 1 : 0
        let mine = s.wins.indices.contains(mySeat) ? s.wins[mySeat] : 0
        let theirs = s.wins.indices.contains(theirSeat) ? s.wins[theirSeat] : 0

        // What I threw most across the match — the one read-your-opponent stat the frame
        // already carries, since resolved rounds hold both throws.
        let counts = s.history.reduce(into: [String: Int]()) { acc, round in
            guard let name = round.throws[safe: mySeat] else { return }
            acc[name, default: 0] += 1
        }
        let mostThrown = counts.max(by: { $0.value < $1.value }).map { name, n in
            "\(name.capitalized) (\(n))"
        }

        return .rps(mine: mine, theirs: theirs, mostThrown: mostThrown, record: nil)
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
                     covered: theyThrew && roundOpen,
                     mirrored: true)
            }

            Text(status(s, mySeat: mySeat, iThrew: iThrew, theyThrew: theyThrew, last: last))
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(s.finished ? VoiidColor.primary : VoiidColor.textSecondary)
                .multilineTextAlignment(.center)

            // The end screen is an OVERLAY (§9.2) — see the `overlay` modifier on the body.

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
    /// the client is not allowed to know yet, drawn as a closed fist rather than a real shape.
    private func hand(throwName: String?, covered: Bool, mirrored: Bool = false) -> some View {
        // The forearm swings only during the shared wind-up, which only runs once BOTH players
        // have thrown — see this file's header for why that window and no other.
        let forearm: Double = winding ? (shakeUp ? HandRig.pumpUp : HandRig.pumpDown) : 0
        let pose: HandRig.Pose = (covered || winding)
            ? HandRig.Pose.lerp(HandRig.neutral, HandRig.rock, winding && shakeUp ? 0.10 : 0.0)
            : HandRig.pose(for: Self.index(for: throwName))

        return RoundedRectangle(cornerRadius: VoiidRadius.lg)
            .fill(VoiidColor.surfaceCard)
            .aspectRatio(1, contentMode: .fit)
            .overlay(
                HandView(
                    pose: pose,
                    forearm: forearm,
                    wrist: forearm * 0.72,
                    mirrored: mirrored)
                    .padding(VoiidSpacing.sm)
            )
            .animation(.spring(response: 0.16, dampingFraction: 0.42), value: shakeUp)
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: throwName)
    }

    /// Wire name -> rig pose index, matching `RpsBot`'s ordering.
    private static func index(for name: String?) -> Int? {
        switch name {
        case "rock":     return 0
        case "paper":    return 1
        case "scissors": return 2
        default:         return nil
        }
    }
}

/// Bounds-safe subscript. The server controls array lengths, so a renderer that indexes them
/// blind would crash on a malformed or future-shaped frame rather than degrade.
private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
