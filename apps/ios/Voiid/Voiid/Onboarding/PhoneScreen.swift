//
//  PhoneScreen.swift
//  Voiid
//
//  Enter your phone number — the onboarding step after Permissions.
//
//  Built to the design source (`Voiid Ui/Screens/PhoneNumberScreen.swift`) through
//  `OnboardingKit`, so the sizes, paddings and weights are the reference's own numbers. The
//  header is the WORDMARK at 34pt, matching Terms and Permissions.
//
//  ── THIS SCREEN DOES SEND ───────────────────────────────────────────────────────
//  The design source sends nothing — its `onContinue` just hands the number up. The real
//  Firebase send lives here and is UNCHANGED by the restyle: `FirebasePhoneAuth.sendCode`
//  returns a verificationID which the OTP step needs.
//
//  ── THE VALIDATION IS DELIBERATELY SHALLOW ──────────────────────────────────────
//  Continue enables on a plausible LENGTH for the chosen country, and nothing more. It does not
//  claim the number exists or that the user owns it — only the SMS can establish that, so
//  pretending otherwise here would be a lie the next screen has to walk back.
//
//  What it DOES prevent is the obvious dead end: tapping Continue on an empty or half-typed
//  field, waiting for an SMS, and getting nothing.
//
//  ── AUTOFILL HANDS BACK A FULL INTERNATIONAL NUMBER ─────────────────────────────
//  iOS autofill and Contacts supply "+91 98765 43210", not "9876543210". Keeping only the digits
//  leaves the dial code attached, which overflows the field and silently truncates the REAL
//  number — a wrong number that looks correctly entered, invisible until the SMS never arrives.
//  `normalise` strips it, guarded by a length check so a national number beginning with the same
//  digits survives.
//
//  ── THE KEYBOARD GETS OUT OF THE WAY ────────────────────────────────────────────
//  A number pad has no Return key, so it never dismisses itself — and it covers Continue. The
//  field drops focus the moment the number reaches its country's maximum length, which is the
//  one point where there is provably nothing left to type. Variable-length countries never trip
//  that, so there is also a keyboard-toolbar Done.
//
//  Committed to dark, like the rest of onboarding.
//

import SwiftUI

struct PhoneScreen: View {
    /// Passes the E.164 number + Firebase verificationID to the OTP step.
    let onContinue: (String, String) -> Void
    /// Back to the permissions step. Optional so the screen still works if it is ever the root.
    var onBack: (() -> Void)? = nil

    @State private var country = Country.default   // India default
    @State private var digits = ""
    @State private var showingCountries = false
    @State private var sending = false
    @State private var errorText: String?

    /// Drives the field's focused ring. The reference shows the field lit, which reads as "this
    /// is where you are" — so the screen opens with it focused rather than waiting for a tap.
    @FocusState private var fieldFocused: Bool

    /// Digits only, with the country's own dial code stripped, capped at its maximum length.
    ///
    /// The guard is the LENGTH check: a bare national number that happens to start with the dial
    /// digits (a Delhi landline starting "91…") is only stripped if what remains is still a
    /// plausible length, so a legitimate number is never mangled.
    private func normalise(_ raw: String) -> String {
        var d = raw.filter(\.isNumber)

        // The dial code without its "+", e.g. "91".
        let code = country.dialCode.dropFirst()

        if d.count > country.maxDigits, d.hasPrefix(code) {
            let stripped = String(d.dropFirst(code.count))
            if stripped.count >= country.minDigits { d = stripped }
        }

        // Some regions autofill a trunk "0" prefix ("098765..."). Same guard.
        if d.count > country.maxDigits, d.hasPrefix("0") {
            let stripped = String(d.dropFirst())
            if stripped.count >= country.minDigits { d = stripped }
        }

        return String(d.prefix(country.maxDigits))
    }

    /// Plausible length only. See the header on why this is not stricter.
    private var isPlausible: Bool {
        digits.count >= country.minDigits && digits.count <= country.maxDigits
    }

    /// Send the OTP via Firebase, then advance to the OTP screen with the verificationID.
    private func sendOtp() {
        guard !sending, isPlausible else { return }
        sending = true
        errorText = nil
        fieldFocused = false
        let e164 = "\(country.dialCode)\(digits)"
        Task {
            do {
                let verificationID = try await FirebasePhoneAuth.sendCode(to: e164)
                Haptics.tap()
                onContinue(e164, verificationID)
            } catch {
                errorText = error.localizedDescription
                Haptics.error()
            }
            sending = false
        }
    }

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    OnboardingHeader(
                        title: .stacked("Enter your", accent: "phone number"),
                        blurb: "We'll send you a verification code\nto confirm your number."
                    )

