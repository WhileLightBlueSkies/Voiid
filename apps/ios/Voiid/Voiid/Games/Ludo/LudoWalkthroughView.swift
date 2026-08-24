//
//  LudoWalkthroughView.swift
//  Voiid
//
//  First-run rules walkthrough (§10): version 1, seven steps, a bottom sheet no higher than
//  30% of the screen so the highlighted REAL cells stay visible. A LOCAL DEMO built from the
//  same 15×15 renderer and geometry — never networked, never after a live match started.
//
//  The capture demonstration MUST use track index 7 (index 8 is safe) — that invariant is
//  pinned in the backend tutorial snapshot test and mirrored by the step table below.
//
//  A persistent Skip in the top-right dismisses ALL steps in one tap; both skip and Done write
//  local seen state immediately and fire the cross-device sync upstream without waiting.
//

import SwiftUI

enum LudoWalkthroughMode { case firstRun, sandbox }

struct LudoWalkthroughView: View {
    let mode: LudoWalkthroughMode
    var clockNote = false          // "The clock keeps running" when opened during own turn (§10)
    let onDismiss: () -> Void

    @State private var step = 0

    static let version = 1

    private static let steps: [(copy: String, highlight: Set<String>)] = [
        ("Tap the die to roll.", ["cell-6-7"]),                                  // die pulse beat
        ("A six brings a pawn out.", ["cell-2-11", "cell-6-13"]),                // yard slot 0 → start 0
        ("Move by the number shown.", ["cell-6-12", "cell-6-11", "cell-6-10", "cell-6-9"]),
        ("Land on a rival to send it home.", ["cell-5-8"]),                      // TRACK INDEX 7 (not safe)
        ("Stars and colored starts are safe.", [                                  // all eight safe cells
            "cell-6-13", "cell-2-8", "cell-1-6", "cell-6-2",
            "cell-8-1", "cell-12-6", "cell-13-8", "cell-8-12"]),
        ("Finish through your colored lane.", ["cell-7-13", "cell-7-12", "cell-7-11", "cell-7-10", "cell-7-9"]),
        ("Bring all four pawns home to win.", []),                                // center slots fill
    ]

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("How to play · \(step + 1) of \(Self.steps.count)")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Spacer()
                Button("Skip") { dismiss(seenAll: true) }   // ONE tap ends all steps (§10)
                    .font(VoiidFont.rounded(14, .semibold))
            }
            if clockNote && mode == .sandbox {
                Text("The clock keeps running")
                    .font(VoiidFont.rounded(12))
                    .foregroundStyle(LudoColors.resolve(scheme).textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            WalkthroughBoard(step: step)
                .frame(height: 180)                          // ≤30% of screen height (§10)
            Text(Self.steps[step].copy)
                .font(VoiidFont.rounded(15))
                .foregroundStyle(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                if step > 0 {
                    Button("Back") { withAnimation { step -= 1 } }
                        .buttonStyle(.bordered)
                }
                Spacer()
                Button(step < Self.steps.count - 1 ? "Next" : "Done") {
                    if step < Self.steps.count - 1 {
                        withAnimation { step += 1 }
                    } else {
                        dismiss(seenAll: true)
                    }
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 20).fill(VoiidColor.surfaceCard))
        .padding(.horizontal, 12)
    }

    @Environment(\.colorScheme) private var scheme

    private func dismiss(seenAll: Bool) {
        // Local seen state writes IMMEDIATELY; the cross-device sync (§7.1) is fired
        // fire-and-forget so a tunnel cannot trap a player in the walkthrough.
        UserDefaults.standard.set(Self.version, forKey: "ludo.walkthrough.seen")
        Task.detached {
            _ = try? await GamesAPI().setWalkthroughSeen(version: Self.version)
        }
        onDismiss()
    }
}

private struct WalkthroughBoard: View {
    let step: Int
    @Environment(\.colorScheme) private var scheme

    /// A non-networked TutorialState rendered through the REAL board canvas (§10).
    static func tutorialState(step: Int) -> LudoGameStateV2 {
        let Y = LudoRules.yard
        let tokens: [[Int]] = {
            switch step {
            case 0: return [[Y, Y, Y, Y], [Y, Y, Y, Y]]
            case 1: return [[LudoRules.startIndex(0), Y, Y, Y], [Y, Y, Y, Y]]
            case 2: return [[4, Y, Y, Y], [Y, Y, Y, Y]]
            case 3: return [[7, Y, Y, Y], [Y, Y, Y, Y]]                 // rival at NON-safe 7
            case 4: return [[13, Y, Y, Y], [13, Y, Y, Y]]               // two colours coexist on safe 13
            case 5: return [[LudoRules.homeLaneBase + 3, Y, Y, Y], [Y, Y, Y, Y]]
            default: return [[LudoRules.finished, LudoRules.finished,
                              LudoRules.finished, LudoRules.finished],
                             [Y, Y, Y, Y]]
            }
        }()
        func seat(_ s: Int, name: String) -> LudoSeatViewV2 {
            LudoSeatViewV2(seat: s, seatId: "demo-\(s)", color: LudoSeatColor(rawValue: s) ?? .red,
                           displayName: name, participation: "active", connection: "connected",
                           timeoutStreak: 0, finishedPawns: 0, captures: 0)
        }
        return LudoGameStateV2(
            schemaVersion: LudoRules.schemaVersion,
            rulesVersion: LudoRules.rulesVersion,
            mode: "duel",
            status: "active",
            serverNow: 0, viewerSeat: 0,
            seats: [seat(0, name: "@you"), seat(2, name: "@rival")],
            tokensPerSeat: 4,
            tokens: tokens + [],
            turn: nil,
            lastAction: nil,
            winnerSeat: step == 6 ? 0 : nil,
            endReason: step == 6 ? "win" : nil,
            seedCommitment: nil,
            seq: 0)
    }

    var body: some View {
        let state = Self.tutorialState(step: step)
        Canvas { ctx, size in
            LudoBoardCanvas.draw(&ctx, size: CGSize(width: size.height, height: size.height),
                                 colors: LudoColors.resolve(scheme), state: state, sweep: nil)
        }
        .clipShape(RoundedRectangle(cornerRadius: LudoDimens.boardCornerRadius))
        .accessibilityHidden(true)
    }
}
