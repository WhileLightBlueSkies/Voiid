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

    var body: some View {
        ZStack {
            if showSplash {
                SplashScreen()
                    .transition(.opacity)
                    .task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation(.easeInOut(duration: 0.5)) { showSplash = false }
                    }
            } else {
                NavigationStack(path: $path) {
                    TermsScreen(onContinue: { path.append(.phone) })
                        .navigationDestination(for: Step.self) { step in
                            switch step {
                            case .phone:   PhoneScreen(onContinue: { path.append(.otp) })
                            case .otp:     OTPScreen(onContinue: { path.append(.signup) })
                            case .signup:  SignupScreen(onContinue: { path.append(.profile) })
                            case .profile: CreateProfileScreen(onFinish: { session.completeOnboarding() })
                            }
                        }
                }
            }
        }
    }
}

// MARK: - Splash (exact Figma — Urbanist logo, embossed on #DFDFDF)

struct SplashScreen: View {
    @State private var appear = false
    // Ellipse scales per device (design ref 325 on 402). Wordmark stays fixed 80 per spec.
    private var ellipse: CGFloat { UIScreen.main.bounds.width * (325.0 / 402.0) }
    var body: some View {
        ZStack {
            VoiidBackground()
            LogoMark(size: ellipse, fontSize: 80)
                .scaleEffect(appear ? 1 : 0.92)
                .opacity(appear ? 1 : 0)
                .animation(.spring(response: 0.8, dampingFraction: 0.7), value: appear)
        }
        .onAppear { appear = true }
    }
}

// MARK: - Terms & Conditions (exact Figma)

struct TermsScreen: View {
    let onContinue: () -> Void
    @State private var agreed = false

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                LogoMark(size: UIScreen.main.bounds.width * (300.0 / 402.0), fontSize: 80)

                Spacer()

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
        }
        .navigationBarBackButtonHidden(true)
    }
}

// MARK: - The embossed "voiid" logo mark (Urbanist) shared by Splash + Terms

struct LogoMark: View {
    /// `size` = ellipse diameter (defaults scale with device width at call sites).
    var size: CGFloat
    var fontSize: CGFloat

    var body: some View {
        ZStack {
            // Ellipse: a #DFDFDF circle on a #DFDFDF background — invisible except for its
            // drop shadow + layer blur, which together produce the soft embossed halo (per design).
            Circle()
                .fill(VoiidColor.background)            // #DFDFDF (matches background)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.18), radius: 24, x: 0, y: 12)  // drop shadow
                .blur(radius: 12)                       // layer blur (softens into a glow)

            // "voiid" wordmark — the EXACT Figma vector (fill + stroke + inner shadow baked in).
            // Asset: Assets.xcassets/VoiidWordmark (SVG, preserves vector data). Native 167x62.
            Image("VoiidWordmark")
                .renderingMode(.original)
                .resizable()
                .scaledToFit()
                .frame(width: size * 0.62)   // ~ wordmark width relative to the ellipse
        }
    }
}

