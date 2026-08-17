//
//  MatchEndOverlay.swift
//  Voiid
//
//  The win / defeat / tie screen, shared by every game
//  (docs/games/VISUALS_AUDIO_AND_PARITY.md §9).
//
//  WHAT THIS REPLACES. Five of six games ended with a line of text next to a Rematch button;
//  Snake had a panel reading "You finished with 47". The match is where the story is, and it
//  was discarded at the moment it was most interesting (CROSS_CUTTING.md §2).
//
//  THE RULE THE WHOLE THING IS BUILT ON (§9.2):
//
//      The board finishes its sentence before the verdict speaks.
//
//  Tic Tac Toe already did this — the win stroke draws, THEN the verdict appears — and it was
//  the only game that did. Everywhere else the result overwrote its own cause: a ship sank and
//  "You win" appeared in the same frame, so the player never saw the ship go down. Hence
//  `holdBeforeScrim`: 450 ms in which nothing moves and the player reads the board.
//
//  AND THE BOARD IS NEVER CLEARED. The scrim dims it to 25% and sits on top. Being able to see
//  the final board while reading the verdict is the difference between a result and a receipt.
//
//  Mirrors Android `MatchEndOverlay.kt`. The timings below are a parity surface.
//

import SwiftUI

struct MatchEndOverlay: View {
    let result: MatchEndResult
    /// Online: mint a rematch. Nil hides the button — a caller that cannot navigate to a new
    /// match must not offer one.
    var matchId: String?
    var onRematch: ((String) -> Void)?
    /// Practice: a local reset, which needs no server. Nil hides it.
    var onPlayAgain: (() -> Void)?
    var onExit: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - The beat table (§9.4)
    //
    // Times are from the moment the FINAL GAME EVENT finishes, not from the state change. A
    // defeat runs the same beats compressed by `outcome.sequenceScale`.

    /// The most important number here. Nothing moves; the player reads the board and
    /// understands WHY before being told WHAT.
    private static let holdBeforeScrim: Double = 0.45
    private static let scrimFade: Double = 0.26
    private static let verdictAt: Double = 0.56
    private static let statsAt: Double = 0.76
    private static let statStagger: Double = 0.06
    private static let actionsAt: Double = 1.10
    private static let flourishAt: Double = 1.25

    @State private var phase = 0          // 0 hidden, 1 scrim, 2 verdict, 3 stats, 4 actions
    @State private var confetti = false
    @State private var shareItem: ShareText?
    @State private var requestingRematch = false
    @State private var rematchFailure: String?

    private let api = GamesAPI()

    private var scale: Double { result.outcome.sequenceScale }

    var body: some View {
        ZStack {
            // THE BOARD STAYS VISIBLE BEHIND THIS. Never a black screen — a dim, not a curtain.
            scrim
                .opacity(phase >= 1 ? 1 : 0)
                .animation(reduceMotion ? nil : .easeOut(duration: Self.scrimFade), value: phase)

            VStack(spacing: VoiidSpacing.md) {
                Spacer()
                verdict
                if !result.stats.isEmpty { statsPanel }
                Spacer()
                actions
            }
            .padding(.horizontal, VoiidSpacing.xl)
            .padding(.bottom, VoiidSpacing.xl)

            if confetti && !reduceMotion {
                ConfettiBurst(color: result.accent)
                    .allowsHitTesting(false)
            }
        }
        // TAPPING SKIPS TO THE END STATE. Never trap a player in a celebration.
        .contentShape(Rectangle())
        .onTapGesture { skipToEnd() }
        .task { await runSequence() }
        .sheet(item: $shareItem) { item in
            ActivityView(text: item.text)
        }
        // VoiceOver reads the verdict as a header, and the overlay's arrival posts a screen
        // change so the result is announced rather than hunted for.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(result.title)
    }

    // MARK: - Sequence

    private func runSequence() async {
        // Under reduce-motion the overlay is simply THERE, fully formed. Not the animation
        // played faster — the animation not happening (§9.10).
        if reduceMotion {
            phase = 4
            playSound()
            playHaptic()
            return
        }

        try? await sleep(Self.holdBeforeScrim)
        withAnimation { phase = 1 }

        try? await sleep((Self.verdictAt - Self.holdBeforeScrim) * scale)
        // Verdict, sound and haptic land on the SAME frame.
        withAnimation(verdictSpring) { phase = 2 }
        playSound()
        playHaptic()

        try? await sleep((Self.statsAt - Self.verdictAt) * scale)
        withAnimation(.easeOut(duration: 0.22)) { phase = 3 }

        try? await sleep((Self.actionsAt - Self.statsAt) * scale)
        withAnimation(.easeOut(duration: 0.26)) { phase = 4 }

        // A win, and only a genuine one, gets the flourish.
        if result.outcome == .win && !result.hollow {
            try? await sleep((Self.flourishAt - Self.actionsAt) * scale)
            confetti = true
        }
    }

