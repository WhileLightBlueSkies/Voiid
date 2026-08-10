//
//  CricketBotView.swift
//  Voiid
//
//  Hand Cricket against the local bot (docs/GAMES_HAND_CRICKET.md).
//
//  THE RULES LIVE HERE, deliberately, unlike the online view. A bot match never reaches the server,
//  so there is no referee to defer to — this view IS the referee for practice play. It mirrors
//  backend/games/src/engine/cricket exactly: same 0-6 picks, same 2 wickets, same "matched number
//  is out including 0 vs 0", same target = score + 1. If the two ever disagree the bot game is
//  teaching a rule the real game doesn't have, which is worse than no bot at all.
//
//  OVERS ARE CHOSEN FIRST AND THEN LOCKED, matching how difficulty locks: a match length you can
//  change mid-innings is not a match length.
//
//  Mirrors Android `CricketBotScreen.kt`.
//

import SwiftUI

private let ballsPerOver = 6
private let wicketsPerInnings = 2

struct CricketBotView: View {
    let level: BotDifficulty
    let skill: Double
    let onClose: () -> Void

    @EnvironmentObject var session: AppSession

    /// Nil until the player picks a length — the match cannot start without one.
    @State private var overs: Int?

    @State private var innings = 1
    @State private var humanBatting = true
    @State private var humanScore = 0
    @State private var botScore = 0
    @State private var humanWickets = 0
    @State private var botWickets = 0
    @State private var ballsBowled = 0
    @State private var target: Int?

    // MARK: Toss
    //
    // Mirrors the server engine's phases exactly, so the two flows cannot drift: the coin is
    // decided when the match length is chosen (BEFORE anyone can call, same as the server —
    // deciding it on the call would make the outcome depend on the input), then the human
    // calls, then whoever won elects.
    @State private var tossPhase = "toss-call"
    @State private var tossCoin = ""
    @State private var tossCalled: String?
    @State private var tossWonByHuman = false
    /// Withheld until the call, matching what the server sends — the UI must not be able to
    /// show a face nobody has called yet.
    private var tossCoinRevealed: String? { tossCalled == nil ? nil : tossCoin }

    @State private var lastEvent: BallEvent?
    @State private var ballToken = 0
    @State private var humanPick: Int?
    @State private var botPick: Int?
    @State private var resolving = false
    @State private var finished = false
    /// Nil = tie.
    @State private var humanWon: Bool?
    @State private var paused = false
    @State private var recorded = false

    // Kept per ROLE: how someone bats says little about how they bowl, so one mixed history would
    // blur the bot's model into noise.
    @State private var humanBatHistory: [Int] = []
    @State private var humanBowlHistory: [Int] = []

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header

                if overs == nil {
                    oversPicker
                } else if tossPhase != "play" {
                    // Same two-step toss as the online game, run locally — there is no server
                    // in a bot match, so this view is the referee for it exactly as it already
                    // is for the scoring rules.
                    CricketToss(
                        phase: tossPhase,
                        iCall: true,          // you always call against the bot
                        iElect: tossWonByHuman,
                        coin: tossCoinRevealed,
                        called: tossCalled,
                        opponentName: "The bot",
                        onCall: callToss,
                        onElect: electToss)
                } else {
                    Spacer(minLength: 0)
                    scoreboard
                    CricketPitch(event: lastEvent, ballToken: ballToken)
                        .padding(.vertical, VoiidSpacing.md)
                    picks
                    Spacer(minLength: 0)
                    if finished { result } else { pickPad }
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)

