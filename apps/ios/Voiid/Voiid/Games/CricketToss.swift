//
//  CricketToss.swift
//  Voiid
//
//  The toss, before ball one — shared by the online match and the bot match.
//
//  TWO STEPS, because that is the real game (backend/games/src/engine/cricket):
//
//    1. one side CALLS heads or tails
//    2. whoever wins the call ELECTS to bat or bowl
//
//  The election is the part worth having. Choosing to bowl first means batting second knowing
//  the target, which in a two-wicket format is a genuine tactic rather than ceremony — a toss
//  that only decided who bats would be a coin flip with extra taps.
//
//  PURE PRESENTATION. This view never decides anything: it reports what the player tapped and
//  renders the state the server (or, offline, the bot match) reports back. The coin itself is
//  decided before anyone can call — see the engine's note on why.
//
//  Mirrors Android `CricketToss.kt`. Keep the spin timing identical.
//

import SwiftUI

struct CricketToss: View {
    /// "toss-call" | "toss-decide".
    let phase: String
    /// True when the local player holds the call.
    let iCall: Bool
    /// True when the local player won the call and now elects.
    let iElect: Bool
    /// Which face landed, once called. Nil hides the result.
    let coin: String?
    /// What the caller said, for the "you called heads" line.
    let called: String?
    /// Opponent's display name, for the waiting copy.
    let opponentName: String

    var onCall: (String) -> Void
    var onElect: (String) -> Void

    /// True once the coin has finished landing, which gates the result copy and the bat/bowl
    /// buttons. The SPIN itself belongs to CoinSceneView — this is only "has it stopped yet",
    /// tracked here because the copy underneath has to wait for it.
    @State private var settled = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// MUST MATCH CoinSceneView's landing duration. The copy revealing before the coin stops
    /// would spoil its own result; revealing long after reads as a hang.
    private static let landingDuration: Double = 1.15
    private static let coinSize: CGFloat = 150

    var body: some View {
        VStack(spacing: VoiidSpacing.lg) {
            Spacer(minLength: 0)

            coinFace
            headline
            subline

            Spacer(minLength: 0)

            if phase == "toss-call" && iCall {
                choiceRow(["heads", "tails"]) { onCall($0) }
            } else if phase == "toss-decide" && iElect {
                choiceRow(["bat", "bowl"]) { onElect($0) }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: coin) { _, landed in
            guard landed != nil else { return }
            settle()
        }
        .onAppear {
            // Entered with the toss already called (a rejoin): the coin lands immediately and
            // the copy should not sit on "…" waiting for a flip the player never saw.
            if coin != nil { settled = true }
        }
    }

    // MARK: - Coin

    /// The coin — a REAL 3D cylinder (SceneKit), not a disc with a painted-on edge.
    ///
    /// The previous version was pure SwiftUI: a circle under `rotation3DEffect` with a band
    /// faked in for the side. That could not work, for a structural reason rather than a
    /// tuning one — `rotation3DEffect` foreshortens a FLAT layer, so the "edge" was a
    /// rectangle being squashed, and side-on it looked like a rectangle because it was one.
    /// A coin's edge is a curved surface and has to actually be curved.
    ///
    /// `CoinSceneView` owns the spin too: it idles until `coin` arrives, then lands on the
    /// face that was actually thrown.
    private var coinFace: some View {
        CoinSceneView(result: coin, size: Self.coinSize)
            .frame(width: Self.coinSize * 1.35, height: Self.coinSize * 1.35)
            .accessibilityLabel(accessibilityCoinLabel)
    }

    private var accessibilityCoinLabel: String {
        guard let coin, settled else { return "Coin in the air" }
        return coin == "heads" ? "The coin landed heads" : "The coin landed tails"
    }

    /// Wait out the coin's landing, then reveal the result copy.
    ///
    /// The coin does its own spinning; this only keeps the words in step with it. Reduce-motion
    /// skips the wait entirely — CoinSceneView still shows the correct face, and a player who
    /// has asked for less motion should not also be made to wait for it.
    private func settle() {
        guard !reduceMotion else {
            settled = true
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.landingDuration) {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.6)) { settled = true }
            Haptics.success()
        }
    }

    // MARK: - Copy

    private var headline: some View {
        Text(headlineText)
            .font(VoiidFont.rounded(22, .bold))
            .foregroundStyle(VoiidColor.textPrimary)
            .multilineTextAlignment(.center)
            .accessibilityAddTraits(.updatesFrequently)
    }

    private var headlineText: String {
        if phase == "toss-call" {
            return iCall ? "Call the toss" : "\(opponentName) is calling"
        }
        // toss-decide
        if !settled { return "…" }
        return iElect ? "You won the toss" : "\(opponentName) won the toss"
    }

    @ViewBuilder
    private var subline: some View {
        let text: String = {
            if phase == "toss-call" {
                return iCall ? "Heads or tails?" : "Waiting for their call…"
            }
            guard settled else { return "" }
            if let called, let coin {
                let outcome = called == coin ? "correct" : "wrong"
                return "Called \(called) — \(outcome), it's \(coin)."
                    + (iElect ? " Bat or bowl?" : " They're deciding…")
            }
            return iElect ? "Bat or bowl?" : "They're deciding…"
        }()

        if !text.isEmpty {
            Text(text)
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: - Choices

    /// The buttons only appear once the coin has settled, so a player cannot elect while it is
    /// still spinning and miss the result that explains their own choice.
    @ViewBuilder
    private func choiceRow(_ options: [String], action: @escaping (String) -> Void) -> some View {
        let ready = phase == "toss-call" || settled
        if ready {
            HStack(spacing: VoiidSpacing.md) {
                ForEach(options, id: \.self) { option in
                    Button {
                        Haptics.tap()
                        action(option)
                    } label: {
                        Text(option.capitalized)
                            .font(VoiidFont.rounded(17, .semibold))
                            .foregroundStyle(VoiidColor.textOnPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, VoiidSpacing.md)
                            .background(Capsule().fill(VoiidColor.primary))
                    }
                    .buttonStyle(.plain)
                }
            }
            .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}
