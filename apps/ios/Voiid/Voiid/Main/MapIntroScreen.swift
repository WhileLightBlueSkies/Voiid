//
//  MapIntroScreen.swift
//  Voiid
//
//  The Map's first door — step 1 of the four-step flow (intro → privacy → map → move).
//
//  ── WHY AN INTRO AT ALL ─────────────────────────────────────────────────────────
//  Most onboarding screens are a tax. This one is not: the next screen asks for the user's
//  location, and iOS gives them exactly ONE chance to say yes. A permission prompt that
//  arrives with no explanation gets denied, and a denied location permission is a dead
//  feature the user has to go to Settings to revive.
//
//  So this screen exists to make three promises BEFORE the ask — Ghost Mode, a chosen
//  audience, end-to-end protected sharing — and Skip stays available throughout, because a
//  feature that will not take no for an answer is exactly what makes people distrust it.
//
//  All three promises are literally TRUE of Voiid, which is why they are safe to make:
//   - Ghost Mode is a hard LOCAL gate — while ghosted, MapPresenceEngine takes no fix at all
//     and MapLocationProvider is stopped. It is not a server-side "please don't show me".
//   - The audience is an explicit allow-list. There is no "share with everyone" door (§8).
//   - Presence is E2EE per share; the server sees that a share exists and when it ends, never
//     a coordinate (docs/LOCATION.md).
//
//  ── COMMITTED DARK ──────────────────────────────────────────────────────────────
//  Like every other onboarding-shaped screen in the app, this one pins `VoiidBrand.ground`
//  and therefore MUST use `VoiidBrand.text` / `.textDim`. `VoiidColor.textPrimary` is
//  theme-resolving and near-BLACK in light mode — on this ground it renders invisible.
//

import SwiftUI

struct MapIntroScreen: View {

    /// Continue → the privacy step (or straight to the audience choice when permission is
    /// already granted; the orchestrator decides, not this screen).
    var onContinue: () -> Void = {}
    /// Skip → the map, in Ghost Mode. They asked for the map, so they get a map.
    var onSkip: () -> Void = {}

