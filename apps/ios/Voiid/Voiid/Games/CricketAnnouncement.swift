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

    /// Seconds the message stays on the pitch before dismissing itself.
    ///
    /// THE SAME FOR EVERY KIND, deliberately. These were tuned per-announcement (4.0-5.6s) on
    /// the theory that a longer message deserves longer, and in a sequence that reads as the
    /// pacing lurching: two cards back to back at different lengths feel like one of them was
    /// cut short. A single interval makes a run of announcements feel like a rhythm rather than
    /// a list, and the longest message is the one that sets it.
    ///
    /// Timed against how long the text takes to be NOTICED, PARSED and turned into a decision —
    /// not merely read. "You need 14 to win" is four words and several seconds of thought. A
    /// message that outstays its welcome costs a beat; one that leaves early costs the
    /// information entirely, and there is no way to ask for it back.
    var duration: Double { Self.standardDuration }

    /// One interval for every announcement. See `duration`.
    static let standardDuration: Double = 5.6

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
    /// Guards re-entry into `dismiss` (a tap racing the auto-dismiss timer). Separate from
    /// `shown` because that one drives the exit animation and cannot be cleared early.
    @State private var dismissing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            // A scrim, not an opaque screen: the match stays visible behind it so the
            // announcement reads as happening TO the game rather than replacing it.
            //
            // ITS OPACITY IS TIED TO `shown` TOO. Previously only the card faded and the scrim
            // sat at full strength the whole time — so on the way out the card vanished and
            // left a grey sheet over the match, which is the washed-out screen this fixes.
            VoiidColor.background
                .opacity(shown ? 0.82 : 0)
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
        // KEYED ON THE ANNOUNCEMENT'S ID, so a second announcement gets a genuinely fresh view
        // rather than reusing this one. Without it SwiftUI keeps the existing instance —
        // `shown` is still true from the previous card, `onAppear` never fires again, and the
        // queued announcement appears with no animation and no dismiss timer, leaving its
        // scrim up forever. That is the other half of the stuck-overlay bug.
        .id(announcement.id)
        .task(id: announcement.id) {
            shown = false
            dismissing = false
            if reduceMotion {
                shown = true
            } else {
                withAnimation(.spring(response: 0.38, dampingFraction: 0.72)) { shown = true }
            }
            Haptics.tap()

            // Auto-dismiss, via the task rather than a detached asyncAfter: if this view goes
            // away early (the player leaves the match), the sleep is cancelled with it. A
            // stray asyncAfter would fire into a dead view and pop the NEXT announcement.
            try? await Task.sleep(nanoseconds: UInt64(announcement.duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            dismiss()
        }
    }

    private func dismiss() {
        // `dismissing`, not `shown`, guards re-entry: `shown` is what the ANIMATION reads, and
        // clearing it up front to block a double tap would also skip the fade it drives.
        guard !dismissing else { return }
        dismissing = true

        guard !reduceMotion else {
            shown = false
            onDismiss()
            return
        }
        withAnimation(.easeIn(duration: Self.exitDuration)) { shown = false }
        // Hand back only AFTER the fade, so the card and its scrim are gone before the next
        // announcement (or the match) takes the screen.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.exitDuration) { onDismiss() }
    }

    private static let exitDuration: Double = 0.22
}

/// Builds the announcement copy, so the online and bot screens cannot word the same event two
/// different ways. Pure functions of the facts — nothing here reads state.
enum CricketAnnouncements {
    /// Fired once, when the toss resolves.
    /// `choice` is what the TOSS WINNER elected — "bat" or "bowl" — whoever that was.
    ///
    /// The winner's election is about THEMSELVES, so turning it into "am I batting" depends on
    /// who won: if I won and chose to bat, I bat; if THEY won and chose to bat, I bowl. Getting
    /// that backwards is silent and produces an announcement that contradicts the scoreboard
    /// two seconds later, which is worse than no announcement at all.
    static func toss(id: Int, iWon: Bool, choice: String, opponent: String) -> CricketAnnouncement {
        let winnerBats = choice == "bat"
        let iBat = iWon ? winnerBats : !winnerBats
        let who = iBat ? "you're batting first" : "\(opponent) bats first"
        return CricketAnnouncement(
            id: id,
            kind: .toss,
            title: iWon ? "You won the toss" : "\(opponent) won the toss",
            // Say what was chosen AND what it means for the player, because "they chose to
            // bowl" requires a beat of thought to turn into "so I'm batting".
            detail: iWon
                ? "You chose to \(choice) — \(who)."
                : "\(opponent) chose to \(choice) — \(who).")
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
