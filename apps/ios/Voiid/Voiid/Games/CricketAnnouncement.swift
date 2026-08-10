//
//  CricketAnnouncement.swift
//  Voiid
//
//  The moments in a match that deserve to be SAID, not just reflected in a label.
//
//  Hand Cricket's big transitions were all silent state flips: the innings changed and the
//  scoreboard simply started counting a different number, the roles swapped and a 13pt caption
//  quietly went from "You're batting" to "You're bowling". If you were looking at the pick pad
//  — which is where your eyes are — you missed all of it, and then wondered why your taps were
//  scoring nothing.
//
//  A real match STOPS and tells you. Umpire signals, a scoreboard change, the commentator
//  saying it out loud. This is that: a card that owns the screen for a beat, blocks input while
//  it is up, and gets out of the way.
//
//  DELIBERATELY BLOCKING. It would be easy to make this a toast that slides over the corner,
//  and that would be the wrong call — the whole problem is that these events are missable, and
//  a non-blocking toast is missable by construction. The pause is the feature.
//
//  Mirrors Android `CricketAnnouncement.kt`.
//

import SwiftUI

/// One thing worth announcing. `id` changes whenever a NEW announcement should replay, so the
/// same text can be shown twice in a match (two innings breaks in a rematch, say).
struct CricketAnnouncement: Equatable, Identifiable {
    enum Kind: Equatable {
        case toss           // who won it and what they chose
        case inningsBreak   // first innings done, sides swap
        case roleChange     // you are batting / you are bowling, now
        case target         // what the chase actually needs
    }

    let id: Int
    let kind: Kind
    /// The headline. Short, past tense, and specific — "You won the toss" beats "Toss result".
    let title: String
    /// One line of consequence. What it MEANS for the player, not a restatement of the title.
    let detail: String

    /// Seconds the card stays up before dismissing itself.
    var duration: Double {
        switch kind {
        case .toss:         return 2.6
        case .inningsBreak: return 2.8
        case .roleChange:   return 2.0
        case .target:       return 2.6
        }
    }

    var symbol: String {
        switch kind {
        case .toss:         return "circle.circle.fill"
        case .inningsBreak: return "arrow.triangle.2.circlepath"
        case .roleChange:   return "figure.cricket"
        case .target:       return "target"
        }
    }
}

/// The card itself. Presented over the match, dismissing on its own timer or on a tap.
struct CricketAnnouncementView: View {
    let announcement: CricketAnnouncement
    var onDismiss: () -> Void

    @State private var shown = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A scrim, not an opaque screen: the match stays visible behind it so the
            // announcement reads as happening TO the game rather than replacing it.
            VoiidColor.background.opacity(0.82)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: VoiidSpacing.md) {
                Image(systemName: announcement.symbol)
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(VoiidColor.primary)

                Text(announcement.title)
                    .font(VoiidFont.rounded(26, .bold))
                    .foregroundStyle(VoiidColor.textPrimary)
                    .multilineTextAlignment(.center)

                Text(announcement.detail)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VoiidSpacing.xl)
            .padding(.vertical, VoiidSpacing.xl)
            .frame(maxWidth: 340)
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.lg)
                    .fill(VoiidColor.surfaceCard)
                    .shadow(color: .black.opacity(0.3), radius: 20, y: 10))
            .scaleEffect(shown ? 1 : 0.88)
            .opacity(shown ? 1 : 0)
        }
        // One accessibility element, so VoiceOver reads the whole announcement as a unit and
        // interrupts whatever it was saying — this is exactly the kind of thing that should.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isModal)
        .onAppear {
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { shown = true }
            }
            Haptics.tap()
            // Auto-dismiss. A tap is offered too, for anyone who reads faster than the timer.
            DispatchQueue.main.asyncAfter(deadline: .now() + announcement.duration) {
                dismiss()
            }
        }
    }

    private func dismiss() {
        guard shown else { return }        // already dismissing; a tap must not double-fire
        if reduceMotion {
            shown = false
            onDismiss()
            return
        }
        withAnimation(.easeIn(duration: 0.18)) { shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { onDismiss() }
    }
}

/// Builds the announcement copy, so the online and bot screens cannot word the same event two
/// different ways. Pure functions of the facts — nothing here reads state.
enum CricketAnnouncements {
    /// Fired once, when the toss resolves.
    static func toss(id: Int, iWon: Bool, choice: String, opponent: String) -> CricketAnnouncement {
        let batting = (choice == "bat") == iWon
        return CricketAnnouncement(
            id: id,
            kind: .toss,
            title: iWon ? "You won the toss" : "\(opponent) won the toss",
            // Say what was chosen AND what it means for the player, because "they chose to
            // bowl" requires a beat of thought to turn into "so I'm batting".
            detail: iWon
                ? "You chose to \(choice) — \(batting ? "you're batting first" : "they're batting first")."
                : "\(opponent) chose to \(choice) — \(batting ? "you're batting first" : "they're batting first").")
    }

    /// Fired at the innings change, before the chase begins.
    static func inningsBreak(id: Int, firstInningsScore: Int, target: Int,
                             iChase: Bool, opponent: String) -> CricketAnnouncement {
        CricketAnnouncement(
            id: id,
            kind: .inningsBreak,
            title: "End of the first innings",
            detail: iChase
                ? "\(opponent) made \(firstInningsScore). You need \(target) to win."
                : "You made \(firstInningsScore). \(opponent) needs \(target) to win.")
    }

    /// Fired whenever the local player's ROLE changes — the thing that was a 13pt caption.
    static func role(id: Int, batting: Bool) -> CricketAnnouncement {
        CricketAnnouncement(
            id: id,
            kind: .roleChange,
            title: batting ? "You're batting" : "You're bowling",
            detail: batting
                ? "Pick a number. If they match it, you're out."
                : "Pick a number. Match theirs and you take the wicket.")
    }
}
