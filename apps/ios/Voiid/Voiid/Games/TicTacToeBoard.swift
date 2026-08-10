//
//  TicTacToeBoard.swift
//  Voiid
//
//  The 3x3 board, shared by the online game (server state) and the bot game (local state).
//
//  Extracted so the two modes cannot drift visually. It takes plain values, not an engine:
//  it has no idea whether the marks came from a server frame or a minimax search, which is
//  exactly the point — one board, two callers.
//
//  Marks are STROKED PATHS, not SF Symbols: a drawn X/O scales cleanly with the cell and
//  can animate its stroke on, which a font glyph cannot.
//
//  THE BOARD OWNS THE END-OF-MATCH BEATS, not its callers (docs/games/TICTACTOE_WIN_LINE.md
//  §2.2). The win line, the swell of the winning cells, the success haptic and the win sound
//  all have to land in a specific order a fifth of a second apart, and a sequence split across
//  two screens is a sequence that drifts. Callers hand over `line` and are told when the
//  gesture has finished, via `onLineComplete`.
//
//  Mirrors Android `TicTacToeBoard.kt`.
//

import SwiftUI

struct TicTacToeBoard: View {
    /// 9 cells, row-major. Each is the seat index that owns it, or nil.
    let board: [Int?]
    /// Winning triple to strike through, if the game is won.
    let line: [Int]?
    /// The match ended with no winner. Drives the draw treatment (§2.3) — deliberately a
    /// separate input rather than "finished && line == nil", because the board cannot see
    /// `finished` and guessing a draw from an absent line would treat every match in progress
    /// as a draw.
    var isDraw: Bool = false
    /// False when taps should be ignored (not your turn, game over, paused).
    let enabled: Bool
    let onTap: (Int) -> Void
    /// Fired when the win stroke has finished drawing — the cue for a caller to reveal its
    /// result panel, so the banner does not land on top of the gesture that explains it.
    var onLineComplete: (() -> Void)?

    /// Reduce-motion draws the line at full length instantly (§2.5). The colour, the sound and
    /// the haptic all survive; only the stroke animation is dropped. The information is the
    /// point — the motion was only ever how it was delivered.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// How much of the win stroke is drawn, 0-1. Animated via `.trim`.
    @State private var strokeProgress: CGFloat = 0
    /// The winning cells swell only once the stroke has landed — it is the payoff now, not
    /// the whole event.
    @State private var swelled = false
    /// Every cell dims together on a draw.
    @State private var drawFaded = false

    // MARK: Timing and geometry (TICTACTOE_WIN_LINE.md §2.1-2.2)
    //
    // KEEP IDENTICAL TO ANDROID. Divergence here is how two ports of one feature end up
    // feeling like different games.

    /// Let the player SEE the third mark before it is annotated. Firing the line on the same
    /// frame as the winning mark makes the two read as one blurred event, and the player never
    /// registers which move won. This is the most important number in the file.
    private static let hold: Double = 0.12
    /// Long enough to read as a deliberate stroke, short enough not to delay the result.
    private static let strokeDuration: Double = 0.34
    /// Extend past the outer two centres by this fraction of a cell, so the line visibly
    /// strikes THROUGH the row rather than connecting two dots. Matters most on the diagonals,
    /// where the un-extended line is visually shortest relative to what it crosses.
    private static let overshoot: CGFloat = 0.35
    /// The line must dominate the marks it crosses, not match them.
    private static let markStrokeWidth: CGFloat = 9
    private static let lineStrokeWidth: CGFloat = markStrokeWidth * 1.4
    private static let drawFadeDuration: Double = 0.30

