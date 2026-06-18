//
//  PhoneScreen.swift
//  Voiid
//
//  Onboarding — phone number entry (Figma Screen-2). SF Pro Rounded.
//

import SwiftUI

struct PhoneScreen: View {
    /// Passes the E.164 number + Firebase verificationID to the OTP step.
    let onContinue: (String, String) -> Void
    @State private var phone = ""
    @State private var country = Country.default   // India default
    @State private var showPicker = false
    @State private var sending = false
    @State private var errorText: String?

    // pill metrics matched to the design
    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill

    /// Send the OTP via Firebase, then advance to the OTP screen with the
    /// verificationID.
    private func sendOtp() {
        guard !sending else { return }
        sending = true; errorText = nil
        let e164 = "\(country.dialCode)\(phone.filter { $0.isNumber })"
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
            VoiidBackground()
                .dismissKeyboardOnTap()   // tap outside fields closes the keyboard
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 24)   // title sits higher up (per design)

                Text("Your phone number")
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                Text("Voiid will send a one-time code via SMS\nto verify your number")
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, 6)

                // Country selector — opens a searchable full-list sheet (best UX for ~200 countries).
                Button {
                    Haptics.tap(); showPicker = true
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Text(country.flag).font(.system(size: 22))
                        Text(country.name)
                            .font(VoiidFont.rounded(17, .regular))
                            .foregroundColor(VoiidColor.adaptiveText)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(VoiidColor.adaptiveText.opacity(0.6))
                    }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .frame(height: pillHeight)
                    .frame(maxWidth: .infinity)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .buttonStyle(SoftPressStyle(scale: 0.985))
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.xl)

                // Dial code pill + number pill
                HStack(spacing: VoiidSpacing.md) {
                    Text(country.dialCode)
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.adaptiveText)
                        .frame(width: 84, height: pillHeight)
                        .background(VoiidColor.fieldFill)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))

                    TextField("", text: $phone, prompt:
                        Text("91234567890").foregroundColor(VoiidColor.placeholder))
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.adaptiveText)
                        .keyboardType(.numberPad)
                        .padding(.horizontal, VoiidSpacing.lg)
                        .frame(height: pillHeight)
                        .frame(maxWidth: .infinity)
                        .background(VoiidColor.fieldFill)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.md)

                Spacer()

                if let errorText {
                    Text(errorText)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.error)
                        .padding(.horizontal, VoiidSpacing.lg)
                }

                // Continue — pink pill with soft touch feedback.
                Button(action: sendOtp) {
                    Group {
                        if sending { ProgressView().tint(VoiidColor.textPrimary) }
                        else { Text("Continue").font(VoiidFont.rounded(18, .medium)) }
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: pillHeight)
                    .background(VoiidColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                    .opacity(phone.count >= 10 ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(phone.count < 10 || sending)
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, VoiidSpacing.xl)
            }
        }
        .sheet(isPresented: $showPicker) {
            CountryPickerSheet(selected: $country)
        }
    }
}
