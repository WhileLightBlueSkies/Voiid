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
    // Ellipse = 325/402 of screen width (design ref), scales per device.
    private var ellipse: CGFloat { UIScreen.main.bounds.width * (325.0 / 402.0) }
    private var logoSize: CGFloat { UIScreen.main.bounds.width * (80.0 / 402.0) }
    var body: some View {
        ZStack {
            VoiidBackground()
            LogoMark(size: ellipse, fontSize: logoSize)
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
                LogoMark(size: UIScreen.main.bounds.width * (300.0 / 402.0),
                         fontSize: UIScreen.main.bounds.width * (72.0 / 402.0))

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

            // "voiid" wordmark — exact Figma spec.
            // Fill #FFFFFF, inside stroke #E8E0E0 2.6, inner shadow x-4 y-4 blur4 #222B59@63%.
            VoiidWordmark(fontSize: fontSize)
        }
    }
}

/// The "voiid" wordmark with the exact Figma fill/stroke/inner-shadow treatment.
/// Inner shadow is faked via a masked, offset dark copy (SwiftUI Text has no inner shadow).
struct VoiidWordmark: View {
    var fontSize: CGFloat
    private let stroke = Color(hex: 0xE8E0E0)
    private let innerShadow = Color(hex: 0x222B59).opacity(0.63)

    var body: some View {
        ZStack {
            // Base white fill
            text(.white)
            // Inner-shadow effect: dark text offset by (-4,-4), blurred, clipped to the glyphs
            text(innerShadow)
                .offset(x: -4, y: -4)
                .blur(radius: 4)
                .mask(text(.white))
            // Inside stroke ~2.6 via a subtle outline overlay
            text(.white)
                .overlay(text(stroke).blur(radius: 0.6).mask(text(.white)).opacity(0.8))
        }
    }

    private func text(_ color: Color) -> some View {
        Text("voiid")
            .font(.custom("Urbanist-Bold", size: fontSize))
            .foregroundColor(color)
    }
}
