//
//  OTPScreen.swift
//  Voiid
//
//  Enter verification code — the onboarding step after the phone number.
//
//  Built to the design source (`Voiid Ui/Screens/VerificationScreen.swift`) through
//  `OnboardingKit`, so the sizes, paddings and weights are the reference's own numbers.
//
//  ── THE BOXES ARE ONE FIELD WEARING SIX ─────────────────────────────────────────
//  Six separate `TextField`s is the obvious build and the wrong one. It breaks SMS autofill
//  (iOS hands the whole code to ONE field), needs hand-written focus-forwarding on every
//  keypress and backspace, and gets deleting-from-the-middle wrong in ways users find
//  immediately.
//
//  So there is ONE hidden field holding the whole string, and six boxes DRAWING it. Autofill,
//  paste, and backspace then work because they are the system's, not ours.
//
//  ── THIS SCREEN DOES VERIFY ─────────────────────────────────────────────────────
//  The design source checks nothing — its `onVerify` hands the digits up. The real work lives
//  here and is UNCHANGED by the restyle: Firebase verifies the code, the resulting ID token is
//  exchanged for OUR JWT, the verified number is persisted, E2E keys are published, and a
//  returning user with a server-side backup is offered restore before entering the app.
//
//  ── THE TIMER COUNTS SOMETHING REAL ─────────────────────────────────────────────
//  Unlike a launch progress bar, an expiry countdown is honest: the code really does expire.
//  `TimelineView` drives the tick rather than a `Timer` publisher, so a backgrounded app is not
//  burning a timer and the value shown on return is the TRUE remaining time rather than a stale
//  count that kept decrementing in the dark.
//
//  Committed to dark, like the rest of onboarding.
//

import SwiftUI

struct OTPScreen: View {
    @EnvironmentObject private var session: AppSession
    let onContinue: () -> Void
    /// Called instead of onContinue when the user already has a complete profile
    /// (returning user) — skip Signup/Profile and go straight to the app.
    var onExistingUser: () -> Void = {}
    /// Back to the phone step, to correct a wrong number.
    var onChangeNumber: (() -> Void)? = nil
    var phoneNumber: String = "+91 91234567890"
    /// E.164 number (no spaces) used for login. Defaults from `phoneNumber`.
    var e164: String? = nil
    /// Firebase verificationID from the Phone screen's sendCode.
    var verificationID: String = ""

    private let codeLength = 6
    /// How long a Firebase SMS code stays valid.
    private let validFor: TimeInterval = 120

    // Single source of truth: one hidden field holds all 6 digits; boxes display them.
    @State private var code = ""
    @State private var verifying = false
    @State private var resending = false
    @State private var errorText: String?
    /// Set when a returning user has a server-side backup — presents the restore
    /// flow before entering the app. nil = no backup (or not yet checked).
    @State private var restoreMeta: BackupMeta?
    /// The live verificationID. Starts as the one passed in and is REPLACED by a resend —
    /// verifying against the original id after a resend fails, because Firebase invalidates it.
    @State private var activeVerificationID = ""
    @State private var deadline = Date.now
    @FocusState private var focused: Bool

    private var isComplete: Bool { code.count == codeLength }

    /// Normalized E.164 ("+" + digits) for the login call.
    private var phoneE164: String {
        if let e164 { return e164 }
        let digits = phoneNumber.filter { $0.isNumber }
        return "+\(digits)"
    }

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    OnboardingHeader(
                        title: .stacked("Enter verification code", accent: "we sent to you"),
                        blurb: "We've sent a \(codeLength)-digit code to"
                    )

                    recipient
                        .padding(.top, 2)

