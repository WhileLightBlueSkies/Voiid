//
//  CricketOverStrip.swift
//  Voiid
//
//  The current over, ball by ball — the strip every cricket broadcast puts on screen.
//
//  WHY IT MATTERS HERE. Hand Cricket's scoreboard says 34-1 in 1.3 overs, which is the state but
//  not the STORY. "· 4 W 2 – –" says the over started quietly, went for four, took a wicket, and
//  has two balls left. That is what a player actually reasons about when deciding whether to
//  push for runs or block, and until now none of it was on screen: the pitch showed the last
//  ball and then forgot it.
//
//  DERIVED, NOT STORED. Every ball is already in `history` with its innings, so the strip is a
//  filter and a slice — no new state, nothing to keep in sync, and it is automatically right
//  after a reconnect or a rejoin.
//
//  Mirrors Android `CricketOverStrip.kt`.
//

import SwiftUI

struct CricketOverStrip: View {
    /// Every ball bowled in the match so far, oldest first.
    let history: [CricketState.Ball]
    /// The innings being played right now — balls from the first innings must not leak into the
    /// second's over strip.
    let innings: Int
    /// Balls bowled in THIS innings, which is where the over boundary comes from.
    let ballsBowled: Int

    private static let ballsPerOver = 6

    var body: some View {
        HStack(spacing: VoiidSpacing.xs) {
            Text(label)
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.trailing, 2)

            ForEach(0..<Self.ballsPerOver, id: \.self) { i in
                bead(at: i)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// "Over 2" — 1-based, because nobody says "over 1" meaning the second one.
    private var label: String { "Over \(ballsBowled / Self.ballsPerOver + 1)" }

    /// Balls bowled in the CURRENT over only.
    ///
    /// Taken from the tail of this innings' history rather than counted forward, so a match
    /// joined mid-over still shows the right beads.
    private var thisOver: [CricketState.Ball] {
        let mine = history.filter { $0.innings == innings }
        let done = ballsBowled % Self.ballsPerOver
        // A completed over reads as full until the next ball lands, rather than snapping to
        // empty the instant the sixth is bowled — the player is still looking at it.
        let count = done == 0 && !mine.isEmpty ? Self.ballsPerOver : done
        return Array(mine.suffix(count))
    }

    @ViewBuilder
    private func bead(at index: Int) -> some View {
        let balls = thisOver
        let ball: CricketState.Ball? = index < balls.count ? balls[index] : nil

        Text(text(for: ball))
            .font(VoiidFont.rounded(13, .bold))
            .foregroundStyle(foreground(for: ball))
            .frame(width: 24, height: 24)
            .background(Circle().fill(background(for: ball)))
            // A ball that has just landed pops, so the eye is drawn to the newest bead rather
            // than having to find it.
            .scaleEffect(index == balls.count - 1 ? 1.0 : 0.92)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: balls.count)
    }

    /// Broadcast shorthand: W for a wicket, · for a dot, the number otherwise. Future balls are
    /// an em dash, which is what makes "how much is left" readable at a glance.
    private func text(for ball: CricketState.Ball?) -> String {
        guard let ball else { return "–" }
        if ball.wicket { return "W" }
        return ball.runs == 0 ? "·" : "\(ball.runs)"
    }

    private func foreground(for ball: CricketState.Ball?) -> Color {
        guard let ball else { return VoiidColor.textSecondary.opacity(0.5) }
        if ball.wicket { return .white }
        return ball.runs >= 4 ? .white : VoiidColor.textPrimary
    }

    private func background(for ball: CricketState.Ball?) -> Color {
        guard let ball else { return VoiidColor.fieldFill.opacity(0.4) }
        if ball.wicket { return Color(red: 0.70, green: 0.16, blue: 0.16) }
        // Boundaries get the accent, so a good over is legible as a shape before it is read.
        if ball.runs >= 4 { return VoiidColor.primary }
        return ball.runs == 0 ? VoiidColor.fieldFill : VoiidColor.fieldFill.opacity(0.85)
    }

    private var accessibilityText: String {
        let balls = thisOver
        guard !balls.isEmpty else { return "\(label), no balls bowled yet" }
        let spoken = balls.map { ball -> String in
            if ball.wicket { return "wicket" }
            return ball.runs == 0 ? "dot" : "\(ball.runs)"
        }
        return "\(label): " + spoken.joined(separator: ", ")
    }
}