            if paused { pauseOverlay }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "cricket")
            // The stadium comes up with the screen and stays up for the whole match.
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
    }

    // MARK: - Pieces

    private var header: some View {
        HStack {
            Text(level.label)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 6)
                .background(Capsule().fill(VoiidColor.fieldFill))
            Spacer()
            Button { paused = true } label: {
                Image(systemName: "pause.fill").foregroundStyle(VoiidColor.textPrimary)
            }
            .disabled(finished || overs == nil)
            .accessibilityLabel("Pause")
        }
        .padding(.vertical, VoiidSpacing.sm)
    }

    /// Match length, chosen before anything starts and then locked.
    private var oversPicker: some View {
        VStack(spacing: 0) {
            Spacer()
            Text("How many overs?")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text("6 balls each. 2 wickets. Locked once you start.")
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.top, 4)
                .padding(.bottom, VoiidSpacing.lg)
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(1...5, id: \.self) { n in
                    Button {
                        Haptics.tap()
                        // The coin is decided HERE, before the toss screen appears and so
                        // before anyone can call it — the same ordering the server uses, and
                        // for the same reason: a coin decided on the call is a coin whose
                        // result depends on the call.
                        tossCoin = Bool.random() ? "heads" : "tails"
                        overs = n
                    } label: {
                        Text("\(n)")
                            .font(VoiidFont.rounded(20, .bold))
                            .foregroundStyle(VoiidColor.textPrimary)
                            .frame(width: 54, height: 54)
                            .background(Circle().fill(VoiidColor.fieldFill))
                    }
                }
            }
            Spacer()
        }
    }

    private var scoreboard: some View {
        let battingScore = humanBatting ? humanScore : botScore
        let battingWickets = humanBatting ? humanWickets : botWickets
        return VStack(spacing: 2) {
            Text(humanBatting ? "You're batting" : "You're bowling")
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
            Text("\(battingScore)-\(battingWickets)")
                .font(VoiidFont.rounded(40, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .contentTransition(.numericText())
            Text(oversLine)
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private var oversLine: String {
        var s = "\(ballsBowled / ballsPerOver).\(ballsBowled % ballsPerOver) / \(overs ?? 0).0 ov"
        if let t = target { s += "  ·  needs \(t)" }
        return s
    }

    private var picks: some View {
        HStack(spacing: VoiidSpacing.xl) {
            pickFace("You", humanPick, hidden: resolving)
            pickFace("Bot", botPick, hidden: resolving)
        }
    }

    private func pickFace(_ label: String, _ pick: Int?, hidden: Bool) -> some View {
        VStack(spacing: 4) {
            RoundedRectangle(cornerRadius: VoiidRadius.md)
                .fill(VoiidColor.surfaceCard)
                .frame(width: 64, height: 64)
                .overlay(
                    Text(hidden || pick == nil ? "—" : "\(pick!)")
                        .font(VoiidFont.rounded(28, .bold))
                        .foregroundStyle(VoiidColor.textPrimary))
            Text(label)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private var pickPad: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Text(humanBatting ? "Pick your runs" : "Pick to bowl")
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
            // 0-6 in two rows: seven buttons in one row are too narrow to hit.
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(0...3, id: \.self) { n in pickButton(n) }
            }
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(4...6, id: \.self) { n in pickButton(n) }
                Color.clear.frame(maxWidth: .infinity)
            }
        }
        .padding(.bottom, VoiidSpacing.xl)
    }

    private func pickButton(_ n: Int) -> some View {
        Button { pick(n) } label: {
            Text("\(n)")
                .font(VoiidFont.rounded(22, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.md)
                    .fill(VoiidColor.fieldFill.opacity(resolving ? 0.4 : 1)))
        }
        .disabled(resolving)
    }

    private var result: some View {
        VStack(spacing: VoiidSpacing.md) {
            Text(resultText)
                .font(VoiidFont.rounded(20, .bold))
                .foregroundStyle(VoiidColor.primary)
            HStack(spacing: VoiidSpacing.sm) {
                pill("Play again", filled: true) { restart() }
                pill("Exit", filled: false) { onClose() }
            }
        }
        .padding(.bottom, VoiidSpacing.xl)
    }

    private var resultText: String {
        switch humanWon {
        case true?:  return "You win!  \(humanScore)–\(botScore)"
        case false?: return "You lose.  \(humanScore)–\(botScore)"
        default:     return "Tied.  \(humanScore)–\(botScore)"
        }
    }

    private func pill(_ label: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(VoiidFont.rounded(15, .bold))
                .foregroundStyle(filled ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(Capsule().fill(filled ? VoiidColor.primary : VoiidColor.fieldFill))
        }
    }

    private var pauseOverlay: some View {
        VoiidColor.background.opacity(0.94).ignoresSafeArea()
            .overlay(
                VStack(spacing: VoiidSpacing.sm) {
                    Text("Paused")
                        .font(VoiidFont.rounded(26, .bold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .padding(.bottom, VoiidSpacing.md)
                    menuButton("Resume", "play.fill", filled: true) { paused = false }
                    menuButton("Restart", "arrow.clockwise", filled: false) { restart() }
                    menuButton("Give up", "flag.fill", filled: false, danger: true) {
                        // Walking out mid-match is a loss, recorded — otherwise the local record
                        // would only ever contain wins and finished games.
                        if !recorded { BotScoreStore.add(level, outcome: -1); recorded = true }
                        onClose()
                    }
                }
                .padding(.horizontal, VoiidSpacing.xl))
    }

    private func menuButton(
        _ label: String, _ icon: String, filled: Bool, danger: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let tint: Color = danger ? VoiidColor.error
            : (filled ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
        return Button(action: action) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: icon).font(.system(size: 16))
                Text(label).font(VoiidFont.rounded(16, .semibold))
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.md)
            .background(Capsule().fill(filled ? VoiidColor.primary : VoiidColor.fieldFill))
        }
    }

    // MARK: - Game logic (mirrors backend/games/src/engine/cricket)

    private func pick(_ n: Int) {
        guard !resolving, !finished, !paused, overs != nil else { return }
        GameAudio.shared.play("pick", gain: 0.45)
        humanPick = n
        botPick = nil
        resolving = true

        let history = humanBatting ? humanBatHistory : humanBowlHistory
        let theirs = CricketBot.choosePick(
            humanHistory: history, skill: skill, botIsBatting: !humanBatting)
        botPick = theirs

        // A beat before resolving so the reveal has real elapsed time rather than landing in the
        // same frame as the tap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            resolve(mine: n, theirs: theirs)
            resolving = false
        }
    }

    private func resolve(mine: Int, theirs: Int) {
        guard let o = overs else { return }
        let batterPick = humanBatting ? mine : theirs
        let wicket = CricketBot.isWicket(batterPick: mine, bowlerPick: theirs)
        let runs = wicket ? 0 : batterPick

        if wicket {
            if humanBatting { humanWickets += 1 } else { botWickets += 1 }
        } else {
            if humanBatting { humanScore += runs } else { botScore += runs }
        }
        ballsBowled += 1
        lastEvent = BallEvent.of(runs: runs, wicket: wicket, matchedPick: mine)
        ballToken += 1
        playBallSound(runs: runs, wicket: wicket)

        // Record the human's pick AFTER resolving, so the model never sees the pick it was
        // predicting on this very ball.
        if humanBatting { humanBatHistory.append(mine) } else { humanBowlHistory.append(mine) }

        let battingScore = humanBatting ? humanScore : botScore
        let battingWickets = humanBatting ? humanWickets : botWickets

        // A chase that reaches the target ends immediately — no playing out the overs.
        if innings == 2, let t = target, battingScore >= t {
            finish(humanBatting)
            return
        }

        let inningsOver = battingWickets >= wicketsPerInnings
            || ballsBowled >= o * ballsPerOver
        guard inningsOver else { return }

        if innings == 1 {
            innings = 2
            humanBatting.toggle()
            ballsBowled = 0
            target = battingScore + 1
            CricketSound.inningsBreak()
        } else {
            // Second innings ended short. Equal totals = tie.
            finish(humanScore == botScore ? nil : humanScore > botScore)
        }
    }

    // MARK: - Toss

    private func callToss(_ side: String) {
        tossCalled = side
        tossWonByHuman = side == tossCoin
        tossPhase = "toss-decide"

        guard !tossWonByHuman else { return }
        // The bot won, so it decides. After a beat, so its choice does not land in the same
        // frame as the coin — the player needs to read the result before it is acted on.
        Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard tossPhase == "toss-decide" else { return }
            electToss(botElection())
        }
    }

    private func electToss(_ choice: String) {
        // Whoever elected, apply it from the ELECTOR's point of view: `tossWonByHuman` says
        // whose choice this is, so one line covers both.
        humanBatting = tossWonByHuman ? (choice == "bat") : (choice == "bowl")
        tossPhase = "play"
        updateCrowd()
    }

    /// What the bot elects.
    ///
    /// BOWLING FIRST IS THE STRONGER PLAY in a two-wicket format — batting second means
    /// knowing exactly what you have to chase — so the bot prefers it, and prefers it harder
    /// at higher difficulty. At low skill it is closer to a coin flip, which keeps easy mode
    /// feeling like a real opponent rather than a solved one.
    private func botElection() -> String {
        Double.random(in: 0..<1) < 0.5 + 0.35 * skill ? "bowl" : "bat"
    }

    /// One resolved ball -> its sound. Delegates to CricketSound, shared with the online game,
    /// so bot and online cricket cannot disagree about what a ball sounds like.
    private func playBallSound(runs: Int, wicket: Bool) {
        // `humanBatting` is what decides which way the crowd reacts: the same wicket is a roar
        // when the bot loses one and a groan when you do.
        CricketSound.ball(runs: runs, wicket: wicket, mine: humanBatting)
        updateCrowd()
    }

    /// Push the crowd bed's gain from the bot match's own state.
    ///
    /// The online path can hand CricketSound a whole CricketState; a bot match has no such
    /// object, so the same curve is fed from the local vars. Keeping ONE curve and two callers
    /// is the point — two curves would drift.
    private func updateCrowd() {
        guard !finished, let overs else { return }
        let gain = CricketSound.bedGain(
            target: target,
            scored: humanBatting ? humanScore : botScore,
            ballsBowled: ballsBowled,
            ballsTotal: overs * ballsPerOver)
        GameAudio.shared.startLoop("crowd_base", gain: gain)
    }

    private func finish(_ won: Bool?) {
        finished = true
        humanWon = won
        CricketSound.stopBed()
        // A tie (won == nil) gets the losing treatment: nobody chased it down.
        CricketSound.matchEnd(won: won == true)
        if won == true { Haptics.boundary() } else { Haptics.rigid() }
        if !recorded {
            BotScoreStore.add(level, outcome: won == true ? 1 : (won == false ? -1 : 0))
            recorded = true
        }
    }

    private func restart() {
        innings = 1; humanBatting = true
        humanScore = 0; botScore = 0
        humanWickets = 0; botWickets = 0
        ballsBowled = 0; target = nil
        lastEvent = nil; humanPick = nil; botPick = nil
        resolving = false; finished = false; humanWon = nil
        paused = false; recorded = false
        humanBatHistory = []; humanBowlHistory = []
        // The toss is part of a match, so a new match gets a new one. Without this a rematch
        // would inherit the last toss and walk straight into play with the old sides.
        tossPhase = "toss-call"; tossCoin = ""; tossCalled = nil; tossWonByHuman = false
        humanBatting = true
        overs = nil
    }
}
