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

    /// My seat, defaulting to 0 when the match state has not arrived yet — the same fallback
    /// the board rendering below uses, kept as a property so the sound path and the layout
    /// cannot disagree about which side of the match the player is on.
    private var mySeat: Int {
        max(0, engine.cricket?.players.firstIndex(of: me ?? "") ?? 0)
    }

    /// Replays the pitch animation when a NEW ball resolves. Derived from history length rather
    /// than from the ball itself, so two identical balls in a row still animate twice.
    @State private var ballToken = 0
    @State private var lastCount = 0
    @State private var lastInnings = 1

    /// Announcements waiting to be delivered on the pitch. Same queue-and-chain model as the
    /// bot screen, so the two modes announce identically.
    @State private var announcements: [CricketAnnouncement] = []
    @State private var announcementSeq = 0
    /// The role last announced, so a change is noticed ONCE rather than on every server frame.
    /// Nil until the toss resolves and there is a role to have.
    @State private var lastAnnouncedBatting: Bool?

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
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "cricket")
            // The stadium comes up with the screen and stays up for the whole match. It is
            // ambience, not an event — nothing else in the game starts or stops it.
            CricketSound.startBed()
        }
        // Restore the bar on the way OUT. Hiding without restoring left the app with no
        // footer after quitting a game — the bar is opt-out, so every screen that hides
        // it owns putting it back.
        .onDisappear {
            session.hideTabBar = false
            CricketSound.stopBed()
            GameAudio.shared.release(for: "cricket")
        }
        .onChange(of: engine.cricket?.history.count ?? 0) { _, n in
            if n > lastCount, let ball = engine.cricket?.history.last, let s = engine.cricket {
                ballToken += 1
                // `mine` decides which way the crowd reacts: the same wicket is a roar for the
                // bowling side and a groan for the batting one.
                CricketSound.ball(runs: ball.runs, wicket: ball.wicket,
                                  mine: ball.battingSeat == mySeat)
                // The chase tightened (or did not) — push the bed's gain either way.
                CricketSound.updateIntensity(s)
            }
            lastCount = n
        }
        .onChange(of: engine.cricket?.innings ?? 1) { _, innings in
            if innings > lastInnings, let s = engine.cricket {
                CricketSound.inningsBreak()
                // The first innings' total is what the chase is measured against. `target` is
                // that score plus one, so it is the honest source for both numbers — reading
                // the scoreboard here would race the same frame that changed it.
                let firstScore = (s.target ?? 1) - 1
                // AFTER the ball, because an innings almost always ends ON one: the last wicket
                // or the shot that used up the overs. Announcing on the frame that reports the
                // switch clears that ball off the pitch mid-flight.
                let chasing = s.battingSeat == mySeat
                let opponent = opponentName(s)
                let target = s.target ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.ballSettleDelay) {
                    announce(CricketAnnouncements.inningsBreak(
                        id: nextAnnouncementId(),
                        firstInningsScore: firstScore,
                        target: target,
                        iChase: chasing,
                        opponent: opponent))
                }
            }
            lastInnings = innings
        }
        // ROLE CHANGES, wherever they come from. Online, this fires for BOTH the toss
        // resolving and the innings switch — the server just reports a new battingSeat and does
        // not say why. Keying on the value rather than the cause means one hook covers both and
        // neither can be missed.
        //
        // `phase == "play"` gates it: during the toss `battingSeat` is still its provisional
        // value, and announcing a role before anyone has elected would be a guess.
        .onChange(of: rolePhaseKey) { _, _ in
            guard let s = engine.cricket, s.phase == "play" else { return }
            let batting = s.battingSeat == mySeat
            guard batting != lastAnnouncedBatting else { return }
            let isFirst = lastAnnouncedBatting == nil
            lastAnnouncedBatting = batting
            // Also delayed: at the innings switch this lands on the same frame as the break,
            // and both would wipe the closing ball. At the toss there is no ball in flight, so
            // the wait costs nothing there.
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.ballSettleDelay) {
                // The FIRST role change is the match beginning, so the format card leads.
                // It states the house rules (two wickets, matched numbers are out), which are
                // not obvious and which a player who does not know them gets wrong on ball one.
                if isFirst, let st = engine.cricket {
                    announce(CricketAnnouncements.matchStart(
                        id: nextAnnouncementId(),
                        overs: st.overs,
                        wickets: st.wicketsPerInnings))
                }
                announce(CricketAnnouncements.role(id: nextAnnouncementId(), batting: batting))
            }
        }
        .onChange(of: engine.cricket?.finished ?? false) { _, finished in
            guard finished, let s = engine.cricket else { return }
            CricketSound.stopBed()
            CricketSound.matchEnd(won: s.winnerUserId == me)
        }
    }

    /// What the role hook watches: the phase and the batting seat together.
    ///
    /// Both matter. The seat alone would miss the toss resolving when the elected seat happens
    /// to match the provisional one; the phase alone would miss the innings switch.
    private var rolePhaseKey: String {
        guard let s = engine.cricket else { return "" }
        return "\(s.phase)-\(s.battingSeat)"
    }

    /// Longest ball animation plus a beat to read the banner. One constant for every outcome:
    /// a wicket and a six should hold for the same length, or the pacing lurches. Identical to
    /// CricketBotView.
    private static let ballSettleDelay: Double = 1.5

    private func nextAnnouncementId() -> Int {
        announcementSeq += 1
        return announcementSeq
    }

    private func announce(_ a: CricketAnnouncement) {
        let wasIdle = announcements.isEmpty
        announcements.append(a)
        // Only the first starts the drain; the rest are pulled by the one ahead. Concurrent
        // timers would clear the whole queue at once and the second message would never show.
        if wasIdle { scheduleDismiss(of: a) }
    }

    private func scheduleDismiss(of a: CricketAnnouncement) {
        let id = a.id
        DispatchQueue.main.asyncAfter(deadline: .now() + a.duration) {
            guard announcements.first?.id == id else { return }
            withAnimation(.easeInOut(duration: 0.3)) { announcements.removeFirst() }
            if let next = announcements.first { scheduleDismiss(of: next) }
        }
    }

    @ViewBuilder
    private func content(_ s: CricketState) -> some View {
        // THE TOSS OWNS THE SCREEN UNTIL IT RESOLVES. Not a sheet over the scoreboard: there is
        // no score yet, and showing 0-0 behind a coin invites a tap on a pick pad the server
        // would only reject.
        if s.phase != "play" {
            CricketToss(
                phase: s.phase,
                iCall: s.toss.callerSeat == mySeat,
                iElect: s.toss.wonSeat == mySeat,
                coin: s.toss.coin,
                called: s.toss.called,
                opponentName: opponentName(s),
                onCall: { engine.callToss($0) },
                onElect: { engine.electToss($0) })
        } else {
            play(s)
        }
    }

    private func opponentName(_ s: CricketState) -> String {
        let theirSeat = mySeat == 0 ? 1 : 0
        guard s.players.indices.contains(theirSeat) else { return "They" }
        return UserDirectory.shared.displayName(s.players[theirSeat], fallback: "They")
    }

    @ViewBuilder
    private func play(_ s: CricketState) -> some View {
        // My seat decides which half of every by-seat array is mine. A wrong seat would silently
        // swap the whole scoreboard.
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

            CricketOverStrip(
                history: s.history,
                innings: s.innings,
                ballsBowled: s.ballsBowled)
                .padding(.top, VoiidSpacing.sm)

            CricketPitch(event: event, ballToken: ballToken,
                         announcement: announcements.first)
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
        Button {
            GameAudio.shared.play("pick", gain: 0.45)
            engine.pickCricket(n)
        } label: {
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
