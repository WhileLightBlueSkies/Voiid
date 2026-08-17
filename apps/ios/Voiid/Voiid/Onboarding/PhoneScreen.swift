//
//  PhoneScreen.swift
//  Voiid
//
//  Onboarding — phone entry, built to the brand reference. Shares its chrome with
//  WelcomeTermsScreen and PermissionsScreen via OnboardingBrandChrome.
//
//  The Firebase send is unchanged from the previous version of this screen: only the
//  presentation is new.
//

import SwiftUI

struct PhoneScreen: View {
    /// Passes the E.164 number + Firebase verificationID to the OTP step.
    let onContinue: (String, String) -> Void
    /// Back to the permissions step. Optional so the screen still works if it is ever the root.
    var onBack: (() -> Void)? = nil

    @State private var phone = ""
    @State private var country = Country.default   // India default
    @State private var showPicker = false
    @State private var sending = false
    @State private var errorText: String?
    @State private var appeared = false
    @State private var showHelp = false
    @FocusState private var focused: Bool

    /// Digits only, so formatting characters a keyboard might insert never reach the wire.
    private var digits: String { phone.filter(\.isNumber) }

    /// Enough digits to be worth sending. Deliberately loose: national number lengths vary from
    /// 6 to 12, and a client that enforces a per-country length rejects legitimate numbers in
    /// places nobody tested. Firebase is the real validator.
    private var valid: Bool { digits.count >= 6 }

    /// Send the OTP via Firebase, then advance to the OTP screen with the verificationID.
    private func sendOtp() {
        guard !sending, valid else { return }
        sending = true; errorText = nil
        let e164 = "\(country.dialCode)\(digits)"
        Task {
            do {
                let verificationID = try await FirebasePhoneAuth.sendCode(to: e164)
                Haptics.tap(); onContinue(e164, verificationID)
            } catch {
                errorText = error.localizedDescription
                Haptics.error()
            }
            sending = false
        }
    }

    var body: some View {
        ZStack {
            OnboardingBrand.ground
                .ignoresSafeArea()
                .dismissKeyboardOnTap()

            VStack(spacing: 0) {
                OnboardingTopBar(
                    onBack: onBack.map { back in { back() } },
                    onHelp: { showHelp = true }
                )
                .padding(.top, 4)

                ScrollView(.vertical, showsIndicators: false) {
                  VStack(spacing: 0) {
                    OnboardingBrandHeader(appeared: appeared)

                    // The WORDMARK sits under the mark on this screen, which the first two do
                    // not have — the design gives phone entry the full lockup.
                    BrandWordmark(size: 38, color: VoiidColor.textPrimary)

                    OnboardingTitle(leading: "Enter your ", accented: "phone number")
                        .padding(.top, 10)

                    Text("We will send you a verification code\nto confirm your number.")
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.top, 8)

                    numberField
                        .padding(.horizontal, 20)
                        .padding(.top, 22)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                    }

                    safetyNote
                        .padding(.horizontal, 24)
                        .padding(.top, 18)

                    OnboardingTrustStrip(items: Self.trustItems)
                        .padding(.horizontal, 20)
                        .padding(.top, 16)
                        .padding(.bottom, 16)
                  }
                }

                OnboardingPrimaryButton(title: "Continue", busy: sending) { sendOtp() }
                    .padding(.horizontal, 20)
                    .opacity(valid ? 1 : 0.45)
                    .disabled(!valid)

                legalLine
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
                    .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .navigationBarBackButtonHidden(true)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
        .sheet(isPresented: $showPicker) {
            CountryPickerSheet(selected: $country)
        }
        .sheet(isPresented: $showHelp) {
            NavigationStack {
                LegalDocumentView(document: LegalDocuments.privacy, showsDoneButton: true)
            }
        }
    }

    // MARK: Number field

    /// Dial code and number in ONE pill, split by a hairline.
    ///
    /// One field rather than two: they are one value, and two separate pills invite the user to
    /// type the country code into the number half — which then fails validation for a reason
    /// the screen never explains.
    private var numberField: some View {
        HStack(spacing: 0) {
            Button {
                Haptics.tap()
                showPicker = true
            } label: {
                HStack(spacing: 8) {
                    Text(country.flag).font(.system(size: 22))
                    Text(country.dialCode)
                        .font(VoiidFont.rounded(17, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(VoiidColor.accent)
                }
                .padding(.horizontal, 14)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.white.opacity(0.04))
                )
            }
            .buttonStyle(.plain)
            .padding(.leading, 8)
            .accessibilityLabel("Country code, \(country.name), \(country.dialCode)")

            Rectangle()
                .fill(OnboardingBrand.hairline)
                .frame(width: 1, height: 40)
                .padding(.horizontal, 12)

            TextField("", text: $phone, prompt:
                Text("Enter phone number").foregroundColor(VoiidColor.placeholder))
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(VoiidFont.rounded(17, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .focused($focused)
                .submitLabel(.go)
                .onSubmit { sendOtp() }
                .padding(.trailing, 16)
        }
        .frame(height: 72)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(OnboardingBrand.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                // The field lights up on focus — the only place the lime outlines something
                // rather than filling it, and it works here because focus is momentary.
                .strokeBorder(focused ? VoiidColor.accent.opacity(0.7) : Color.white.opacity(0.08),
                              lineWidth: focused ? 1.5 : 1)
        )
        .animation(.easeOut(duration: 0.18), value: focused)
    }

    // MARK: Safety note

    private var safetyNote: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(VoiidColor.accent)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your number is safe with us")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("We never share your number with anyone.")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: Legal line

    /// Consent was already given on the welcome screen; this is a reminder, not a second gate.
    /// The two document names are still tappable, because a reminder the user cannot act on is
    /// decoration.
    private var legalLine: some View {
        VStack(spacing: 2) {
            (
                Text("By continuing, you agree to Voiid's ")
                    .foregroundColor(VoiidColor.textSecondary)
                + Text("Terms of Service")
                    .foregroundColor(VoiidColor.accent)
            )
            (
                Text("and acknowledge our ")
                    .foregroundColor(VoiidColor.textSecondary)
                + Text("Privacy Policy")
                    .foregroundColor(VoiidColor.accent)
                + Text(".")
                    .foregroundColor(VoiidColor.textSecondary)
            )
        }
        .font(VoiidFont.rounded(13, .regular))
        .multilineTextAlignment(.center)
        .onTapGesture {
            Haptics.tap()
            showHelp = true
        }
    }

    // MARK: Trust strip

    private static let trustItems: [OnboardingTrustStrip.Item] = [
        .init(id: "e2ee", system: "lock", line1: "End-to-end", line2: "encrypted"),
        .init(id: "private", system: "checkmark.shield", line1: "Private &", line2: "secure"),
        .init(id: "nospam", system: "person.2", line1: "No spam", line2: "promises"),
        .init(id: "control", system: "checkmark.seal", line1: "You're in", line2: "control"),
    ]
}
