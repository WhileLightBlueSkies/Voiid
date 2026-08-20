//
//  OnboardingFlow.swift
//  Voiid
//
//  Splash → Terms → Phone → OTP → Signup → Create Profile → main app.
//  Splash + Terms keep the exact Figma design (Urbanist logo). From Phone onward: SF Pro Rounded.
//

import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject var session: AppSession
    @State private var path: [Step] = []
    @State private var showSplash = true

    // `profile` carries the draft from step 1 rather than reading it back out of the session:
    // the draft holds the username and photo, which are NOT session properties, and threading
    // them through the route is what lets the save happen once on the second page.
    enum Step: Hashable {
        case permissions
        case phone
        case otp(phone: String, verificationID: String)
        /// The success beat between a verified code and whatever follows it. `next` carries the
        /// destination because verification has TWO exits — a new user goes on to sign up, a
        /// returning one straight into the app — and the screen itself should not know which.
        case verified(next: VerifiedNext)
        case signup(phone: String)
        case profile(draft: ProfileDraft)
    }

    /// Where `verified` hands off to once the moment has played.
    enum VerifiedNext: Hashable {
        case signup(phone: String)
        case enterApp
    }

    @Namespace private var logoNS

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if showSplash {
                // NO ANIMATION ON THE HANDOFF, deliberately.
                //
                // This was a shared-element transition: the wordmark flew from the splash into
                // the Terms header via `matchedGeometryEffect`. Several rounds of tuning could
                // not make it clean — `matchedGeometryEffect` INTERPOLATES FRAMES, so the text
                // was rasterised and resampled for the whole flight. That produced a soft ghost
                // behind the glyphs and a landing that read as a loading state, and no amount of
                // curve or duration work addresses it, because the artefact comes from scaling
                // text rather than from timing.
                //
                // A plain cut has none of those problems and costs nothing: the splash is a
                // 1.2s brand frame, seen once per launch, and what follows it is a screen the
                // user has to READ. Motion was never doing work here.
                //
                // If this is ever revisited, the honest fix is a wordmark rendered at ONE size
                // on both ends and never scaled — not a better spring.
                SplashScreen(logoNS: logoNS)
                    .zIndex(1)
                    .task {
                        // 1.2s. Long enough for the mark to be read; past that it stops reading
                        // as a brand moment and starts reading as a load screen.
                        try? await Task.sleep(nanoseconds: 1_200_000_000)
                        showSplash = false
                    }
            } else {
                NavigationStack(path: $path) {
                    WelcomeTermsScreen(logoNS: logoNS,
                                       onContinue: { path.append(.permissions) },
                                       onExistingAccount: { session.completeOnboarding() })
                        .navigationDestination(for: Step.self) { step in
                            switch step {
                            case .permissions: PermissionsScreen(onContinue: { path.append(.phone) })
                            case .phone:   PhoneScreen(onContinue: { phone, vid in path.append(.otp(phone: phone, verificationID: vid)) },
                                                       onBack: { path.removeLast() })
                            case .otp(let phone, let vid):
                                // Both exits route through `.verified` rather than jumping
                                // straight on: the code being accepted is the moment the account
                                // becomes real, and it is also when loginWithFirebase and the E2E
                                // bootstrap are still settling. Showing the confirmation turns
                                // that unavoidable wait into the honest version of a loading state.
                                OTPScreen(onContinue: { path.append(.verified(next: .signup(phone: phone))) },
                                          onExistingUser: { path.append(.verified(next: .enterApp)) },
                                          // "Change" pops back to the phone step rather than
                                          // pushing a new one, so the stack does not grow a
                                          // phone → otp → phone chain each time it is used.
                                          onChangeNumber: { path.removeLast() },
                                          phoneNumber: phone, e164: phone, verificationID: vid)
                            case .verified(let next):
                                VerifiedScreen(onFinished: {
                                    switch next {
                                    case .signup(let phone): path.append(.signup(phone: phone))
                                    case .enterApp:          session.completeOnboarding()
                                    }
                                })
                            case .signup(let phone):
                                SignupScreen(onContinue: { draft in
                                                 path.append(.profile(draft: draft))
                                             },
                                             phone: phone)
                            case .profile(let draft):
                                CreateProfileScreen(draft: draft,
                                                    onFinish: { session.completeOnboarding() })
                            }
                        }
                }
            }
        }
        // The ground belongs to the CONTAINER, not to either branch. Both screens sit on the
        // same near-black, so painting it once here means the splash can be removed without the
        // ground blinking — which is what would otherwise show through mid-handoff.
        .background(VoiidBrand.ground.ignoresSafeArea())
    }
}

