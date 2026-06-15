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
    var body: some View {
        ZStack {
            VoiidBackground()
            LogoMark(size: 325, fontSize: 80)
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
                LogoMark(size: 300, fontSize: 72)

                VStack(spacing: VoiidSpacing.sm) {
                    RoundedRectangle(cornerRadius: VoiidRadius.md)
                        .fill(VoiidColor.fieldFill)
                        .frame(width: 120, height: 120)
                        .overlay(Image(systemName: "bubble.left.and.bubble.right.fill")
                            .font(.system(size: 44)).foregroundColor(VoiidColor.accent))
                    Text("Talk. See. Share")
                        .font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
                }
                .padding(.top, VoiidSpacing.lg)

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
    var size: CGFloat
    var fontSize: CGFloat
    var body: some View {
        ZStack {
            // Soft neumorphic ring embossed into the #DFDFDF surface (subtle, like the design).
            Circle()
                .stroke(VoiidColor.background, lineWidth: 26)
                .frame(width: size, height: size)
                .shadow(color: .black.opacity(0.10), radius: 16, x: 8, y: 8)
                .shadow(color: .white.opacity(0.85), radius: 16, x: -8, y: -8)
                .blur(radius: 1)
                .opacity(0.9)

            // Glassy / chrome "voiid" wordmark — white→silver→lavender gradient with a soft emboss.
            Text("voiid")
                .font(.custom("Urbanist-Bold", size: fontSize))
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.white, Color(hex: 0xF2EAF0), Color(hex: 0xCFC3D0), Color.white],
                        startPoint: .top, endPoint: .bottom)
                )
                .shadow(color: .white.opacity(0.9), radius: 1, x: -1, y: -1)
                .shadow(color: VoiidColor.primary.opacity(0.18), radius: 2, x: 1, y: 2)
        }
    }
}
