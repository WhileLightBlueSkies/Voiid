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
        .animation(.easeInOut(duration: 0.18), value: paused)
        .onAppear { session.hideTabBar = true }
        .onDisappear { session.hideTabBar = false }
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

    private func hand(_ throwIdx: Int?, mirrored: Bool) -> some View {
        let tilt: Double = revealing ? (shakeUp ? 18 : -18) : 0
        return ZStack {
            // A lit panel rather than a flat card: the radial fall-off reads as a spotlit arena,
            // which is what makes two emoji feel like a face-off instead of a list.
            RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(RadialGradient(
                    colors: [VoiidColor.primary.opacity(0.20), VoiidColor.surfaceCard],
                    center: .center, startRadius: 4, endRadius: 130))
                .aspectRatio(1, contentMode: .fit)
            Text(RpsBot.emoji(revealing ? nil : throwIdx))
                .font(.system(size: 56))
                .rotationEffect(.degrees(mirrored ? -tilt : tilt))
                .scaleEffect(throwIdx != nil && !revealing ? 1 : 0.82)
                .animation(.spring(response: 0.18, dampingFraction: 0.35), value: shakeUp)
                .animation(.spring(response: 0.35, dampingFraction: 0.42), value: throwIdx)
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
        if matchOver {
            let record = BotScoreStore.record(level)
            VStack(spacing: VoiidSpacing.sm) {
                // Running record, shown at the moment it means something.
                HStack {
                    stat("Won", record.wins)
                    Spacer()
                    stat("Drawn", record.draws)
                    Spacer()
                    stat("Lost", record.losses)
                }
                .padding(VoiidSpacing.md)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))

                HStack(spacing: VoiidSpacing.sm) {
                    pill("Play again", filled: true) { restart() }
                    pill("Exit", filled: false) { onClose?() }
                }
            }
            .transition(.scale(scale: 0.85).combined(with: .opacity))
        } else {
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

    // MARK: - Logic

    private func throwHand(_ choice: Int) {
        guard !revealing, !matchOver, !paused else { return }
        myThrow = choice
        botThrow = nil
        revealing = true

        Task {
            // Shake for a beat, oscillating, then reveal. The elapsed time is the point —
            // resolving in the same frame as the tap would look like the bot answered you.
            for _ in 0..<6 {
                try? await Task.sleep(nanoseconds: 110_000_000)
                shakeUp.toggle()
            }
            guard !paused else { revealing = false; return }

            let theirs = RpsBot.chooseThrow(history: history, skill: skill)
            botThrow = theirs
            // Graded by outcome, so a win and a loss don't feel identical: a won round gets the
            // rising thump, a lost one a blunt knock, a tie a light tick.
            switch RpsBot.compare(choice, theirs) {
            case 1:  myWins += 1; Haptics.boundary()
            case -1: botWins += 1; Haptics.rigid()
            default: Haptics.tap()
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
