//
//  TicTacToeBotView.swift
//  Voiid
//
//  Practice against the local bot. No server, no match row, no connection needed.
//
//  Difficulty arrives already chosen from GameSetupSheet and is LOCKED for the match —
//  a record of "beat the hard bot" is worthless if it could be lowered mid-game. To change
//  it you leave and start again, which is exactly the honest cost.
//
//  Mirrors Android `TicTacToeBotScreen.kt`.
//

import SwiftUI

struct TicTacToeBotView: View {
    let level: BotDifficulty
    let skill: Double
    var onClose: (() -> Void)?

    @StateObject private var match = TicTacToeBotMatch()
    @EnvironmentObject var session: AppSession

    /// The result line and the record panel wait for the win stroke to finish drawing
    /// (TICTACTOE_WIN_LINE.md §2.2: the banner is the last beat, not the first). A draw has no
    /// stroke to wait for, so it reveals immediately.
    @State private var resultRevealed = false

    var body: some View {
        ZStack {
            VoiidColor.background.ignoresSafeArea()

            playBoard

            if match.paused { pauseOverlay }
        }
        .animation(.easeInOut(duration: 0.18), value: match.paused)
        .onAppear {
            session.hideTabBar = true
            // Difficulty is fixed for this screen's lifetime; configure once.
            match.configure(level: level, skill: skill)
            GameAudio.shared.preload(for: "tictactoe")
        }
        .onDisappear {
            session.hideTabBar = false
            GameAudio.shared.release(for: "tictactoe")
        }
        // Mark placed — same board-diff approach as the online TicTacToeView, so a bot
        // move and a human move sound identical (the player should not be able to tell
        // which one just played from the sound alone).
        .onChange(of: match.board) { oldBoard, newBoard in
            TicTacToeSound.boardChanged(
                from: oldBoard, to: newBoard, mySeat: TicTacToeBotMatch.humanSeat)
        }
        // A WIN'S SOUND IS NOT PLAYED HERE. `win_line` belongs to the stroke that draws it and
        // fires from TicTacToeBoard on the same beat the stroke starts — 120 ms after the mark
        // lands, not on this state change. A draw has no stroke, so it keeps its sound here.
        .onChange(of: match.finished) { _, finished in
            guard finished else { resultRevealed = false; return }
            if match.winnerSeat == nil {
                GameAudio.shared.play("chalk_erase", gain: 0.55)
                withAnimation { resultRevealed = true }
            }
        }
    }

    // MARK: - Board

    private var playBoard: some View {
        VStack(spacing: 0) {
            // Difficulty is locked, so it is a label here, not a control.
            HStack {
                Text(match.level.label)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(VoiidColor.fieldFill))
                Spacer()
                Button {
                    Haptics.tap()
                    match.paused = true
                } label: {
                    Image(systemName: "pause.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .padding(VoiidSpacing.sm)
                }
                .disabled(match.finished)
                .accessibilityLabel("Pause")
            }
            .padding(.bottom, VoiidSpacing.lg)

            TicTacToeBoard(
                board: match.board,
                line: match.line,
                isDraw: match.finished && match.winnerSeat == nil,
                enabled: match.canPlay,
                onTap: { match.play(cell: $0) },
                onLineComplete: { withAnimation { resultRevealed = true } }
            )
            .animation(.spring(response: 0.35, dampingFraction: 0.55), value: match.board)

            statusLine

            if match.finished && resultRevealed {
                let record = BotScoreStore.record(level)
                VStack(spacing: VoiidSpacing.sm) {
                    // Running record at this difficulty, shown after a result — the moment
                    // it means something.
                    HStack {
                        stat("Won", record.wins)
                        Spacer()
                        stat("Drawn", record.draws)
                        Spacer()
                        stat("Lost", record.losses)
                    }
                    .padding(VoiidSpacing.md)
                    .background(RoundedRectangle(cornerRadius: VoiidRadius.lg)
                        .fill(VoiidColor.surfaceCard))

                    HStack(spacing: VoiidSpacing.sm) {
                        pill("Play again", filled: true) {
                            Haptics.tap()
                            withAnimation { match.restart() }
                        }
                        pill("Exit", filled: false) { onClose?() }
                    }
                }
                .padding(.top, VoiidSpacing.lg)
                .transition(.scale(scale: 0.85).combined(with: .opacity))
            }

            Spacer()
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.md)
        .animation(.spring(response: 0.4, dampingFraction: 0.6), value: resultRevealed)
    }

    private var statusLine: some View {
        // `settled` rather than `match.finished`: the result is announced once the win stroke
        // has been drawn, so the player reads the line and then the verdict instead of both at
        // once. Until then the last in-play status holds.
        let settled = match.finished && resultRevealed
        let text: String = {
            if settled {
                guard let w = match.winnerSeat else { return "Dead heat — nobody could force it" }
                return w == TicTacToeBotMatch.humanSeat ? "You win" : "Bot wins"
            }
            return match.botThinking ? "Bot is thinking…" : "Your turn"
        }()

        return Text(text)
            .font(VoiidFont.rounded(18, .bold))
            .foregroundStyle(settled ? VoiidColor.primary : VoiidColor.textSecondary)
            .padding(.top, VoiidSpacing.lg)
            // The result pops rather than appearing, so a win feels like an event.
            .scaleEffect(settled ? 1.15 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.4), value: settled)
            .accessibilityAddTraits(.updatesFrequently)
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

    // MARK: - Pause

    /// A scrim over the board rather than a separate screen, so the game is visibly still
    /// there — a pause that hides the board reads as having quit.
    private var pauseOverlay: some View {
        ZStack {
            VoiidColor.background.opacity(0.94).ignoresSafeArea()
                .onTapGesture { }   // swallow taps so the board can't be played while paused

            VStack(spacing: VoiidSpacing.sm) {
                Text("Paused")
                    .font(VoiidFont.rounded(26, .bold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .padding(.bottom, VoiidSpacing.md)

                menuButton("Resume", icon: "play.fill", filled: true) {
                    match.paused = false
                }
                menuButton("Restart", icon: "arrow.clockwise", filled: false) {
                    withAnimation { match.restart() }
                }
                menuButton("Give up", icon: "flag", filled: false, danger: true) {
                    match.giveUp()
                    match.paused = false
                }
            }
            .padding(.horizontal, VoiidSpacing.xl)
            .transition(.scale(scale: 0.9).combined(with: .opacity))
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
}
