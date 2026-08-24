//
//  VerifiedScreen.swift
//  Voiid
//
//  The success moment, after the code is accepted.
//
//  ── WHY THIS ANIMATES WHEN ALMOST NOTHING ELSE DOES ─────────────────────────────
//  Onboarding is otherwise deliberately still. This screen is the exception, and the rule that
//  allows it is FREQUENCY: a user verifies once, ever. That is the rare/first-time tier, the one
//  place a decorative animation is defensible — the same motion on a screen seen daily would be
//  a defect.
//
//  It also has a JOB beyond delight. Verification is the moment the account becomes real, and
//  the app needs a beat to do the work that follows. A success animation converts that unavoidable
//  wait into confirmation, which is the honest version of a loading state.
//
//  ── THE CHOREOGRAPHY, AND WHY IT IS IN THIS ORDER ───────────────────────────────
//  Ring draws → tick strokes on → both settle → copy fades up. Sequenced, not simultaneous:
//  everything arriving at once reads as a single image being switched on, which is exactly what
//  a confirmation should NOT feel like. The eye needs to see the mark being MADE.
//
//  The tick is a trimmed path, so it draws the way a tick is drawn — one stroke, start to end.
//  Fading or scaling a finished checkmark is the cheap version and reads as it.
//
//  ── REDUCED MOTION ──────────────────────────────────────────────────────────────
//  Honoured. It does not mean "no animation": the tick still appears and the copy still fades,
//  because a hard cut to a finished state is its own jarring. What goes is the DRAWING — the
//  path completes instantly, the ring does not sweep, nothing scales.
//

import SwiftUI

// NOTE ON THE BRAND TOKENS: `VoiidBrand.lime*` names the SLOT (fill / lit edge / lower stop),
// not the hue — the values are Tide teal since the brand moved off the lime. See OnboardingKit.

struct VerifiedScreen: View {

    /// Called once the moment has played out. The caller decides what comes next.
    var onFinished: () -> Void = {}
    /// How long to hold the finished state before continuing.
    var holdAfter: TimeInterval = 1.1

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 0→1, draws the ring.
    @State private var ringProgress: CGFloat = 0
    /// 0→1, strokes the tick.
    @State private var tickProgress: CGFloat = 0
    /// The settle pop once the tick lands.
    @State private var markScale: CGFloat = 0.86
    @State private var copyVisible = false
    /// One soft halo that expands and fades as the tick completes.
    @State private var haloScale: CGFloat = 0.9
    @State private var haloOpacity: Double = 0

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            // The pool of light, matching the splash's own. Static — it is a backdrop, not the
            // event.
            RadialGradient(
                colors: [VoiidBrand.lime.opacity(0.13), VoiidBrand.lime.opacity(0.03), .clear],
                center: UnitPoint(x: 0.5, y: 0.42),
                startRadius: 0,
                endRadius: 320
            )
            .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                mark

                Text("Verified")
                    .font(VoiidFont.rounded(30, .bold))
                    .foregroundColor(VoiidBrand.text)
                    .padding(.top, VoiidSpacing.xl)
                    .opacity(copyVisible ? 1 : 0)
                    .offset(y: copyVisible ? 0 : (reduceMotion ? 0 : 8))

                Text("Your number is confirmed.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidBrand.textDim)
                    .padding(.top, VoiidSpacing.sm)
                    .opacity(copyVisible ? 1 : 0)
                    .offset(y: copyVisible ? 0 : (reduceMotion ? 0 : 8))

                Spacer(minLength: 0)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        // The moment is over — there is nothing to go back TO, because the number is verified.
        .toolbar(.hidden, for: .navigationBar)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Verified. Your number is confirmed.")
        .task { await play() }
    }

    // MARK: The mark

    private var mark: some View {
        ZStack {
            // The halo. Expands past the ring and fades — the visual equivalent of the haptic
            // that fires with it.
            Circle()
                .fill(VoiidBrand.lime.opacity(0.16))
                .frame(width: 132, height: 132)
                .scaleEffect(haloScale)
                .opacity(haloOpacity)

            // The ring, drawn rather than faded. Starts at 12 o'clock: `trim` begins at 3, so
            // without the rotation the sweep starts from the right and reads as arbitrary.
            Circle()
                .trim(from: 0, to: ringProgress)
                .stroke(
                    LinearGradient(
                        colors: [VoiidBrand.limeBright, VoiidBrand.lime],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: 4, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .frame(width: 116, height: 116)

            Tick()
                .trim(from: 0, to: tickProgress)
                .stroke(
                    VoiidBrand.lime,
                    style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round)
                )
                .frame(width: 54, height: 40)
        }
        .scaleEffect(markScale)
    }

    // MARK: The sequence

    private func play() async {
        if reduceMotion {
            // Present, but not drawn. See the header.
            ringProgress = 1
            tickProgress = 1
            markScale = 1
            withAnimation(.easeOut(duration: 0.3)) { copyVisible = true }
            try? await Task.sleep(for: .seconds(holdAfter))
            onFinished()
            return
        }

        // 1. The ring sweeps closed. ease-out: fast off the mark, settling at the join, so the
        //    circle appears to close rather than to stop.
        withAnimation(.easeOut(duration: 0.45)) { ringProgress = 1 }
        try? await Task.sleep(for: .milliseconds(260))

        // 2. The tick strokes on, overlapping the ring's tail — waiting for the ring to finish
        //    first would put a dead beat in the middle of the moment.
        withAnimation(.easeOut(duration: 0.30)) { tickProgress = 1 }
        Haptics.success()

        // 3. Everything settles together. A spring, because this is the part that should feel
        //    like an object landing; bounce stays low so it reads as confidence, not as a toy.
        withAnimation(.spring(duration: 0.5, bounce: 0.28)) { markScale = 1 }

        // The halo has to be VISIBLE before it can be animated away. Setting the start value
        // after the withAnimation block — as the first version did — simply assigned the final
        // state, so the halo appeared at full strength and stayed there, a solid disc behind the
        // tick. Start first, then animate out.
        haloOpacity = 0.55
        withAnimation(.easeOut(duration: 0.75)) {
            haloScale = 1.6
            haloOpacity = 0
        }

        try? await Task.sleep(for: .milliseconds(180))
        withAnimation(.easeOut(duration: 0.35)) { copyVisible = true }

        try? await Task.sleep(for: .seconds(holdAfter))
        onFinished()
    }
}

// MARK: - The tick

/// A checkmark as a PATH, so it can be trimmed and drawn stroke-wise.
///
/// Proportional to its frame rather than fixed points, so it scales with whatever size the call
/// site gives it. The proportions are a standard tick: the short arm about a third of the long
/// one, meeting below the midline.
private struct Tick: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY + rect.height * 0.05))
        p.addLine(to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        return p
    }
}

// MARK: - Previews

#Preview("Verified") {
    VerifiedScreen()
}