    /// Drives the entrance. Set on appear so the content settles rather than snapping in.
    @State private var appeared = false

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            // FIXED CHROME, SCROLLING MIDDLE.
            //
            // The reference put the whole page inside one ScrollView with the footer as a
            // sibling — which on a 667pt device (SE / 13 mini) pushed the three promises and
            // the Continue button below the fold, so the screen read as one that just ends.
            // Here the Skip row and the footer are pinned OUTSIDE the scroll view: the button
            // is always on screen at any height, and only the headline/illustration/promises
            // scroll, so nothing is ever clipped — it just becomes reachable by dragging.
            VStack(spacing: 0) {
                skipRow

                ScrollView {
                    VStack(spacing: 0) {
                        Text("Find friends\non the map")
                            .font(VoiidFont.rounded(28, .bold))
                            .foregroundColor(VoiidBrand.text)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.md)

                        Text("Share your location live with the people you choose — on your terms. You're always in control.")
                            .font(VoiidFont.rounded(14.5))
                            .foregroundColor(VoiidBrand.textDim)
                            .multilineTextAlignment(.center)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, VoiidSpacing.lg)
                            .padding(.top, VoiidSpacing.sm)

                        illustration
                            .padding(.top, VoiidSpacing.md)

                        // THE PRIVACY PROMISES — the entire argument for the feature.
                        // Ordered by how quickly each one answers the fear it addresses:
                        // "can I get out?", "who sees me?", "who else sees me?".
                        VStack(spacing: VoiidSpacing.md) {
                            promise("eye.slash", "Ghost Mode anytime",
                                    "Disappear from the map instantly. While you're hidden, Voiid stops taking your location at all.")
                            promise("person.2", "Choose who can see you",
                                    "Name the people who get to see you. There is no “share with everyone”.")
                            promise("lock.fill", "End-to-end protected sharing",
                                    "Voiid's servers never see where you are — only that a share exists, and when it ends.")
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.lg)
                        // Breathing room at the bottom of the SCROLL, not the screen: the last
                        // promise should clear the pinned footer's edge when fully scrolled.
                        .padding(.bottom, VoiidSpacing.md)
                    }
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }
                .scrollIndicators(.hidden)
                // The scroll view takes whatever height is left after the fixed chrome, so on
                // a tall device nothing scrolls and on a short one everything is still there.
                .frame(maxHeight: .infinity)

                footer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        // Committed dark: force the dark scheme so any system-drawn affordance inside this
        // screen (scroll bars, the keyboard-less controls) matches the ground it sits on.
        .preferredColorScheme(.dark)
        .onAppear {
            // ease-out, 340ms: an entrance, and the first frame is the one being watched.
            withAnimation(.easeOut(duration: 0.34)) { appeared = true }
        }
    }

    // MARK: - Skip

    private var skipRow: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Skip") {
                Haptics.tap()
                onSkip()
            }
            .font(VoiidFont.rounded(15, .medium))
            .foregroundColor(VoiidBrand.textDim)
            .accessibilityHint("Opens the map in Ghost Mode — nobody can see you")
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    // MARK: - Illustration

    /// A stylised map with three friends on it, DRAWN rather than shipped as an asset — so it
    /// inherits the brand tokens and needs no re-export the next time the accent moves.
    ///
    /// Deliberately abstract: real faces here would imply the user already has friends on the
    /// map, which on a first open is exactly the thing that is not yet true.
    private var illustration: some View {
        ZStack {
            // The "area" — a soft accent field, echoing the coarse circle a Map pin really is.
            RoundedRectangle(cornerRadius: 110, style: .continuous)
                .fill(VoiidBrand.lime.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 110, style: .continuous)
                        .stroke(VoiidBrand.lime.opacity(0.18), lineWidth: 1)
                )

            // Street lines: enough to suggest a map without pretending to be one. A real
            // rendered map here would be a lie — we have no permission and no fix yet.
            ForEach(0..<3, id: \.self) { i in
                Capsule()
                    .fill(VoiidBrand.hairline)
                    .frame(width: 190, height: 2)
                    .rotationEffect(.degrees(Double(i) * 34 - 34))
                    .offset(y: CGFloat(i) * 26 - 26)
            }

            // The user's own pin, centred and largest — the map is drawn from where they are.
            ZStack {
                Circle()
                    .fill(VoiidBrand.lime.opacity(0.22))
                    .frame(width: 92, height: 92)
                    .blur(radius: 14)

                Image(systemName: "mappin.circle.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(VoiidBrand.onLime, VoiidBrand.lime)
            }

            friendBubble("person.fill", x: -100, y: -46)
            friendBubble("person.fill", x:  102, y: -32)
            friendBubble("person.fill", x:  -54, y:  58)
        }
        // Fixed height so the pinned footer's position never depends on this block, and the
        // scroll's content height stays predictable across devices.
        .frame(height: 190)
        .padding(.horizontal, VoiidSpacing.md)
        .accessibilityHidden(true)
    }

    private func friendBubble(_ symbol: String, x: CGFloat, y: CGFloat) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 17, weight: .semibold))
            .foregroundColor(VoiidBrand.textDim)
            .frame(width: 42, height: 42)
            .background(Circle().fill(VoiidBrand.row))
            .overlay(Circle().stroke(VoiidBrand.ground, lineWidth: 2.5))
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(VoiidColor.success)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(VoiidBrand.ground, lineWidth: 2))
            }
            .offset(x: x, y: y)
    }

    // MARK: - Promises

    private func promise(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(VoiidBrand.limeBright)
                .frame(width: 34, height: 34)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(VoiidBrand.lime.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidBrand.text)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        // One accessibility element per promise: three separate labels read as a list, six
        // fragments read as noise.
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    /// PINNED, never scrolled. The primary action of an onboarding screen must be on screen
    /// at the moment the screen appears, at every device height — a Continue button you have
    /// to discover by dragging is a Continue button a share of users never press.
    private var footer: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.rigid()
                onContinue()
            } label: {
                Text("Continue")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidBrand.onLime)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                            .fill(VoiidBrand.lime)
                    )
            }
            .buttonStyle(SoftPressStyle())

            Text("You stay hidden until you choose someone.")
                .font(VoiidFont.rounded(12))
                .foregroundColor(VoiidBrand.placeholder)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.md)
        // A hairline above the footer so it reads as chrome once content scrolls under it,
        // rather than as the last item in the list.
        .background(
            VoiidBrand.ground
                .overlay(alignment: .top) { VoiidBrand.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
