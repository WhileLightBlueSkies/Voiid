//
//  MapPrivacyScreen.swift
//  Voiid
//
//  The Map's permission step — step 2 of the four-step flow (intro → privacy → map → move).
//
//  ── WHY THIS SCREEN EXISTS ──────────────────────────────────────────────────────
//  Before this, Voiid jumped straight to the iOS location prompt from inside `goVisible`.
//  That is the single most expensive mistake a location feature can make: the system dialog
//  is one-shot, it offers "Allow Once" (which looks safest and silently breaks the feature a
//  day later), and a denial can only be undone in Settings. So the ask is preceded by an
//  explicit, honest statement of WHAT Voiid does and — just as important — what it does NOT.
//
//  Everything claimed here is enforced in code elsewhere, not marketing:
//   - COARSE: presence accuracy is deliberately coarsened before it is ever sent, and
//     `LocationAccuracy.note` says so on the contact card.
//   - NO BACKGROUND TRACKING WHILE HIDDEN: Ghost Mode calls `MapLocationProvider.stop()`,
//     which drops `allowsBackgroundLocationUpdates` too. Not a flag on the server.
//   - NO ADDRESSES: the Map never reverse-geocodes (docs/LOCATION.md §10).
//   - E2EE: only the chosen audience holds the key; the server sees a share, not a place.
//
//  ── THE ASK IS When-In-Use, AND ONLY When-In-Use ────────────────────────────────
//  `MapLocationProvider.requestWhenInUse()` is what this screen drives. Always is requested
//  later, as an UPGRADE, and only once the user has actually chosen to be visible — asking
//  cold shows nothing useful and burns the user's goodwill on a prompt with no context.
//
//  ── COMMITTED DARK ──────────────────────────────────────────────────────────────
//  Pins `VoiidBrand.ground`, so it uses `VoiidBrand.text` / `.textDim` / `.placeholder`.
//  `VoiidColor.textPrimary` is near-BLACK in light mode and would be invisible here.
//

import SwiftUI
import CoreLocation

struct MapPrivacyScreen: View {

    @ObservedObject private var provider = MapLocationProvider.shared

    /// The user answered "allow" and iOS has resolved the prompt (either way — see below).
    var onAllow: () -> Void = {}
    /// The user answered "not now". A real answer, and it is respected.
    var onSkip: () -> Void = {}
    /// Back to the intro.
    var onBack: () -> Void = {}

    /// True from the moment we call into CoreLocation until the delegate reports a status
    /// other than `.notDetermined`. Drives the button's LOADING state, which is otherwise
    /// invisible: the system sheet covers us, and on dismissal there is a beat before the
    /// delegate fires where a live-looking button would invite a second, ignored tap.
    @State private var asking = false

    /// Set when the ask resolved to a REFUSAL. Distinct from "not now": the user tried to
    /// allow and iOS said no (denied, restricted, or a prior denial that shows no prompt at
    /// all), which needs a different sentence and a route to Settings.
    @State private var refused = false

    @State private var appeared = false

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            // Same fixed-chrome / scrolling-middle structure as the intro: the primary action
            // must be on screen at 667pt without a drag.
            VStack(spacing: 0) {
                header

                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Your location.\nYour choice.")
                            .font(VoiidFont.rounded(26, .bold))
                            .foregroundColor(VoiidBrand.text)
                            .fixedSize(horizontal: false, vertical: true)

                        Text("Voiid needs location access to put you on the Map. Here is exactly what that does.")
                            .font(VoiidFont.rounded(14.5))
                            .foregroundColor(VoiidBrand.textDim)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 6)

                        sectionLabel("WHAT VOIID DOES")
                            .padding(.top, VoiidSpacing.lg)

                        VStack(spacing: 8) {
                            fact("checkmark.shield.fill", positive: true,
                                 "Shows an approximate area",
                                 "Your pin is coarsened before it leaves your phone — it is a neighbourhood, not a doorstep.")
                            fact("lock.fill", positive: true,
                                 "Encrypts it end-to-end",
                                 "Only the people you name can decrypt it. Voiid's servers see that a share exists, never where you are.")
                            fact("eye.slash.fill", positive: true,
                                 "Stops the moment you hide",
                                 "Ghost Mode doesn't just hide your pin — it stops your location being taken at all.")
                        }

                        sectionLabel("WHAT VOIID NEVER DOES")
                            .padding(.top, VoiidSpacing.lg)

                        VStack(spacing: 8) {
                            fact("xmark.circle.fill", positive: false,
                                 "No street addresses",
                                 "The Map never turns your position into a place name — not for you, not for anyone watching.")
                            fact("xmark.circle.fill", positive: false,
                                 "No broadcasting to strangers",
                                 "There is no “share with everyone”. Nobody sees you until you pick them by name.")
                            fact("xmark.circle.fill", positive: false,
                                 "No history, no ads",
                                 "Your positions aren't stored as a trail and are never used to target you.")
                        }

                        permissionPreview
                            .padding(.top, VoiidSpacing.lg)

