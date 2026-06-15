//
//  AuthScreens.swift
//  Voiid
//
//  Phone → OTP → Signup → Create Profile. SF Pro Rounded (per design owner).
//  Built to exact Figma values; refined via device screenshots.
//

import SwiftUI
import PhotosUI

// MARK: - Phone number (Figma Screen-2)

// A small country model for the picker.
struct Country: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let dialCode: String
    let flag: String
}

private let countries: [Country] = [
    Country(name: "India", dialCode: "+91", flag: "🇮🇳"),
    Country(name: "United States", dialCode: "+1", flag: "🇺🇸"),
    Country(name: "United Kingdom", dialCode: "+44", flag: "🇬🇧"),
    Country(name: "United Arab Emirates", dialCode: "+971", flag: "🇦🇪"),
    Country(name: "Singapore", dialCode: "+65", flag: "🇸🇬"),
    Country(name: "Australia", dialCode: "+61", flag: "🇦🇺"),
    Country(name: "Canada", dialCode: "+1", flag: "🇨🇦"),
]

struct PhoneScreen: View {
    let onContinue: () -> Void
    @State private var phone = ""
    @State private var country = countries[0]   // India default

    // pill metrics matched to the design
    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill

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

                // Country selector — native menu (most reliable + accessible).
                Menu {
                    ForEach(countries) { c in
                        Button {
                            Haptics.selection(); country = c
                        } label: {
                            Text("\(c.flag)  \(c.name)  \(c.dialCode)")
                        }
                    }
                } label: {
                    HStack {
                        Text(country.name)
                            .font(VoiidFont.rounded(17, .regular))
                            .foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .frame(height: pillHeight)
                    .frame(maxWidth: .infinity)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.xl)

                // Dial code pill + number pill
                HStack(spacing: VoiidSpacing.md) {
                    Text(country.dialCode)
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(width: 84, height: pillHeight)
                        .background(VoiidColor.fieldFill)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: pillRadius).stroke(VoiidColor.fieldBorder, lineWidth: 1))

                    TextField("91234567890", text: $phone)
                        .font(VoiidFont.rounded(17, .regular))
                        .foregroundColor(VoiidColor.textPrimary)
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

                // Continue — pink pill with soft touch feedback.
                Button(action: { Haptics.tap(); onContinue() }) {
                    Text("Continue")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity)
                        .frame(height: pillHeight)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                        .opacity(phone.count >= 10 ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(phone.count < 10)
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, VoiidSpacing.xl)
            }
        }
    }
}

// MARK: - OTP (Figma Screen-3) — 6 boxes, auto-advance

struct OTPScreen: View {
    let onContinue: () -> Void
    @State private var code: [String] = Array(repeating: "", count: 6)
    @FocusState private var focusedIndex: Int?

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 80)
                Text("Verify your number")
                    .font(VoiidFont.title).foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                Text("We sent a 6-digit code to +91 91234567890")
                    .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.lg).padding(.top, VoiidSpacing.sm)

                HStack(spacing: VoiidSpacing.sm) {
                    ForEach(0..<6, id: \.self) { i in
                        otpBox(i)
                    }
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.xl)

                Spacer()

                VoiidPrimaryButton(title: "Continue", enabled: code.allSatisfy { !$0.isEmpty }) {
                    Haptics.success(); onContinue()
                }
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        .onAppear { focusedIndex = 0 }
    }

    private func otpBox(_ i: Int) -> some View {
        TextField("", text: Binding(
            get: { code[i] },
            set: { newVal in
                let filtered = String(newVal.prefix(1)).filter(\.isNumber)
                code[i] = filtered
                if !filtered.isEmpty {
                    Haptics.selection()
                    if i < 5 { focusedIndex = i + 1 } else { focusedIndex = nil }
                }
            })
        )
        .multilineTextAlignment(.center)
        .font(VoiidFont.title)
        .keyboardType(.numberPad)
        .focused($focusedIndex, equals: i)
        .frame(width: 50, height: 50)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md)
            .stroke(focusedIndex == i ? VoiidColor.primary : VoiidColor.fieldBorder, lineWidth: focusedIndex == i ? 2 : 1))
    }
}

// MARK: - Signup (Figma Screen-4) — full name + email

struct SignupScreen: View {
    let onContinue: () -> Void
    @EnvironmentObject var session: AppSession
    @State private var name = ""
    @State private var email = ""

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                Spacer().frame(height: 80)
                Text("Let's get started")
                    .font(VoiidFont.display).foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)

                VoiidTextField(placeholder: "Full name", text: $name)
                    .padding(.horizontal, VoiidSpacing.lg).padding(.top, VoiidSpacing.lg)
                VoiidTextField(placeholder: "Email Address", text: $email, keyboard: .emailAddress)
                    .padding(.horizontal, VoiidSpacing.lg)

                HStack {
                    Text("+91").font(VoiidFont.body).foregroundColor(VoiidColor.textPrimary)
                    Text("91234567890").font(VoiidFont.body).foregroundColor(VoiidColor.textSecondary)
                    Spacer()
                    Image(systemName: "checkmark.circle.fill").foregroundColor(VoiidColor.success)
                }
                .padding(.horizontal, VoiidSpacing.md).frame(height: 65)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder))
                .padding(.horizontal, VoiidSpacing.lg)

                Spacer()
                VoiidPrimaryButton(title: "Continue", enabled: !name.isEmpty && email.contains("@")) {
                    session.profile.fullName = name
                    Haptics.tap(); onContinue()
                }
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
    }
}

// MARK: - Create Profile (Figma Screen-5) — photo + about

struct CreateProfileScreen: View {
    let onFinish: () -> Void
    @EnvironmentObject var session: AppSession
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Image?

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(spacing: VoiidSpacing.lg) {
                Spacer().frame(height: 60)
                Text("CREATE PROFILE")
                    .font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, VoiidSpacing.lg)

                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack {
                        Circle().fill(VoiidColor.fieldFill).frame(width: 120, height: 120)
                        if let photo { photo.resizable().scaledToFill().frame(width: 120, height: 120).clipShape(Circle()) }
                        else { Image(systemName: "camera.fill").font(.system(size: 36)).foregroundColor(VoiidColor.accent) }
                    }
                    .overlay(Circle().stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let ui = UIImage(data: data) { photo = Image(uiImage: ui) }
                    }
                }

                TextField("About you", text: $about, axis: .vertical)
                    .font(VoiidFont.body).lineLimit(3...5)
                    .padding(VoiidSpacing.md)
                    .frame(maxWidth: .infinity, minHeight: 119, alignment: .topLeading)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder))
                    .padding(.horizontal, VoiidSpacing.lg)

                Spacer()
                VoiidPrimaryButton(title: "Sign up") {
                    session.profile.bio = about
                    Haptics.success(); onFinish()
                }
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
    }
}