// MARK: - Splash (Urbanist logo, embossed on the Voiid ground)

struct SplashScreen: View {
    /// Unused — the shared-element handoff was removed (see `OnboardingFlow`). Kept on the type
    /// so the call site does not have to change if it is ever restored.
    var logoNS: Namespace.ID

    // Ellipse scales per device (design ref 325 on 402).
    private var ellipse: CGFloat { VoiidScreen.width * (325.0 / 402.0) }

    var body: some View {
        ZStack {
            // NO GROUND OF ITS OWN. The container paints the near-black behind both branches
            // (see OnboardingFlow.body), so there is one continuous backdrop and no flash when
            // the splash is swapped out.
            LogoMark(size: ellipse, fontSize: 80)
        }
        // The status bar's glyphs have to read against near-black, and in light mode they would
        // be drawn dark on dark.
        .preferredColorScheme(.dark)
    }
}

// MARK: - Terms & Conditions (exact Figma)

/// The consent screen — and, since this is where the affirmative action actually happens,
/// the DPDP s.5/s.6 surface of the whole app.
///
/// WHAT CHANGED AND WHY
/// --------------------
/// "Terms & Conditions" and "Privacy Policy" used to be plain `Text` inside a single
/// concatenated string: users ticked a box agreeing to two documents they could not open,
/// and no document existed to open. Both halves are fixed — the documents are bundled
/// (`Legal/LegalDocuments.swift`) and both phrases are now real links.
///
/// The tick is also *recorded* now. `POST /users/consent` had existed for months with zero
/// callers, so `consent_given_at` was null for every account ever created. It cannot be
/// posted from here — there is no account and no token until several screens later — so
/// the decision is stored locally the moment it is made and flushed once an account
/// exists (see `ConsentService`).
///
/// "I already have an account" deliberately does not record consent: someone signing back
/// in has not been shown this notice as a decision. They are caught by the backfill prompt
/// after sign-in (`ContentView`), which asks properly rather than assuming.
///
/// `@MainActor` on the whole struct, not just `body`: the link handler and the tick
/// handler both touch `ConsentService` (a main-actor singleton) and `@State`, and leaving
/// them nonisolated would make that a concurrency diagnostic the first time this file is
/// compiled under stricter checking.
// MARK: - The embossed "voiid" logo mark (Urbanist) shared by Splash + Terms

struct LogoMark: View {
    /// `size` = the composition's overall extent. The mark takes a fraction of it (see
    /// `markSize`) so the lockup keeps breathing room rather than filling the frame.
    var size: CGFloat
    var fontSize: CGFloat   // kept for call-site compatibility; unused (the lockup derives it)

    /// 0.42 of the extent: the splash passes its ellipse diameter as `size`, which is the
    /// composition's extent rather than the mark's. Rendering the mark at full width would have
    /// it fill that space edge to edge and lose the air the design is built around.
    private var markSize: CGFloat { size * 0.42 }

    var body: some View {
        // Gap derived from the WORDMARK, not the mark, so the word sits close under the V
        // rather than a mark-proportional distance below it.
        VStack(spacing: OnboardingHeader.wordmarkSize * 0.42) {
            VoiidMark(size: markSize)

            BrandWordmark(size: OnboardingHeader.wordmarkSize,
                          color: .white,
                          dotColor: VoiidBrand.lime)
        }
    }
}