                    numberField
                        .padding(.top, VoiidSpacing.lg)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.sm)
                    }

                    VStack(spacing: 10) {
                        ForEach(PhonePromise.all) { promise in
                            PromiseCard(promise: promise)
                        }
                    }
                    .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, 240)
            }
            .scrollIndicators(.hidden)
            // Tapping the background dismisses the keyboard. Without it the only way out of the
            // field on a screen with no other tap target is the Return key, which a number pad
            // does not have.
            .onTapGesture { fieldFocused = false }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footer
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .sheet(isPresented: $showingCountries) {
            CountryPickerSheet(selected: $country) {
                // Clear on change: a number valid for one country is rarely valid for another,
                // and silently keeping it produces a number that looks entered but cannot pass.
                digits = ""
                // Straight back to typing — choosing a country is a step ON THE WAY to entering
                // a number, never the goal, so the field takes focus again without a tap.
                fieldFocused = true
            }
        }
        // Focused after a beat, not immediately: during a navigation PUSH the field is not yet
        // in the responder chain when `onAppear` fires, so setting focus there silently does
        // nothing — which leaves the field grey and the keyboard down. A hop to the next runloop
        // lands after the push completes.
        .task {
            try? await Task.sleep(for: .milliseconds(350))
            fieldFocused = true
        }
    }

    // MARK: The field

    private var numberField: some View {
        HStack(spacing: 0) {
            countryPicker

            // A hairline, not a gap: the dial code and the number are ONE value, and separating
            // them into two boxes would suggest they are entered independently.
            Rectangle()
                .fill(VoiidBrand.hairline)
                .frame(width: 1, height: 34)

            TextField("", text: $digits, prompt:
                Text("Phone number").foregroundColor(VoiidBrand.placeholder)
            )
            .keyboardType(.phonePad)          // includes +*# , which .numberPad omits — pasted
                                              // international numbers would otherwise be rejected
                                              // character-by-character before `normalise` sees them
            .textContentType(.telephoneNumber)
            .font(VoiidFont.rounded(17, .medium))
            .foregroundColor(VoiidBrand.text)
            .focused($fieldFocused)
            .padding(.horizontal, VoiidSpacing.md)
            // The escape hatch for VARIABLE-length countries. Auto-dismiss fires at maxDigits,
            // which a fixed-length country reaches on its last digit — but Germany's range is
            // 6–11, so a valid 9-digit number never trips it and the keyboard would stay up
            // over Continue forever. A toolbar Done is the standard way out of a number pad.
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { fieldFocused = false }
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidBrand.lime)
                }
            }
            // Digits only, capped at the country's own maximum. Filtering on change rather than
            // validating on submit: a keypad can still deliver paste, and a number that silently
            // exceeds its own format is worse than one that stops accepting characters.
            .onChange(of: digits) { _, new in
                let filtered = normalise(new)
                if filtered != new {
                    digits = filtered
                    return          // this fires again with the clean value; act on that pass
                }

                // ── THE KEYBOARD LEAVES WHEN THE NUMBER IS DONE ─────────────────────────
                // A number pad has no Return key, so nothing about it says "finished". The
                // keyboard therefore sat over Continue, and a user who had typed a complete
                // number had to know to tap the background to reach the button they were being
                // asked to press.
                //
                // Only at MAX, never at min. Countries whose range is wide (Germany is 6–11)
                // would otherwise have the keyboard yanked away mid-number, which is far worse
                // than leaving it up.
                if filtered.count == country.maxDigits {
                    fieldFocused = false
                    // Confirms the field took the last digit, on a screen where the keyboard
                    // vanishing is the only other signal.
                    Haptics.soft()
                }
            }
        }
        .frame(height: 62)
        .background(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidBrand.field)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(
                    fieldFocused ? VoiidBrand.lime : VoiidBrand.fieldEdge,
                    lineWidth: fieldFocused ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.18), value: fieldFocused)
    }

    private var countryPicker: some View {
        Button {
            Haptics.tap()
            fieldFocused = false      // the keyboard would otherwise fight the sheet
            showingCountries = true
        } label: {
            HStack(spacing: 8) {
                Text(country.flag)
                    .font(.system(size: 22))
                Text(country.dialCode)
                    .font(VoiidFont.rounded(17, .medium))
                    .foregroundColor(VoiidBrand.text)
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(VoiidBrand.textDim)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Country code, \(country.name), \(country.dialCode)")
        .accessibilityHint("Opens the country list")
    }

    // MARK: Footer

    private var footer: some View {
        OnboardingFooter {
            OnboardingKitButton(title: "Continue", enabled: isPlausible && !sending) {
                sendOtp()
            }

            // What Continue will actually do. Centred under the button, matching the rest of
            // the screen's centred type.
            HStack(spacing: 8) {
                Image(systemName: "lock")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(VoiidBrand.lime)

                Text("We'll send a verification code by SMS.\nMessage and data rates may apply.")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

// MARK: - A promise card

/// One reassurance: icon in a lime disc, copy, and a checkmark holding the right edge.
///
/// The trailing check is separated by a hairline rather than floating: without it the tick reads
/// as an interactive control the user is meant to tap, which is exactly what it is not.
private struct PromiseCard: View {
    let promise: PhonePromise

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: promise.icon)
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(promise.title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.text)

                Text(promise.detail)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }

            Spacer(minLength: 0)

            Rectangle()
                .fill(VoiidBrand.hairline)
                .frame(width: 1, height: 40)

            Image(systemName: "checkmark.shield")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(VoiidBrand.lime)
                .padding(.leading, 4)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 14)
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Data

/// A reassurance shown under the field.
struct PhonePromise: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String

    static let all: [PhonePromise] = [
        .init(id: "secure",
              title: "Secure & private",
              detail: "Your number is encrypted and always private.",
              icon: "lock"),
        .init(id: "nospam",
              title: "No spam. Ever.",
              detail: "We never share your number with anyone.",
              icon: "ellipsis.bubble"),
        .init(id: "identity",
              title: "Used only for you",
              detail: "To verify your identity and keep your account secure.",
              icon: "person"),
    ]
}
