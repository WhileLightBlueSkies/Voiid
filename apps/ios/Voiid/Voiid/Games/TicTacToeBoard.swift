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
//  Mirrors Android `TicTacToeBotScreen.kt`'s Cell.
//

import SwiftUI

struct TicTacToeBoard: View {
    /// 9 cells, row-major. Each is the seat index that owns it, or nil.
    let board: [Int?]
    /// Winning triple to highlight, if the game is won.
    let line: [Int]?
    /// False when taps should be ignored (not your turn, game over, paused).
    let enabled: Bool
    let onTap: (Int) -> Void

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
    }

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
                    .fill(isWinning ? VoiidColor.primary.opacity(0.20) : VoiidColor.surfaceCard)

                if let mark {
                    MarkShape(isCross: mark == 0)
                        .stroke(
                            mark == 0 ? VoiidColor.primary : VoiidColor.accent,
                            style: StrokeStyle(lineWidth: 9, lineCap: .round, lineJoin: .round)
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
            // The winning triple swells so the win reads instantly.
            .scaleEffect(isWinning ? 1.08 : 1)
            .animation(.spring(response: 0.45, dampingFraction: 0.5), value: isWinning)
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
