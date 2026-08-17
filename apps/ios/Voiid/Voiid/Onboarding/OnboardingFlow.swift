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

    enum Step: Hashable { case permissions, phone, otp(phone: String, verificationID: String), signup(phone: String), profile }

    @Namespace private var logoNS

    var body: some View {
        ZStack {
            if showSplash {
                SplashScreen(logoNS: logoNS)
                    .transition(.opacity)
                    .zIndex(1)
                    .task {
                        try? await Task.sleep(nanoseconds: 1_900_000_000)
                        // Elastic, connected move: logo glides from splash center up to Terms.
                        withAnimation(.spring(response: 0.75, dampingFraction: 0.82)) {
                            showSplash = false
                        }
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
                                OTPScreen(onContinue: { path.append(.signup(phone: phone)) },
                                          onExistingUser: { session.completeOnboarding() },
                                          phoneNumber: phone, e164: phone, verificationID: vid)
                            case .signup(let phone):
                                SignupScreen(onContinue: { path.append(.profile) }, phone: phone)
                            case .profile: CreateProfileScreen(onFinish: { session.completeOnboarding() })
                            }
                        }
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Splash (Urbanist logo, embossed on the Voiid ground)

struct SplashScreen: View {
    var logoNS: Namespace.ID
    @State private var appear = false
    // Ellipse scales per device (design ref 325 on 402). Wordmark stays fixed 80 per spec.
    private var ellipse: CGFloat { VoiidScreen.width * (325.0 / 402.0) }
    var body: some View {
        ZStack {
            VoiidBackground()
            LogoMark(size: ellipse, fontSize: 80)
                .matchedGeometryEffect(id: "voiidLogo", in: logoNS)
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: appear)
        }
        .onAppear { appear = true }
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
@MainActor
// MARK: - The embossed "voiid" logo mark (Urbanist) shared by Splash + Terms

struct LogoMark: View {
    /// `size` = rendered diameter of the full logo mark (wordmark + halo).
    var size: CGFloat
    var fontSize: CGFloat   // kept for call-site compatibility; unused (logo is a baked image)

    var body: some View {
        // PLACEHOLDER until the real mark lands — see DesignSystem/BrandMark.swift for what to
        // swap and where. Drawn rather than an empty `Image("VoiidLogoMark")`, which would
        // render nothing and read as a broken build on the FIRST screen a new user sees.
        BrandWordmark(size: size * 0.30, color: VoiidColor.primary)
    }
}