                    codeBoxes
                        .padding(.top, VoiidSpacing.lg)

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, VoiidSpacing.sm)
                    }

                    expiry
                        .padding(.top, VoiidSpacing.md)

                    securityNote
                        .padding(.top, VoiidSpacing.lg)

                    resendRow
                        .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, 170)
            }
            .scrollIndicators(.hidden)
            .onTapGesture { focused = false }

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                OnboardingFooter {
                    OnboardingKitButton(title: "Verify & Continue",
                                        enabled: isComplete && !verifying) {
                        focused = false
                        Task { await verify() }
                    }
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .task {
            activeVerificationID = verificationID
            startCountdown()
            // Deferred for the same reason as the phone field: during a push the field is not in
            // the responder chain when the view first appears, so focusing there silently fails.
            try? await Task.sleep(for: .milliseconds(350))
            focused = true
        }
        .fullScreenCover(item: $restoreMeta) { meta in
            RestoreMessagesView(meta: meta) {
                restoreMeta = nil
                onExistingUser()
            }
        }
    }

    // MARK: Recipient

    /// The number, with a way back to change it.
    ///
    /// "Change" is here rather than only in the back button because a wrong number is the most
    /// likely reason the code never arrives, and the user should not have to work out that
    /// "back" is how they fix it.
    private var recipient: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Text(phoneNumber)
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidBrand.text)

            if let onChangeNumber {
                Button {
                    Haptics.tap()
                    onChangeNumber()
                } label: {
                    Text("Change")
                        .font(VoiidFont.rounded(15, .medium))
                        .foregroundColor(VoiidBrand.lime)
                }
                .buttonStyle(PressableButtonStyle())
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: The code

    /// Six boxes drawing one field. See the header for why it is built this way.
    private var codeBoxes: some View {
        ZStack {
            // The real field, invisible but focusable and full-width so autofill has a target.
            // `.opacity(0.01)` rather than `.hidden()`: a fully hidden field cannot receive
            // focus, and a zero-opacity one still participates in autofill.
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)     // this is what makes SMS autofill work
                .focused($focused)
                .opacity(0.01)
                .onChange(of: code) { _, new in
                    let filtered = String(new.filter(\.isNumber).prefix(codeLength))
                    if filtered != new {
                        code = filtered
                        return          // fires again with the clean value; act on that pass
                    }
                    // A typed digit that did not complete the code still deserves feedback.
                    if !filtered.isEmpty && filtered.count < codeLength { Haptics.selection() }
                    if filtered.count == codeLength {
                        focused = false
                        Haptics.soft()
                    }
                }

            HStack(spacing: 10) {
                ForEach(0..<codeLength, id: \.self) { index in
                    box(at: index)
                }
            }
            // The boxes are decoration; taps belong to the field beneath them.
            .allowsHitTesting(false)
        }
        // One tap target across the whole row, so a user aiming at any box lands in the field.
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        .accessibilityElement()
        .accessibilityLabel("Verification code")
        .accessibilityValue(code.isEmpty ? "Empty" : code.map(String.init).joined(separator: " "))
    }

    private func box(at index: Int) -> some View {
        let digits = Array(code)
        let filled = index < digits.count
        // The caret sits on the next empty box — or on the last one when the code is full, so a
        // complete code still shows where a backspace would land.
        let isCursor = focused && (index == min(digits.count, codeLength - 1))

        return RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(VoiidColor.fieldFill)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        isCursor ? VoiidBrand.lime : VoiidColor.fieldBorder,
                        lineWidth: isCursor ? 2 : 1
                    )
            )
            .frame(height: 62)
            .overlay {
                if filled {
                    Text(String(digits[index]))
                        .font(VoiidFont.rounded(26, .semibold))
                        .foregroundColor(VoiidBrand.text)
                        .monospacedDigit()
                } else {
                    // An underscore, not an empty box: it shows a character is expected here.
                    Rectangle()
                        .fill(VoiidBrand.textDim.opacity(0.5))
                        .frame(width: 18, height: 2)
                        .offset(y: 12)
                }
            }
            .animation(.easeOut(duration: 0.15), value: isCursor)
            .animation(.easeOut(duration: 0.15), value: filled)
    }

    // MARK: Expiry

    /// The countdown. Real — see the header.
    private var expiry: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            expiryLabel(remaining: max(0, deadline.timeIntervalSince(context.date)))
        }
    }

    @ViewBuilder
    private func expiryLabel(remaining: TimeInterval) -> some View {
        Group {
            if remaining <= 0 {
                Text("The code has expired. Request a new one.")
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.error)
            } else {
                (
                    Text("The code will expire in ")
                        .foregroundColor(VoiidBrand.textDim)
                    + Text(formatted(remaining))
                        .foregroundColor(VoiidBrand.lime)
                        .monospacedDigit()
                )
                .font(VoiidFont.rounded(14))
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityLabel(remaining <= 0
            ? "The code has expired"
            : "Code expires in \(Int(remaining)) seconds")
    }

    /// mm:ss. Built by hand rather than with a DateFormatter because this is a DURATION, and
    /// formatting it as a time-of-day would localize into nonsense in some regions.
    private func formatted(_ t: TimeInterval) -> String {
        let total = max(0, Int(t.rounded(.up)))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private func startCountdown() {
        deadline = .now.addingTimeInterval(validFor)
    }

    // MARK: Security note

    private var securityNote: some View {
        HStack(spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 46, height: 46)
                .overlay {
                    Image(systemName: "lock")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text("Keep your code secure")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.text)

                Text("Never share your code with anyone.\nVoiid will never ask for it.")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
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

    // MARK: Resend

    private var resendRow: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "arrow.clockwise")
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(VoiidBrand.lime)

            Text("Didn't receive the code?")
                .font(VoiidFont.rounded(15))
                .foregroundColor(VoiidBrand.textDim)

            Button {
                Haptics.tap()
                Task { await resend() }
            } label: {
                Text(resending ? "Sending…" : "Resend code")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidBrand.lime)
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(resending || verifying)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Actions

    /// Ask Firebase for a new code.
    ///
    /// THE NEW verificationID REPLACES THE OLD ONE. Firebase invalidates the previous id when it
    /// issues a fresh code, so verifying against the id this screen was constructed with would
    /// fail for every user who tapped Resend. The old build's Resend button did nothing at all,
    /// which at least could not get this wrong.
    private func resend() async {
        guard !resending, !verifying else { return }
        resending = true
        errorText = nil
        do {
            let newID = try await FirebasePhoneAuth.sendCode(to: phoneE164)
            activeVerificationID = newID
            code = ""
            startCountdown()
            focused = true
            Haptics.success()
        } catch {
            errorText = error.localizedDescription
            Haptics.error()
        }
        resending = false
    }

    /// Verify the code with Firebase, then exchange the Firebase ID token for our
    /// JWT. (Firebase sent the SMS on the previous screen.)
    private func verify() async {
        guard !verifying else { return }
        verifying = true; errorText = nil
        do {
            let idToken = try await FirebasePhoneAuth.verify(verificationID: activeVerificationID,
                                                             code: code)
            let profileComplete = try await AuthService.shared.loginWithFirebase(idToken: idToken)
            // Persist the VERIFIED phone number. The server never stores it, so this is the
            // ONLY place the real number is known — without this, Settings shows a placeholder.
            AppSession.saveVerifiedPhone(phoneE164)
            // AppSession.init() already ran at cold launch with an empty key, so update the
            // LIVE profile too — otherwise the number only appears after the next relaunch.
            session.profile.phoneNumber = phoneE164
            // Publish this device's E2E identity + prekeys (needed for encrypted chat).
            try? await E2EManager.shared.bootstrap()
            Haptics.success()
            if profileComplete {
                // Returning user. If the account has a server-side backup and this
                // device doesn't already hold the master secret (fresh install wiped
                // the E2E keychain), offer restore BEFORE entering the app. No backup
                // (or already restored) → proceed straight through.
                if !BackupManager.shared.hasLocalSecret,
                   let meta = try? await BackupService.shared.fetchBackupMeta() {
                    restoreMeta = meta
                } else {
                    onExistingUser()
                }
            } else {
                onContinue()
            }
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
            Haptics.error()
        }
        verifying = false
    }
}
