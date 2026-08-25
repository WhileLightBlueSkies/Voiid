//
//  MapOnboardingFlow.swift
//  Voiid
//
//  The Map's onboarding orchestrator — the one place that decides intro vs privacy vs
//  neither. Steps 1 and 2 of the four-step flow; the Map itself (MapTabView) and Move
//  (MapMoveScreen / MapStartMoveSheet) are steps 3 and 4 and are reached by finishing here.
//
//  ── ONBOARDING RUNS ONCE, AND ONLY ONCE ─────────────────────────────────────────
//  `voiid.map.seenExplainer` decides whether the tab opens on the intro or straight on the
//  map. EVERY exit from this flow sets it — Continue-then-allow, Continue-then-deny, "Not
//  now", and Skip alike — because a user who declined has still ANSWERED. Re-asking every
//  time they open the tab is nagging, and nagging is the fastest way to make someone
//  distrust a privacy feature.
//
//  ── THE PRIVACY STEP IS CONDITIONAL, NOT DECORATIVE ─────────────────────────────
//  It exists to explain an iOS prompt that is about to appear. If the user has ALREADY
//  granted When-In-Use (or Always) there is no prompt to explain, so showing it would be a
//  screen that asks for something the user has already given — which reads as broken. In
//  that case Continue completes onboarding immediately and hands the caller straight to the
//  audience choice.
//
//  ── WHY A SEPARATE FLOW VIEW AT ALL ─────────────────────────────────────────────
//  MapTabView is already a NavigationStack with its own destinations (Move) and four sheets.
//  Pushing onboarding into it would tangle two unrelated stacks. This is presented as a
//  fullScreenCover instead: onboarding is a door you pass through once, not a place inside
//  the Map you can navigate back to.
//

import SwiftUI

struct MapOnboardingFlow: View {

    /// Where the flow ended, so the Map knows what to do next.
    enum Outcome {
        /// The user is done and wants to pick an audience — permission is either granted, or
        /// they answered the prompt and the audience sheet's own in-context ask can retry.
        case chooseAudience
        /// The user opted out (Skip, "Not now", or a refusal they chose not to fix). The Map
        /// opens in Ghost Mode, which is the default state anyway — nothing is emitted.
        case browseOnly
    }

    /// Called exactly once, on every exit path. The caller marks onboarding seen and closes.
    var onFinish: (Outcome) -> Void

    @ObservedObject private var provider = MapLocationProvider.shared

    private enum Step: Hashable { case privacy }

    @State private var path: [Step] = []

    var body: some View {
        NavigationStack(path: $path) {
            MapIntroScreen(
                onContinue: {
                    // ALREADY GRANTED → skip the permission step entirely. There is no system
                    // prompt left to prepare them for, and a screen that asks for what you
                    // already gave is worse than no screen.
                    if provider.isAuthorized {
                        onFinish(.chooseAudience)
                    } else {
                        path.append(.privacy)
                    }
                },
                // Skip lands on the map in Ghost Mode rather than dropping the user back into
                // whatever tab they came from: they asked for the map, so they get a map.
                onSkip: { onFinish(.browseOnly) }
            )
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .privacy:
                    MapPrivacyScreen(
                        // Granted. Straight on to "who can see me" — the only remaining
                        // question, and the one the whole flow has been building toward.
                        onAllow: { onFinish(.chooseAudience) },
                        // "Not now", or a refusal accepted. Ghost Mode, no nagging.
                        onSkip: { onFinish(.browseOnly) },
                        onBack: { if !path.isEmpty { path.removeLast() } }
                    )
                }
            }
        }
        // Committed dark for the whole stack, so a push between the two screens never flashes
        // a light-mode navigation bar behind them.
        .preferredColorScheme(.dark)
    }
}
