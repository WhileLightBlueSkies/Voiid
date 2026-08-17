//
//  RpsBotView.swift
//  Voiid
//
//  Rock Paper Scissors against the local bot. Best of 3, matching the server engine's
//  default so the online and offline games are the same game.
//
//  THE SHAKE IS NOT DECORATION: both hands shake together for a beat before revealing,
//  which is what makes a simultaneous game feel simultaneous. Without it the bot's throw
//  would simply appear next to yours and it would look like it answered you — the same
//  perception problem the online engine solves by hiding throws until both are in.
//
//  Mirrors Android `RpsBotScreen.kt`.
//

import SwiftUI

struct RpsBotView: View {
    let level: BotDifficulty
    let skill: Double
    var onClose: (() -> Void)?

    private static let target = 3

    @State private var myWins = 0
    @State private var botWins = 0
    @State private var myThrow: Int?
    @State private var botThrow: Int?
    @State private var revealing = false
    @State private var paused = false
    @State private var history: [Int] = []
    @State private var recorded = false
    /// Drives the shake oscillation; flipped repeatedly while a round resolves.
    @State private var shakeUp = false

    /// The three fist-pump beats rise slightly in pitch, so the wind-up climbs toward the
    /// reveal instead of repeating. Identical on Android.
    static let pumpPitches: [Float] = [0.94, 1.0, 1.08]

    @EnvironmentObject var session: AppSession

    private var matchOver: Bool { myWins >= Self.target || botWins >= Self.target }

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            VStack(spacing: 0) {
                header
                scoreRow
                hands
                statusText
                controls
                Spacer()
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, VoiidSpacing.md)

