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
                    TermsScreen(logoNS: logoNS, onContinue: { path.append(.permissions) })
                        .navigationDestination(for: Step.self) { step in
                            switch step {
                            case .permissions: PermissionsScreen(onContinue: { path.append(.phone) })
                            case .phone:   PhoneScreen(onContinue: { phone, vid in path.append(.otp(phone: phone, verificationID: vid)) })
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
struct TermsScreen: View {
    var logoNS: Namespace.ID
    let onContinue: () -> Void
    @State private var agreed = false
    @State private var contentIn = false
    /// Set by tapping a link in the consent line; presented as a sheet because this screen
    /// is the root of the navigation stack and pushing would replace the consent context.
    @State private var presentedDocument: LegalDocument?

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(spacing: 0) {
                Spacer().frame(height: 60)
                LogoMark(size: VoiidScreen.width * (300.0 / 402.0), fontSize: 80)
                    .matchedGeometryEffect(id: "voiidLogo", in: logoNS)

                Spacer()

                Group {
                HStack(spacing: VoiidSpacing.sm) {
                    Button { toggleAgreement() } label: {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(VoiidColor.textSecondary, lineWidth: 1)
                            .background(agreed ? VoiidColor.primary : Color.clear)
                            .frame(width: 16, height: 16)
                            .overlay(agreed ? Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(VoiidColor.textOnPrimary) : nil)
                            .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                    .accessibilityLabel("I accept the Terms & Conditions and Privacy Policy")
                    .accessibilityAddTraits(agreed ? [.isSelected] : [])
                    // One `Text` carrying an AttributedString, not four concatenated ones:
                    // concatenation cannot hold a link, and the design needs this to stay on
                    // a single 13pt line. The link targets use a private scheme handled by
                    // the `openURL` action below — nothing here reaches the network.
                    Text(consentLine)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                        .environment(\.openURL, OpenURLAction { url in
                            guard url.scheme == Self.legalScheme,
                                  let doc = LegalDocuments.all.first(where: { $0.id == url.host }) else {
                                return .discarded
                            }
                            Haptics.tap()
                            presentedDocument = doc
                            return .handled
                        })
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
        .sheet(item: $presentedDocument) { doc in
            NavigationStack {
                LegalDocumentView(document: doc, showsDoneButton: true)
            }
            .preferredColorScheme(nil)
        }
    }

    // MARK: - Consent

    /// Private URL scheme for the two in-app documents. Not `https`: these documents are in
    /// the binary, and a scheme that looks like the web would eventually be "fixed" by
    /// someone into a real URL that 404s.
    private static let legalScheme = "voiid-legal"

    /// The consent sentence, with both document names as real links.
    ///
    /// Underlined as well as coloured. Colour alone is not an affordance — it fails for
    /// colour-blind users and it fails against this screen's low-contrast secondary token,
    /// which is exactly how "Privacy Policy" managed to look like a link for months while
    /// being inert text.
    private var consentLine: AttributedString {
        var line = AttributedString("I accept the ")

        var terms = AttributedString("Terms & Conditions")
        terms.font = VoiidFont.rounded(13, .semibold)
        terms.link = URL(string: "\(Self.legalScheme)://terms")
        terms.underlineStyle = .single

        var and = AttributedString(" and ")
        and.foregroundColor = VoiidColor.textPrimary

        var privacy = AttributedString("Privacy Policy")
        privacy.font = VoiidFont.rounded(13, .semibold)
        privacy.link = URL(string: "\(Self.legalScheme)://privacy")
        privacy.underlineStyle = .single

        line.append(terms)
        line.append(and)
        line.append(privacy)
        return line
    }

    /// Ticking IS the consent, so it is recorded here rather than on Continue: a user who
    /// ticks and then abandons the flow still ticked, and a crash between the two must not
    /// lose the record. Un-ticking clears it — a retracted tick is an absence of consent,
    /// not a withdrawal, and posting it later would manufacture agreement.
    private func toggleAgreement() {
        withAnimation(.spring(response: 0.25)) { agreed.toggle() }
        if agreed {
            ConsentService.shared.recordLocalConsent(
                purposes: Dictionary(uniqueKeysWithValues:
                    LegalDocuments.purposes.map { ($0.id, true) }))
        } else {
            ConsentService.shared.clearLocalConsent()
        }
    }
}

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