    private func skipToEnd() {
        guard phase < 4 else { return }
        withAnimation(.easeOut(duration: 0.15)) { phase = 4 }
    }

    private func sleep(_ seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
    }

    /// A win scales UP and overshoots; a defeat scales DOWN and settles like a weight, with no
    /// overshoot at all; a tie meets in the middle. Direction is the whole design (§9.5).
    private var verdictSpring: Animation {
        switch result.outcome {
        case .win:  return .spring(response: 0.42, dampingFraction: 0.55)
        case .lose: return .easeOut(duration: 0.32)
        case .tie:  return .spring(response: 0.38, dampingFraction: 0.85)
        }
    }

    private func playSound() {
        // A hollow win — one taken by resignation or timeout — gets the stinger at half gain.
        // Winning because somebody left is not a victory (§9.7).
        GameAudio.shared.play(result.outcome.sound, gain: result.hollow ? 0.5 : 0.85)
    }

    private func playHaptic() {
        switch result.outcome {
        case .win:
            guard !result.hollow else { Haptics.tap(); return }
            Haptics.success()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { Haptics.boundary() }
        case .lose:
            // One thud. Not a sequence — a defeat gets less (§9.5).
            Haptics.rigid()
        case .tie:
            Haptics.soft()
        }
    }

    // MARK: - Pieces

