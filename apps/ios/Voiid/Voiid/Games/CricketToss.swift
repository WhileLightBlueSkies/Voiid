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

    /// Rotation in degrees. Drives which FACE is toward the viewer, so it is the coin's state
    /// and not just decoration — see `showingHeads`.
    @State private var spin: Double = 0
    @State private var settled = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough to read as a real flip, short enough not to delay the match.
    private static let spinDuration: Double = 1.1
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
            if coin != nil {
                // Entered with the toss already called (a rejoin): show the landed face
                // immediately rather than replaying a flip the player did not make.
                spin = coin == "heads" ? 0 : 180
                settled = true
            } else {
                idleSpin()
            }
        }
    }

    // MARK: - Coin

    private var coinFace: some View {
        // DRIVEN BY AN ANIMATABLE MODIFIER, not by reading `spin` directly.
        //
        // `withAnimation` interpolates what is RENDERED; the @State itself jumps straight to
        // its final value. So a letter chosen from `spin` in the body would swap once, on the
        // first frame, and the coin would spin showing one face the whole way round. CoinFlip
        // is an AnimatableModifier, so SwiftUI hands it every intermediate angle and the
        // faces alternate exactly as the rotation passes edge-on.
        Color.clear
            .frame(width: Self.coinSize, height: Self.coinSize)
            .modifier(CoinFlip(angle: spin, face: { showingHeads in
                coinBody(showingHeads: showingHeads)
            }))
            .accessibilityLabel(accessibilityCoinLabel)
    }

    private func coinBody(showingHeads: Bool) -> some View {
        ZStack {
            Circle()
                .fill(Self.gold)
                // MATTE, NOT SHINY. A gloss highlight on a spinning disc reads as plastic and
                // fights the letter for attention — real coins are dull metal, and the
                // shallow top-to-bottom shading below is all the roundness it needs.
                .overlay(
                    Circle().fill(
                        LinearGradient(
                            colors: [.white.opacity(0.10), .clear, .black.opacity(0.10)],
                            startPoint: .top, endPoint: .bottom))
                )
                // The rim, in dark gold. Drawn INSIDE the circle's edge (inset by half the
                // stroke) so it reads as a milled edge rather than a ring floating around it.
                .overlay(
                    Circle()
                        .strokeBorder(Self.goldRim, lineWidth: Self.rimWidth)
                )
                // A second, inner rim — the raised ridge every struck coin has. This is the
                // detail that separates "gold circle" from "coin" at a glance.
                .overlay(
                    Circle()
                        .strokeBorder(Self.goldRim.opacity(0.55), lineWidth: 2)
                        .padding(Self.rimWidth + 5)
                )
                .frame(width: Self.coinSize, height: Self.coinSize)
                .shadow(color: .black.opacity(0.30), radius: 14, y: 8)

            Text(showingHeads ? "H" : "T")
                .font(.system(size: 62, weight: .black, design: .rounded))
                .foregroundStyle(Self.goldLetter)
                // Struck INTO the metal: a dark letter with a one-point light edge under it is
                // the cheapest convincing intaglio, and it survives the coin being small.
                .shadow(color: .white.opacity(0.35), radius: 0, x: 0, y: 1)
                // The far face is mirrored, so counter-flip the glyph — without this the
                // letter reads backwards for half of every rotation.
                .rotation3DEffect(.degrees(showingHeads ? 0 : 180), axis: (x: 0, y: 1, z: 0))
        }
    }

    // Gold, mixed by hand rather than taken from the theme: VoiidColor.accent is the app's
    // amber and is tuned for text on dark surfaces, not for a metal object that has to read as
    // gold against both light and dark backgrounds.
    private static let gold = Color(red: 0.83, green: 0.65, blue: 0.22)
    private static let goldRim = Color(red: 0.45, green: 0.31, blue: 0.05)
    private static let goldLetter = Color(red: 0.30, green: 0.20, blue: 0.02)
    private static let rimWidth: CGFloat = 7

    /// Spins a two-faced object and tells its content which face is toward the viewer.
    ///
    /// This has to be an `AnimatableModifier` rather than a plain `rotation3DEffect`: only an
    /// animatable type receives the INTERMEDIATE values of an animation, and the intermediate
    /// values are the entire point — they are what makes H and T alternate as the coin turns.
    private struct CoinFlip<Face: View>: AnimatableModifier {
        var angle: Double
        /// The generic is `Face`, NOT `Content`: `ViewModifier` already declares an associated
        /// type called `Content`, and shadowing it with a generic parameter silently breaks
        /// conformance ("does not conform to protocol 'ViewModifier'") with no other clue.
        ///
        /// Plain stored closure rather than `@ViewBuilder` for the same reason — keep this
        /// declaration as boring as possible.
        let face: (Bool) -> Face

        var animatableData: Double {
            get { angle }
            set { angle = newValue }
        }

        /// Between 90° and 270° (mod 360) the coin's back is toward the viewer.
        private var showingHeads: Bool {
            let a = angle.truncatingRemainder(dividingBy: 360)
            let n = a < 0 ? a + 360 : a
            return n < 90 || n > 270
        }

        /// How side-on the coin is right now, 0 (flat to the viewer) to 1 (perfectly edge-on).
        ///
        /// This is what gives the coin THICKNESS. A flat disc rotated in 3D vanishes to a line
        /// at 90°, which is what betrays it as a cut-out rather than an object. Fading a
        /// rendered edge in as the faces turn away — widest exactly when the face is
        /// narrowest — is what sells a solid piece of metal.
        private var edgeOn: Double {
            abs(sin(angle * .pi / 180))
        }

        /// The modified view is a transparent spacer reserving the coin's footprint; the coin
        /// is drawn as an overlay so `face` receives the animated value.
        func body(content: Content) -> some View {
            content.overlay(
                ZStack {
                    // THE EDGE — the coin's thickness, and the thing that makes it an object
                    // rather than a cut-out.
                    //
                    // COUNTER-SCALED AGAINST THE ROTATION, which is the whole trick. The
                    // rotation3DEffect below squashes everything horizontally as the coin
                    // turns, reaching zero exactly at 90° — so an edge band drawn normally is
                    // crushed to a hairline at precisely the moment it should be at its
                    // widest, which is what a first attempt looks like. Dividing by the same
                    // foreshortening the transform applies cancels it, leaving the edge a
                    // constant real width in screen terms.
                    CoinEdge()
                        .frame(width: CricketToss.coinSize * 0.115,
                               height: CricketToss.coinSize)
                        // CLAMPED AT 6x. The counter-scale is 1/(1-edgeOn), which runs away to
                        // infinity as the coin reaches exactly side-on — unclamped it becomes a
                        // slab wider than the coin for the last few degrees. Six is past the
                        // point where the edge already fills the silhouette, so the cap is
                        // invisible and the blow-up cannot happen.
                        .scaleEffect(x: min(1 / max(1 - edgeOn, 0.02), 6), y: 1, anchor: .center)
                        // LATE AND FAST. The edge belongs to the last stretch of the turn
                        // only: a linear fade has the coin reading as a bar for most of its
                        // rotation, because `edgeOn` is already 0.5 at just 30°. Raising it to
                        // a high power keeps the coin a FACE through the bulk of the spin and
                        // hands over to the edge only as it genuinely goes side-on.
                        .opacity(pow(edgeOn, 6))

                    // The face fades out as the edge takes over, instead of showing THROUGH
                    // it — a letter visible across the coin's own side is the clearest
                    // possible tell that this is two flat layers rather than one solid object.
                    // Same curve, inverted, so exactly one of the two is ever dominant.
                    face(showingHeads)
                        .opacity(1 - pow(edgeOn, 5))
                }
                .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
            )
        }
    }

    /// The coin's side: a gold band with vertical milling, seen as the coin turns edge-on.
    ///
    /// Drawn as a band rather than a true 3D extrusion because SwiftUI has no solid geometry —
    /// and it does not need one. At the moment this is visible the coin is nearly side-on, so
    /// a rectangle of ridges reads exactly as the milled edge of a struck coin.
    private struct CoinEdge: View {
        /// Milling: the fine vertical grooves cut into a coin's side. Dense on purpose — too
        /// few and it reads as a barcode rather than machined metal.
        private static let ridges = 26

        var body: some View {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                // Slightly shorter than the face, so the silhouette tucks in at top and bottom
                // the way a real cylinder seen edge-on does rather than ending square.
                let barHeight = h * 0.965

                ZStack {
                    // Darker at both extremes, brighter down the middle: a curved metal
                    // surface catching light along its centre line.
                    LinearGradient(
                        colors: [
                            CricketToss.goldRim,
                            CricketToss.gold,
                            Color(red: 0.93, green: 0.78, blue: 0.38),
                            CricketToss.gold,
                            CricketToss.goldRim,
                        ],
                        startPoint: .leading, endPoint: .trailing)

                    // THE HORIZONTAL LINE DESIGN — the milling itself, drawn as evenly spaced
                    // vertical grooves across the band.
                    HStack(spacing: 0) {
                        ForEach(0..<Self.ridges, id: \.self) { i in
                            Rectangle()
                                .fill(i.isMultiple(of: 2)
                                      ? CricketToss.goldRim.opacity(0.5)
                                      : Color.clear)
                        }
                    }
                }
                .frame(width: w, height: barHeight)
                .clipShape(RoundedRectangle(cornerRadius: w * 0.3))
                // Rim lines top and bottom, where the edge meets each face.
                .overlay(
                    RoundedRectangle(cornerRadius: w * 0.3)
                        .strokeBorder(CricketToss.goldRim, lineWidth: 1.5)
                        .frame(width: w, height: barHeight))
                .frame(width: w, height: h)
            }
        }
    }

    private var accessibilityCoinLabel: String {
        guard let coin, settled else { return "Coin in the air" }
        return coin == "heads" ? "The coin landed heads" : "The coin landed tails"
    }

    /// A slow turn while nobody has called yet.
    ///
    /// A coin sitting dead still under "Heads or tails?" looks like a disabled control. Turning
    /// it slowly says the toss has not happened yet AND shows both faces before you commit,
    /// which is the honest thing to do when the player is about to bet on one of them.
    private func idleSpin() {
        guard !reduceMotion, coin == nil else { return }
        withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
            spin = 360
        }
    }

    /// Spin the coin so that it COMES TO REST ON THE FACE THAT ACTUALLY LANDED.
    ///
    /// The target is not "some number of turns" — it is an exact final angle: a multiple of
    /// 360° to show heads, an odd multiple of 180° to show tails. Anything else stops the coin
    /// edge-on or displaying the wrong side, which would make the animation contradict the
    /// result printed underneath it.
    private func settle() {
        guard let coin else { return }
        let wantsHeads = coin == "heads"

        guard !reduceMotion else {
            // No spin, but still land on the right face — the result must be legible.
            withAnimation(.none) { spin = wantsHeads ? 0 : 180 }
            settled = true
            return
        }

        // CANCEL THE IDLE SPIN FIRST. It is a `repeatForever`, and starting the landing
        // animation without stopping it leaves the coin turning under the result forever.
        // Re-stating the CURRENT presented angle with no animation ends the repeat; reading
        // it back off `spin` would give the target of the idle loop, not where it visually is.
        let current = spin.truncatingRemainder(dividingBy: 360)
        withAnimation(.none) { spin = current }

        // Five and a bit turns from where it actually is, then snapped to the nearest angle
        // that shows the correct face. Enough rotation to read as a real flip.
        let minimum = current + 1800
        let step = 360.0
        var target = (minimum / step).rounded(.up) * step
        if !wantsHeads { target += 180 }

        withAnimation(.easeOut(duration: Self.spinDuration)) { spin = target }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.spinDuration) {
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