            if paused { pauseOverlay }
        }
        // THE HANDS STAY VISIBLE BEHIND THE VERDICT (§9.2).
        .overlay {
            if matchOver {
                MatchEndOverlay(
                    result: botResult(),
                    onPlayAgain: { restart() },
                    onExit: { onClose?() })
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: paused)
        .onAppear {
            session.hideTabBar = true
            GameAudio.shared.preload(for: "rps")
        }
        .onDisappear {
            session.hideTabBar = false
            GameAudio.shared.release(for: "rps")
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
            Button {
                Haptics.tap()
                paused = true
            } label: {
                Image(systemName: "pause.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .padding(VoiidSpacing.sm)
            }
            .disabled(matchOver)
            .accessibilityLabel("Pause")
        }
        .padding(.bottom, VoiidSpacing.lg)
    }

    private var scoreRow: some View {
        HStack {
            scorePill("You", myWins)
            Spacer()
            Text("first to \(Self.target)")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
            Spacer()
            scorePill("Bot", botWins)
        }
        .padding(.bottom, VoiidSpacing.lg)
    }

    private func scorePill(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(VoiidFont.rounded(26, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                // The number pops on change, so a won round registers without reading text.
                .scaleEffect(1)
                .animation(.spring(response: 0.3, dampingFraction: 0.35), value: value)
            Text(label)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private var hands: some View {
        HStack(spacing: VoiidSpacing.md) {
            hand(myThrow, mirrored: false)
            hand(botThrow, mirrored: true)
        }
    }

    /// One hand, drawn from the rig rather than as a glyph (§3).
    ///
    /// THE POSE IS THE ANIMATION. During the pumps the fingers hold `neutral` and the FOREARM
    /// swings; on the third downstroke the curls interpolate to the thrown pose over 130 ms,
    /// so the fingers are visibly seen to form the shape. An emoji could only ever cut.
    private func hand(_ throwIdx: Int?, mirrored: Bool) -> some View {
        // The forearm swings; the wrist follows it a beat later. That lag is the single detail
        // that makes the pump look human (§3.5).
        let forearm: Double = revealing ? (shakeUp ? HandRig.pumpUp : HandRig.pumpDown) : 0
        let wrist: Double = forearm * 0.72

        // Fingers stay neutral through the wind-up and tighten slightly on each pump — the hand
        // gathering itself — then snap to the throw when `revealing` ends.
        let pose: HandRig.Pose = revealing
            ? HandRig.Pose.lerp(HandRig.neutral, HandRig.rock, shakeUp ? 0.10 : 0.02)
            : HandRig.pose(for: throwIdx)

        let popping = !revealing && throwIdx == 0

        return ZStack {
            // A lit panel rather than a flat card: the radial fall-off reads as a spotlit arena,
            // which is what makes two hands feel like a face-off instead of a list.
            RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(RadialGradient(
                    colors: [VoiidColor.primary.opacity(0.20), VoiidColor.surfaceCard],
                    center: .center, startRadius: 4, endRadius: 130))
                .aspectRatio(1, contentMode: .fit)

            HandView(
                pose: pose,
                forearm: forearm,
                wrist: wrist,
                mirrored: mirrored,
                knucklePop: popping ? HandRig.rockKnucklePop : 1)
                .aspectRatio(1, contentMode: .fit)
                .padding(VoiidSpacing.sm)
                // Two springs, deliberately different: the pump is fast and loose so it reads
                // as a shake, the reveal is a tighter settle so the shape lands.
                .animation(.spring(response: 0.16, dampingFraction: 0.42), value: shakeUp)
                .animation(.spring(response: HandRig.revealDuration * 1.4,
                                   dampingFraction: 0.55), value: throwIdx)
                .animation(.easeOut(duration: 0.12), value: revealing)
        }
    }

    private var statusText: some View {
        let text: String = {
            if matchOver { return myWins > botWins ? "You win the match" : "Bot wins the match" }
            if revealing { return "Shoot!" }
            if let m = myThrow, let b = botThrow {
                switch RpsBot.compare(m, b) {
                case 1:  return "You win the round"
                case -1: return "Bot wins the round"
                default: return "Tie"
                }
            }
            return "Pick your throw"
        }()

        return Text(text)
            .font(VoiidFont.rounded(18, .bold))
            .foregroundStyle(matchOver ? VoiidColor.primary : VoiidColor.textSecondary)
            .padding(.vertical, VoiidSpacing.lg)
            .scaleEffect(matchOver ? 1.15 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.4), value: matchOver)
            .accessibilityAddTraits(.updatesFrequently)
    }

    @ViewBuilder
    private var controls: some View {
        // The record card and the buttons moved into MatchEndOverlay (§9.3) — one end screen
        // for all six games rather than a bespoke panel per game.
        if !matchOver {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(0..<3, id: \.self) { i in
                    Button {
                        Haptics.tap()
                        throwHand(i)
                    } label: {
                        Text(RpsBot.emoji(i))
                            .font(.system(size: 30))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoiidSpacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: VoiidRadius.lg)
                                    .fill(myThrow == i && !revealing ? VoiidColor.primary : VoiidColor.fieldFill)
                            )
                            .scaleEffect(myThrow == i && !revealing ? 1.08 : 1)
                    }
                    .buttonStyle(.plain)
                    .disabled(revealing || paused)
                }
            }
            .animation(.spring(response: 0.3, dampingFraction: 0.45), value: myThrow)
        }
    }

    private func stat(_ label: String, _ value: Int) -> some View {
        VStack(spacing: 2) {
            Text("\(value)")
                .font(VoiidFont.rounded(20, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text(label)
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    private func pill(_ text: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(VoiidFont.rounded(14, .semibold))
                .foregroundStyle(filled ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(Capsule().fill(filled ? VoiidColor.primary : VoiidColor.fieldFill))
        }
        .buttonStyle(.plain)
    }

    private var pauseOverlay: some View {
        ZStack {
            VoiidColor.background.opacity(0.94).ignoresSafeArea()
                .onTapGesture { }
            VStack(spacing: VoiidSpacing.sm) {
                Text("Paused")
                    .font(VoiidFont.rounded(26, .bold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .padding(.bottom, VoiidSpacing.md)
                menuButton("Resume", icon: "play.fill", filled: true) { paused = false }
                menuButton("Restart", icon: "arrow.clockwise", filled: false) { restart() }
                menuButton("Give up", icon: "flag", filled: false, danger: true) {
                    if !recorded { BotScoreStore.add(level, outcome: -1); recorded = true }
                    onClose?()
                }
            }
            .padding(.horizontal, VoiidSpacing.xl)
        }
    }

    private func menuButton(_ text: String, icon: String, filled: Bool,
                            danger: Bool = false, action: @escaping () -> Void) -> some View {
        let fg = filled ? VoiidColor.textOnPrimary : (danger ? VoiidColor.error : VoiidColor.textPrimary)
        return Button {
            Haptics.tap()
            action()
        } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                Text(text).font(VoiidFont.rounded(15, .semibold))
            }
            .foregroundStyle(fg)
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.md)
            .background(Capsule().fill(filled ? VoiidColor.primary : VoiidColor.fieldFill))
        }
        .buttonStyle(.plain)
    }

    // MARK: - The result

    /// Built from local match state — a practice match never reaches the backend, so the
    /// record comes from BotScoreStore exactly as the old inline panel read it.
    private func botResult() -> MatchEndResult {
        let record = BotScoreStore.record(level)
        let counts = history.reduce(into: [Int: Int]()) { acc, throwIdx in
            acc[throwIdx, default: 0] += 1
        }
        let mostThrown = counts.max(by: { $0.value < $1.value }).map { idx, n in
            "\(RpsBot.emoji(idx)) x\(n)"
        }
        return .rps(
            mine: myWins,
            theirs: botWins,
            mostThrown: mostThrown,
            record: "\(record.wins)W \(record.draws)D \(record.losses)L")
    }

    // MARK: - Logic

    private func throwHand(_ choice: Int) {
        guard !revealing, !matchOver, !paused else { return }
        myThrow = choice
        botThrow = nil
        revealing = true

        Task {
            // Shake for a beat, oscillating, then reveal. The elapsed time is the point —
            // resolving in the same frame as the tap would look like the bot answered you.
            // The shake is SILENT no longer. Every other beat is a fist-pump whoosh, rising in
            // pitch across the three — the sound of the hand actually moving, which is what
            // makes the wait read as a wind-up rather than as latency (SOUND_DESIGN.md §4.4).
            for i in 0..<6 {
                try? await Task.sleep(nanoseconds: 110_000_000)
                shakeUp.toggle()
                if i % 2 == 0 {
                    GameAudio.shared.play("hand_pump",
                                          pitch: Self.pumpPitches[i / 2], gain: 0.5)
                }
            }
            guard !paused else { revealing = false; return }

            let theirs = RpsBot.chooseThrow(history: history, skill: skill)
            botThrow = theirs
            GameAudio.shared.play("hand_reveal", gain: 0.7)
            // Graded by outcome, so a win and a loss don't feel identical: a won round gets the
            // rising thump, a lost one a blunt knock, a tie a light tick.
            switch RpsBot.compare(choice, theirs) {
            case 1:  myWins += 1; Haptics.boundary(); GameAudio.shared.play("round_win", gain: 0.65)
            case -1:
                botWins += 1
                Haptics.rigid()
                GameAudio.shared.play("round_lose", gain: 0.65)
                // THE SHARED SOUND (§3): your throw was COUNTERED.
                GameAudio.shared.play(GameAudio.catchShared, gain: 0.5)
            default: Haptics.tap(); GameAudio.shared.play("round_tie", gain: 0.5)
            }
            // Recorded AFTER resolving, so the model never sees the throw it is predicting.
            history.append(choice)
            revealing = false

            if !recorded, myWins >= Self.target || botWins >= Self.target {
                BotScoreStore.add(level, outcome: myWins > botWins ? 1 : -1)
                recorded = true
            }
        }
    }

    private func restart() {
        myWins = 0
        botWins = 0
        myThrow = nil
        botThrow = nil
        revealing = false
        paused = false
        recorded = false
        history.removeAll()
    }
}