    private var scrim: some View {
        Group {
            switch result.outcome {
            case .win:
                // Tinted with the game's accent, so the overlay belongs to the board behind it.
                LinearGradient(
                    colors: [result.accent.opacity(0.34), VoiidColor.background.opacity(0.82)],
                    startPoint: .top, endPoint: .bottom)
                    .opacity(0.72 / 0.72)
            case .lose:
                Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.80)
            case .tie:
                VoiidColor.background.opacity(0.76)
            }
        }
        .ignoresSafeArea()
    }

    private var verdict: some View {
        let shown = phase >= 2
        // Win rises into place, defeat settles down onto it, tie arrives level.
        let entrance: CGFloat = {
            switch result.outcome {
            case .win:  return shown ? 1.0 : 0.70
            case .lose: return shown ? 1.0 : 1.25
            case .tie:  return shown ? 1.0 : 0.94
            }
        }()

        return VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: result.outcome.symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(verdictColor)

            Text(result.title)
                .font(.system(size: 34, weight: .black))
                .foregroundStyle(verdictColor)
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)

            if let detail = result.detail {
                Text(detail)
                    .font(VoiidFont.rounded(14, .medium))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .scaleEffect(entrance)
        .opacity(shown ? 1 : 0)
        // Everything on a defeat settles DOWNWARD; a win rises.
        .offset(y: shown ? 0 : (result.outcome == .lose ? -10 : 14))
    }

    private var verdictColor: Color {
        switch result.outcome {
        case .win:  return result.hollow ? VoiidColor.textPrimary : result.accent
        case .lose: return VoiidColor.textSecondary
        case .tie:  return VoiidColor.textPrimary
        }
    }

    private var statsPanel: some View {
        VStack(spacing: 0) {
            ForEach(Array(result.stats.enumerated()), id: \.element.id) { index, stat in
                let shown = phase >= 3
                HStack {
                    Text(stat.label)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                    Spacer()
                    Text(stat.value)
                        .font(VoiidFont.rounded(17, .bold))
                        .foregroundStyle(stat.highlight ? result.accent : VoiidColor.textPrimary)
                }
                .padding(.vertical, VoiidSpacing.sm)
                .opacity(shown ? 1 : 0)
                .offset(y: shown ? 0 : 12)
                .animation(
                    reduceMotion ? nil
                        : .easeOut(duration: 0.22)
                            .delay(Double(index) * Self.statStagger * scale),
                    value: phase)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(stat.label), \(stat.value)")

                if index < result.stats.count - 1 {
                    Divider().overlay(VoiidColor.textSecondary.opacity(0.15))
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(VoiidColor.surfaceCard.opacity(0.92)))
    }

    @ViewBuilder
    private var actions: some View {
        let shown = phase >= 4
        VStack(spacing: VoiidSpacing.sm) {
            if let rematchFailure {
                Text(rematchFailure)
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
            }

            HStack(spacing: VoiidSpacing.sm) {
                if onPlayAgain != nil {
                    pill("Play again", filled: true) { onPlayAgain?() }
                } else if matchId != nil {
                    pill(requestingRematch ? "…" : "Rematch", filled: true) { requestRematch() }
                }
                pill("Exit", filled: false) { onExit() }
            }

            // SHARE, IN EVERY GAME — this app is a messenger and a result that can be dropped
            // into the chat it was arranged in is its one structural advantage over a
            // standalone game (CROSS_CUTTING.md §2). ON A LOSS THERE IS NO SHARE BUTTON:
            // nobody shares a loss, and offering it reads as a joke at the player's expense.
            if let text = result.shareText, result.outcome != .lose, !result.hollow {
                Button {
                    Haptics.tap()
                    shareItem = ShareText(text: text)
                } label: {
                    Label("Challenge a friend", systemImage: "square.and.arrow.up")
                        .font(VoiidFont.rounded(14, .semibold))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .buttonStyle(.plain)
            }
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown ? 0 : 18)
    }

    private func pill(_ text: String, filled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            Text(text)
                .font(VoiidFont.rounded(15, filled ? .bold : .semibold))
                .foregroundStyle(filled ? VoiidColor.textOnPrimary : VoiidColor.textPrimary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.md)
                .background(Capsule().fill(filled ? result.accent : VoiidColor.fieldFill))
        }
        .buttonStyle(.plain)
        .disabled(requestingRematch)
    }

    /// Mints a NEW match rather than reopening the finished one — the old row holds a result the
    /// leaderboard already counted. Same logic RematchBar carried, moved rather than rewritten.
    private func requestRematch() {
        guard let matchId, !requestingRematch else { return }
        requestingRematch = true
        rematchFailure = nil
        Task {
            do {
                let res = try await api.rematch(matchId: matchId)
                requestingRematch = false
                onRematch?(res.match_id)
            } catch {
                requestingRematch = false
                // DELIBERATELY VAGUE, and deliberately not the server's message: the route
                // returns 403 without naming which player failed so it cannot be used to probe
                // whether a user id exists. "Could not start" covers blocked, deleted and
                // offline alike, which is all the player can act on anyway.
                withAnimation { rematchFailure = "Couldn't start a rematch. They may have left." }
            }
        }
    }
}

/// Wraps a string so `.sheet(item:)` can key off it.
private struct ShareText: Identifiable {
    let text: String
    var id: String { text }
}

/// The ordinary system share sheet, rather than a bespoke flow, so a result can go to any
/// conversation the player already has.
private struct ActivityView: UIViewControllerRepresentable {
    let text: String

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [text], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 24 pieces of paper under gravity. Win only, never a defeat (§9.5).
///
/// Hand-drawn rather than a particle system: this runs for 1.4 s once per match, and a
/// `TimelineView` over 24 rects costs nothing next to pulling in a dependency.
private struct ConfettiBurst: View {
    let color: Color

    private static let count = 24
    private static let life: Double = 1.4
    private static let gravity: Double = 900

    @State private var start = Date()

    /// Seeded per index so the burst is deterministic within a run and does not re-randomise on
    /// every recomposition — a burst that reshuffles mid-flight reads as flicker.
    private func seed(_ i: Int, _ salt: Int) -> Double {
        let x = sin(Double(i) * 12.9898 + Double(salt) * 78.233) * 43758.5453
        return x - x.rounded(.down)
    }

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSince(start)
                Canvas { ctx, size in
                    guard t < Self.life else { return }
                    for i in 0..<Self.count {
                        let angle = (seed(i, 1) * 1.6 - 0.8) - .pi / 2
                        let speed = 420 + seed(i, 2) * 380
                        let vx = cos(angle) * speed
                        let vy = sin(angle) * speed
                        let x = size.width / 2 + vx * t
                        let y = size.height * 0.42 + vy * t + 0.5 * Self.gravity * t * t
                        guard y < size.height + 20 else { continue }

                        let fade = max(0, 1 - t / Self.life)
                        let spin = t * (3 + seed(i, 3) * 6)
                        let w = 6 + seed(i, 4) * 5
                        let h = 9 + seed(i, 5) * 6

                        var piece = ctx
                        piece.translateBy(x: x, y: y)
                        piece.rotate(by: .radians(spin))
                        piece.opacity = fade
                        piece.fill(
                            Path(CGRect(x: -w / 2, y: -h / 2, width: w, height: h)),
                            with: .color(seed(i, 6) > 0.5 ? color : color.opacity(0.62)))
                    }
                }
            }
        }
        .onAppear { start = Date() }
    }
}
