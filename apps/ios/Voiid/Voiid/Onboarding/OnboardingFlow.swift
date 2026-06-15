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

    enum Step: Hashable { case phone, otp, signup, profile }

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
                    TermsScreen(logoNS: logoNS, onContinue: { path.append(.phone) })
                        .navigationDestination(for: Step.self) { step in
                            switch step {
                            case .phone:   PhoneScreen(onContinue: { path.append(.otp) })
                            case .otp:     OTPScreen(onContinue: { path.append(.signup) })
                            case .signup:  SignupScreen(onContinue: { path.append(.profile) })
                            case .profile: CreateProfileScreen(onFinish: { session.completeOnboarding() })
                            }
                        }
                }
                .transition(.opacity)
            }
        }
    }
}

// MARK: - Splash (exact Figma — Urbanist logo, embossed on #DFDFDF)

struct SplashScreen: View {
    var logoNS: Namespace.ID
    @State private var appear = false
    // Ellipse scales per device (design ref 325 on 402). Wordmark stays fixed 80 per spec.
    private var ellipse: CGFloat { UIScreen.main.bounds.width * (325.0 / 402.0) }
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

struct TermsScreen: View {
    var logoNS: Namespace.ID
    let onContinue: () -> Void
    @State private var agreed = false
    @State private var contentIn = false

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                LogoMark(size: UIScreen.main.bounds.width * (300.0 / 402.0), fontSize: 80)
                    .matchedGeometryEffect(id: "voiidLogo", in: logoNS)

                Spacer()

                Group {
                HStack(spacing: VoiidSpacing.sm) {
                    Button { withAnimation(.spring(response: 0.25)) { agreed.toggle() } } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(VoiidColor.textSecondary, lineWidth: 1)
                            .background(agreed ? VoiidColor.primary : Color.clear)
                            .frame(width: 16, height: 16)
                            .overlay(agreed ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white) : nil)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    // SF Pro Rounded; "Terms & Conditions" emphasized like the design
                    (Text("I accept the ")
                        + Text("Terms & Conditions").fontWeight(.semibold)
                        + Text(" and ")
                        + Text("Privacy Policy").foregroundColor(VoiidColor.textSecondary))
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, VoiidSpacing.md)

                Button(action: { if agreed { Haptics.tap(); onContinue() } }) {
                    Text("Continue")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(width: 300, height: 64)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                        .opacity(agreed ? 1 : 0.5)
                }
                .disabled(!agreed)

                Button("I already have an account") { onContinue() }
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.top, VoiidSpacing.md)

                Text("v1.0.0 (15)")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.lg)
                }
                // Content fades + slides up after the logo settles (staggered reveal).
                .opacity(contentIn ? 1 : 0)
                .offset(y: contentIn ? 0 : 16)
            }
        }
        .navigationBarBackButtonHidden(true)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45).delay(0.25)) { contentIn = true }
        }
    }
}

// MARK: - The embossed "voiid" logo mark (Urbanist) shared by Splash + Terms

struct LogoMark: View {
    /// `size` = rendered diameter of the full logo mark (wordmark + halo).
    var size: CGFloat
    var fontSize: CGFloat   // kept for call-site compatibility; unused (logo is a baked image)

    var body: some View {
        // Full Figma logo mark exported as one image: the "voiid" wordmark + soft halo together.
        // Asset: Assets.xcassets/VoiidLogoMark (drop voiid-logomark.png into that imageset).
        Image("VoiidLogoMark")
            .resizable()
            .scaledToFit()
            .frame(width: size)
    }
}

