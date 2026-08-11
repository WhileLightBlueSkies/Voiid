//
//  SnakeCoach.swift
//  Voiid
//
//  Teaching Snake by playing it, once (docs/games/SNAKE_COMPETITIVE_PARITY.md §4 P2.6).
//
//  The competitor ships a `TutorialGameMode` with a `TutorialSnakeBot` and a
//  `TutorialTouchZone` — a whole parallel mode. We deliberately do not, for two reasons.
//
//  A separate mode is a second arena to keep in step with the real one: every change to
//  steering, boost or death has to be made twice, and the day they drift the tutorial teaches
//  something false. And a scripted opponent is a lie a player can feel — they beat it, then
//  meet a real bot and discover the game they were taught is not the game they are playing.
//
//  So this is a coach, not a mode. It rides on top of an ordinary match: real bots, real
//  stakes, real death. It only ever ADDS one line of text at a time and never blocks input,
//  because a tutorial that takes the controls away is a slideshow with extra steps.
//
//  IT RUNS ONCE. The flag is set the moment the last step is reached, not when the match ends,
//  so a player who learns the game and then dies does not get taught it again. There is no
//  "replay tutorial" button: the rules sheet on the game picker covers everything this says,
//  and a coach you can summon is a help system, which is a different feature.
//
//  Mirrors Android `SnakeCoach.kt`.
//

import Combine
import SwiftUI

/// One thing to teach, and the condition that proves it was learned.
enum SnakeCoachStep: Int, CaseIterable {
    /// Steering. Cleared by moving at all — the check is on distance travelled, not on the
    /// control being touched, so it works identically for both schemes (P1.5) rather than
    /// hard-coding the joystick the way a `TutorialTouchZone` would.
    case steer
    /// Eating. Cleared by mass going up, which is the only definition of "ate" the player has.
    case eat
    /// Boosting. Cleared by the boost actually engaging — `boostActive`, not the button being
    /// held, since below the fuel floor holding it does nothing and teaching otherwise would
    /// be teaching a bug.
    case boost
    /// The rule that kills people. Cleared on a timer: there is no safe way to make a player
    /// demonstrate dying, so this one is told rather than tested.
    case rule

    var text: String {
        switch self {
        case .steer: return "Steer with your thumb — your snake never stops moving."
        case .eat:   return "Eat the dots. Every one makes you longer."
        case .boost: return "Hold boost to sprint. It burns the length you just ate."
        case .rule:  return "You die by touching another snake's body. Their head hitting yours is their problem."
        }
    }

    var icon: String {
        switch self {
        case .steer: return "hand.draw"
        case .eat:   return "circle.hexagongrid.fill"
        case .boost: return "bolt.fill"
        case .rule:  return "exclamationmark.triangle.fill"
        }
    }
}

/// Drives the steps and remembers that it has run.
@MainActor
final class SnakeCoach: ObservableObject {
    private static let key = "voiid.snake.coached"

    static var hasCoached: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }

    /// Nil once there is nothing left to teach.
    @Published private(set) var step: SnakeCoachStep?

    /// Where the snake was when the current step began, so `steer` can measure movement rather
    /// than trust a control callback.
    private var origin: CGPoint?
    private var massAtStart: Int?
    /// Guards against a step being cleared by state that was already true when it opened — a
    /// player who happens to be boosting when `boost` appears has not been taught anything.
    private var openedAt: Date = .distantPast

    init(enabled: Bool) {
        // Nothing to do for a player who has already been through it. Constructing the coach
        // and immediately finishing keeps the arena's wiring identical either way.
        step = enabled && !Self.hasCoached ? .steer : nil
    }

    /// Called every frame with the live match state.
    func update(head: CGPoint, mass: Int, boostActive: Bool) {
        guard let current = step else { return }
        if origin == nil { origin = head; massAtStart = mass; openedAt = Date() }

        // Every step holds for a beat before it can clear. A line that vanishes the instant it
        // appears was never read, and the player is left knowing something changed but not what.
        let shown = Date().timeIntervalSince(openedAt)
        guard shown > 1.4 else { return }

        let done: Bool
        switch current {
        case .steer:
            let d = hypot(head.x - (origin?.x ?? head.x), head.y - (origin?.y ?? head.y))
            done = d > 240
        case .eat:
            done = mass > (massAtStart ?? mass)
        case .boost:
            done = boostActive
        case .rule:
            // Told, not tested — so it clears on reading time. Longer than the others because
            // it is the longest line and the only one that is not confirmed by doing.
            done = shown > 6
        }

        if done { advance() }
    }

    private func advance() {
        let next = SnakeCoachStep(rawValue: (step?.rawValue ?? 0) + 1)
        step = next
        origin = nil
        massAtStart = nil
        openedAt = Date()
        // Set on reaching the END, not on the match ending. A player who has been shown all
        // four lines has been taught; whether they then survive is not the coach's business,
        // and re-teaching someone who died once is how a tutorial becomes a nag.
        if next == nil { Self.hasCoached = true }
    }
}

/// The one line, at the top of the arena.
///
/// Positioned under the HUD rather than over the middle of the board: the middle is where the
/// snake is, and covering the thing you are teaching someone to look at defeats the purpose.
struct SnakeCoachBanner: View {
    let step: SnakeCoachStep?

    var body: some View {
        // Keyed on the step so each line gets its own transition — without the id, SwiftUI
        // reuses the view and the text swaps in place with no animation at all.
        if let step {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: step.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiidColor.primary)
                Text(step.text)
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .fill(.black.opacity(0.55))
                    .overlay(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .stroke(.white.opacity(0.12), lineWidth: 1))
            )
            .id(step)
            // Down from above and out upward: the banner belongs to the HUD it sits under, so
            // it enters and leaves from the same edge rather than appearing from nothing.
            .transition(.asymmetric(
                insertion: .move(edge: .top).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)))
            // Never eats a touch. Everything under it is the arena, and the swipe scheme steers
            // by dragging anywhere on it.
            .allowsHitTesting(false)
        }
    }
}
