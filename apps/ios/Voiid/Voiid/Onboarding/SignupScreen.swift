//
//  SignupScreen.swift
//  Voiid
//
//  Onboarding — full name + email (Figma Screen-4). Verified phone shown locked.
//

import SwiftUI

struct SignupScreen: View {
    let onContinue: () -> Void
    /// The real verified phone in E.164 (e.g. "+9199..."), shown read-only.
    var phone: String = ""
    @EnvironmentObject var session: AppSession
    @State private var name = ""
    @State private var email = ""

    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill
    private var valid: Bool {
        let n = name.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces)
        // basic email: something@something.something
        let emailOK = e.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil
        return !n.isEmpty && emailOK
    }

    var body: some View {
        ZStack {
            VoiidBackground().dismissKeyboardOnTap()
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                Spacer().frame(height: 40)
                Text("Let's get started")
                    .font(VoiidFont.rounded(34, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.bottom, VoiidSpacing.sm)

                // Full name (pill)
                pillField(placeholder: "Full name", text: $name)
                // Email (pill)
                pillField(placeholder: "Email Address", text: $email, keyboard: .emailAddress)

                // Verified phone — grey-filled, read-only, with green check
                HStack(spacing: VoiidSpacing.sm) {
                    Text(phone.isEmpty ? "Verified number" : phone)
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(VoiidColor.success)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .frame(height: pillHeight)
                .frame(maxWidth: .infinity)
                .background(VoiidColor.bubbleSent)   // grey fill (#C8C8C8) = verified/locked
                .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                .padding(.horizontal, VoiidSpacing.lg)

                Spacer()

                Button(action: {
                    session.profile.fullName = name
                    session.profile.email = email.trimmingCharacters(in: .whitespaces)
                    Haptics.tap(); onContinue()
                }) {
                    Text("Continue")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: pillHeight)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                        .opacity(valid ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(!valid)
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
    }

    private func pillField(placeholder: String, text: Binding<String>, keyboard: UIKeyboardType = .default) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(VoiidColor.placeholder))
            .font(VoiidFont.rounded(17, .regular))
            .foregroundColor(VoiidColor.textPrimary)
            .keyboardType(keyboard)
            .autocapitalization(keyboard == .emailAddress ? .none : .words)
            .padding(.horizontal, VoiidSpacing.lg)
            .frame(height: pillHeight)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))
            .padding(.horizontal, VoiidSpacing.lg)
    }
}