                        if refused {
                            refusalNote
                                .padding(.top, VoiidSpacing.md)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.xs)
                    .padding(.bottom, VoiidSpacing.md)
                    .opacity(appeared ? 1 : 0)
                    .offset(y: appeared ? 0 : 12)
                }
                .scrollIndicators(.hidden)
                .frame(maxHeight: .infinity)

                footer
            }
        }
        .toolbar(.hidden, for: .navigationBar)
        .navigationBarBackButtonHidden(true)
        .preferredColorScheme(.dark)
        .onAppear {
            withAnimation(.easeOut(duration: 0.34)) { appeared = true }
        }
        // THE RESOLUTION PATH. `requestWhenInUse()` returns immediately; the answer arrives
        // here, through the provider's published `authorization`. Watching the published
        // value rather than polling is what makes the loading state end exactly once, and it
        // also catches the case where iOS shows NO prompt (a prior denial) — the status is
        // already `.denied`, so `asking` is cleared on the next publish and the refusal note
        // appears instead of a button that spins forever.
        .onChange(of: provider.authorization) { _, status in
            guard asking, status != .notDetermined else { return }
            asking = false
            if provider.isAuthorized {
                Haptics.success()
                onAllow()
            } else {
                Haptics.rigid()
                withAnimation(.easeOut(duration: 0.2)) { refused = true }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Button {
                Haptics.tap()
                onBack()
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoiidBrand.text)
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(SoftPressStyle())
            .accessibilityLabel("Back")

            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.sm)
        .padding(.top, VoiidSpacing.sm)
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.rounded(11, .semibold))
            .foregroundColor(VoiidBrand.placeholder)
            .tracking(0.6)
            .padding(.bottom, VoiidSpacing.sm)
    }

    // MARK: - Facts

    /// One promise or one refusal. The two lists share a row shape on purpose: the "never"
    /// half is not fine print, it is half the argument, and styling it as a lesser thing is
    /// how a privacy page starts looking like a disclaimer.
    private func fact(_ icon: String, positive: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(positive ? VoiidBrand.limeBright : VoiidBrand.textDim)
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(positive ? VoiidBrand.lime.opacity(0.14) : Color.white.opacity(0.05))
                )

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
        .padding(VoiidSpacing.md - 2)
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Permission preview

    /// A preview of iOS's own dialog. NOT decoration: a user who has already seen what is
    /// coming, and been told which option to pick, says yes. One ambushed by it picks "Allow
    /// Once" and the Map quietly dies tomorrow.
    private var permissionPreview: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("WHAT iOS WILL ASK")
                .font(VoiidFont.rounded(11, .semibold))
                .foregroundColor(VoiidBrand.placeholder)
                .tracking(0.6)

            HStack(alignment: .top, spacing: VoiidSpacing.md) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("“Allow Voiid to use your location?”")
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(VoiidBrand.text)
                        .fixedSize(horizontal: false, vertical: true)

                    // Naming the exact option matters. "Allow Once" is the one that looks
                    // safest to a cautious user and breaks the feature by the next launch.
                    Text("Choose “While Using the App”. “Once” expires as soon as you close Voiid, and the Map goes dark without telling you why.")
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidBrand.textDim)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "location.fill")
                    .font(.system(size: 22))
                    .foregroundColor(VoiidBrand.onLime)
                    .frame(width: 52, height: 52)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(VoiidBrand.lime))
            }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidBrand.field)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.fieldEdge, lineWidth: 1)
        )
    }

    // MARK: - Refusal (the FAILED state)

    /// Shown only after an ask that came back denied. The button below becomes "Open
    /// Settings", because re-asking is impossible — iOS will never show the prompt again, and
    /// a button that silently does nothing is worse than no button.
    private var refusalNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundColor(VoiidColor.warning)

            VStack(alignment: .leading, spacing: 2) {
                Text("Location is switched off for Voiid")
                    .font(VoiidFont.rounded(13.5, .semibold))
                    .foregroundColor(VoiidBrand.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("iOS won't ask again from here. You can turn it on in Settings, or carry on to the Map in Ghost Mode and decide later.")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.md - 2)
        .background(VoiidColor.warning.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(VoiidColor.warning.opacity(0.35), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                if refused {
                    // Settings is the ONLY route left. Anything else here would be theatre.
                    Haptics.tap()
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                } else {
                    Haptics.rigid()
                    asking = true
                    provider.requestWhenInUse()
                }
            } label: {
                HStack(spacing: VoiidSpacing.sm) {
                    if asking {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(VoiidBrand.onLime)
                    }
                    Text(asking ? "Waiting for iOS…"
                         : (refused ? "Open Settings" : "Allow location access"))
                        .font(VoiidFont.rounded(16, .semibold))
                }
                .foregroundColor(VoiidBrand.onLime)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .background(
                    RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                        .fill(VoiidBrand.lime)
                )
            }
            .buttonStyle(SoftPressStyle())
            // Double-tapping while the system sheet is up would queue a second, pointless ask.
            .disabled(asking)
            .opacity(asking ? 0.85 : 1)

            // "Not now" reaches the map too, in Ghost Mode. Refusing a permission is a real
            // answer, and stranding someone on this screen for giving it is the exact coercion
            // the intro promised not to apply.
            Button("Not now") {
                Haptics.tap()
                onSkip()
            }
            .font(VoiidFont.rounded(15, .semibold))
            .foregroundColor(VoiidBrand.limeBright)
            .disabled(asking)
            .opacity(asking ? 0.5 : 1)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .padding(.bottom, VoiidSpacing.md)
        .background(
            VoiidBrand.ground
                .overlay(alignment: .top) { VoiidBrand.hairline.frame(height: 1) }
                .ignoresSafeArea(edges: .bottom)
        )
    }
}
