//
//  OTPScreen.swift
//  Voiid
//
//  Onboarding — 6-digit OTP verification (Figma Screen-3).
//  Hidden-field pattern: one field captures all input/paste/SMS-autofill; circles display.
//

import SwiftUI

struct OTPScreen: View {
    let onContinue: () -> Void
    var phoneNumber: String = "+91 91234567890"
    /// E.164 number (no spaces) used for login. Defaults from `phoneNumber`.
    var e164: String? = nil
    /// Firebase verificationID from the Phone screen's sendCode.
    var verificationID: String = ""

    // Single source of truth: one hidden field holds all 6 digits; circles display them.
    @State private var code = ""
    @State private var verifying = false
    @State private var errorText: String?
    @FocusState private var keyboardUp: Bool

    private let pillHeight: CGFloat = 64
    private let length = 6
    private var complete: Bool { code.count == length }

    /// Normalized E.164 ("+" + digits) for the login call.
    private var phoneE164: String {
        if let e164 { return e164 }
        let digits = phoneNumber.filter { $0.isNumber }
        return "+\(digits)"
    }

    /// Verify the code with Firebase, then exchange the Firebase ID token for our
    /// JWT. (Firebase sent the SMS on the previous screen.)
    private func verify() async {
        guard !verifying else { return }
        verifying = true; errorText = nil
        do {
            let idToken = try await FirebasePhoneAuth.verify(verificationID: verificationID, code: code)
            try await AuthService.shared.loginWithFirebase(idToken: idToken)
            Haptics.success()
            onContinue()
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
            Haptics.error()
        }
        verifying = false
    }

    var body: some View {
        ZStack {
            VoiidBackground()
                .contentShape(Rectangle())
                .onTapGesture { keyboardUp = false }   // tap outside closes keyboard
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 24)
                Text("Verify your number")
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                Text("We sent a 6-digit code to \(phoneNumber)")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.lg).padding(.top, 6)

                // Display circles overlaid on one hidden text field that captures all input.
                ZStack {
                    // Hidden field — does the actual typing/paste; tapping the circles focuses it.
                    TextField("", text: $code)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)   // SMS autofill
                        .focused($keyboardUp)
                        .foregroundColor(.clear)
                        .accentColor(.clear)
                        .onChange(of: code) { _, newVal in
                            let digits = String(newVal.filter(\.isNumber).prefix(length))
                            if digits != code { code = digits }
                            if !digits.isEmpty { Haptics.selection() }
                            if digits.count == length { keyboardUp = false }
                        }

                    HStack(spacing: 10) {
                        ForEach(0..<length, id: \.self) { i in otpCircle(i) }
                    }
                    .allowsHitTesting(false)   // taps pass through to the hidden field
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.xl)
                .contentShape(Rectangle())
                .onTapGesture { keyboardUp = true }   // tap the row -> focus

                Button("Resend code") { Haptics.tap() }
                    .font(VoiidFont.rounded(14, .medium))
                    .foregroundColor(VoiidColor.primary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.md)

                if let errorText {
                    Text(errorText)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.error)
                        .padding(.horizontal, VoiidSpacing.lg)
                        .padding(.top, VoiidSpacing.sm)
                }

                Spacer()

                Button(action: { Task { await verify() } }) {
                    Group {
                        if verifying {
                            ProgressView().tint(VoiidColor.textPrimary)
                        } else {
                            Text("Continue").font(VoiidFont.rounded(18, .medium))
                        }
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: pillHeight)
                    .background(VoiidColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                    .opacity(complete ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(!complete || verifying)
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        .onAppear { keyboardUp = true }
    }

    private func digit(_ i: Int) -> String {
        let chars = Array(code)
        return i < chars.count ? String(chars[i]) : ""
    }
    private var activeIndex: Int { min(code.count, length - 1) }

    private func otpCircle(_ i: Int) -> some View {
        let isActive = keyboardUp && i == activeIndex && code.count < length
        let filled = i < code.count
        return Text(digit(i))
            .font(VoiidFont.rounded(22, .semibold))
            .foregroundColor(VoiidColor.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .background(VoiidColor.fieldFill)
            .clipShape(Circle())
            .overlay(Circle().stroke(
                (isActive || filled) ? VoiidColor.primary : VoiidColor.fieldBorder,
                lineWidth: isActive ? 2 : 1))
            .scaleEffect(isActive ? 1.06 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: keyboardUp)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: code)
    }
}