    var body: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: VoiidSpacing.sm) {
                    ForEach(0..<3, id: \.self) { col in
                        cell(row * 3 + col)
                    }
                }
            }
        }
        // Overlaid on the GRID, so the geometry reader reports exactly the grid's frame and
        // cell centres fall out of the same spacing constant the layout above uses.
        .overlay { winLine }
        .saturation(drawFaded ? 0.15 : 1)
        .opacity(drawFaded ? 0.65 : 1)
        .onChange(of: line) { _, newLine in runWinSequence(for: newLine) }
        .onChange(of: isDraw) { _, draw in
            withAnimation(reduceMotion ? nil : .easeInOut(duration: Self.drawFadeDuration)) {
                drawFaded = draw
            }
        }
        .onAppear {
            // A board entered ALREADY WON (a rejoin, a returning screen) shows the end state
            // without replaying a gesture the player already missed — and still reports
            // completion, or a caller waiting on `onLineComplete` would wait forever for a
            // sequence that was deliberately skipped.
            if line != nil {
                strokeProgress = 1
                swelled = true
                onLineComplete?()
            }
            drawFaded = isDraw
        }
    }

    // MARK: - Win line

    @ViewBuilder
    private var winLine: some View {
        if let line, line.count == 3 {
            GeometryReader { geo in
                // Cells are square with equal gaps, so one axis defines both — deriving y from
                // the height instead would drift by a rounding error and tilt the diagonals.
                let cell = (geo.size.width - VoiidSpacing.sm * 2) / 3
                let a = Self.centre(of: line[0], cell: cell)
                let b = Self.centre(of: line[2], cell: cell)
                let (start, end) = Self.extended(from: a, to: b, cell: cell)

                WinLineShape(start: start, end: end)
                    .trim(from: 0, to: strokeProgress)
                    .stroke(
                        winnerColour,
                        style: StrokeStyle(lineWidth: Self.lineStrokeWidth, lineCap: .round)
                    )
            }
            .allowsHitTesting(false)
        }
    }

    /// The winner's own mark colour, at full saturation — so the stroke says WHO won in the
    /// same gesture that says that someone won.
    private var winnerColour: Color {
        let seat = line?.first.flatMap { board.indices.contains($0) ? board[$0] : nil }
        return seat == 0 ? VoiidColor.primary : VoiidColor.accent
    }

    private static func centre(of index: Int, cell: CGFloat) -> CGPoint {
        let col = CGFloat(index % 3), row = CGFloat(index / 3)
        return CGPoint(x: col * (cell + VoiidSpacing.sm) + cell / 2,
                       y: row * (cell + VoiidSpacing.sm) + cell / 2)
    }

    private static func extended(from a: CGPoint, to b: CGPoint, cell: CGFloat) -> (CGPoint, CGPoint) {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = max(hypot(dx, dy), 0.0001)
        let ux = dx / length, uy = dy / length
        let reach = cell * overshoot
        return (CGPoint(x: a.x - ux * reach, y: a.y - uy * reach),
                CGPoint(x: b.x + ux * reach, y: b.y + uy * reach))
    }

    /// The end-of-match sequence, in the order §2.2 specifies:
    ///
    ///     0 ms    final mark lands, mark sound plays (the caller's board diff does this)
    ///     120 ms  hold expires — stroke begins, win sound starts with it
    ///     460 ms  stroke complete, winning cells swell, success haptic
    ///     560 ms  caller reveals its result panel
    private func runWinSequence(for newLine: [Int]?) {
        guard newLine != nil else {
            strokeProgress = 0
            swelled = false
            return
        }

        guard !reduceMotion else {
            strokeProgress = 1
            swelled = true
            GameAudio.shared.play("win_line", gain: 0.7)
            Haptics.success()
            onLineComplete?()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) {
            // Sound and stroke start on the SAME beat: the scrape is the stroke, and a scrape
            // that outlasts the line reads as broken without the player knowing why.
            GameAudio.shared.play("win_line", gain: 0.7)
            withAnimation(.easeOut(duration: Self.strokeDuration)) { strokeProgress = 1 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold + Self.strokeDuration) {
            // ON COMPLETION, not on start (§2.4): the haptic is the full stop at the end of
            // the gesture, and firing it at the beginning would confirm a win the player has
            // not been shown yet.
            Haptics.success()
            withAnimation(.spring(response: 0.45, dampingFraction: 0.5)) { swelled = true }
            onLineComplete?()
        }
    }

    // MARK: - Cells

    private func cell(_ index: Int) -> some View {
        let mark = board.indices.contains(index) ? board[index] : nil
        let isWinning = line?.contains(index) ?? false
        let tappable = enabled && mark == nil

        return Button {
            Haptics.tap()
            onTap(index)
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: VoiidRadius.lg)
                    .fill(isWinning && swelled
                          ? VoiidColor.primary.opacity(0.20)
                          : VoiidColor.surfaceCard)

                if let mark {
                    MarkShape(isCross: mark == 0)
                        .stroke(
                            mark == 0 ? VoiidColor.primary : VoiidColor.accent,
                            style: StrokeStyle(lineWidth: Self.markStrokeWidth,
                                               lineCap: .round, lineJoin: .round)
                        )
                        .padding(VoiidSpacing.lg)
                        // Lands with an overshoot rather than appearing — the bouncy feel.
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                }
            }
            // SQUARE ON THE STACK, not on the background rectangle.
            //
            // With the ratio on the fill only, the rectangle was square but the ZStack was not —
            // so MarkShape sized itself to the taller stack and drew an X and an O that spilled
            // past the tile and looked stretched. Constraining the stack makes every child square.
            .aspectRatio(1, contentMode: .fit)
            // The winning triple swells — but only AFTER the stroke has been drawn, so it reads
            // as the payoff to the gesture rather than competing with it.
            .scaleEffect(isWinning && swelled ? 1.08 : 1)
        }
        .buttonStyle(.plain)
        .disabled(!tappable)
        .accessibilityLabel(label(mark: mark, index: index))
    }

    private func label(mark: Int?, index: Int) -> String {
        let position = "row \(index / 3 + 1), column \(index % 3 + 1)"
        guard let mark else { return "Empty, \(position)" }
        return "\(mark == 0 ? "X" : "O"), \(position)"
    }
}

/// The stroke through the winning triple. A plain two-point path so `.trim` animates it as a
/// line being DRAWN — a stroke that appears at full length is a graphic, a stroke that is drawn
/// is a gesture, and this is a game about marking a board by hand.
private struct WinLineShape: Shape {
    let start: CGPoint
    let end: CGPoint

    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: start)
        p.addLine(to: end)
        return p
    }
}

/// An X (two crossing strokes) or an O (a circle), drawn to fill its rect.
private struct MarkShape: Shape {
    let isCross: Bool

    func path(in rect: CGRect) -> Path {
        var p = Path()
        if isCross {
            p.move(to: CGPoint(x: rect.minX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            p.move(to: CGPoint(x: rect.maxX, y: rect.minY))
            p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        } else {
            p.addEllipse(in: rect)
        }
        return p
    }
}
