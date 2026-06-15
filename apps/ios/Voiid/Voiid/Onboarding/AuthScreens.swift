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

struct PhoneScreen: View {
    let onContinue: () -> Void
    @State private var phone = ""
    @State private var country = Country.default   // India default
    @State private var showPicker = false

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

                // Country selector — opens a searchable full-list sheet (best UX for ~200 countries).
                Button {
                    Haptics.tap(); showPicker = true
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Text(country.flag).font(.system(size: 22))
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
                .buttonStyle(SoftPressStyle(scale: 0.985))
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
        .sheet(isPresented: $showPicker) {
            CountryPickerSheet(selected: $country)
        }
    }
}

// MARK: - Searchable country picker (full list)

struct CountryPickerSheet: View {
    @Binding var selected: Country
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        guard !query.isEmpty else { return CountryStore.all }
        return CountryStore.all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.dialCode.contains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List(results) { c in
                Button {
                    Haptics.selection(); selected = c; dismiss()
                } label: {
                    HStack(spacing: VoiidSpacing.md) {
                        Text(c.flag).font(.system(size: 24))
                        Text(c.name).font(VoiidFont.rounded(17, .regular)).foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                        Text(c.dialCode).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textSecondary)
                        if c.id == selected.id {
                            Image(systemName: "checkmark").foregroundColor(VoiidColor.primary)
                        }
                    }
                }
            }
            .listStyle(.plain)
            .searchable(text: $query, prompt: "Search country or code")
            .navigationTitle("Select country")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}

// MARK: - OTP (Figma Screen-3) — 6 boxes, auto-advance

struct OTPScreen: View {
    let onContinue: () -> Void
    var phoneNumber: String = "+91 91234567890"
    @State private var code: [String] = Array(repeating: "", count: 6)
    @FocusState private var focusedIndex: Int?

    private let pillHeight: CGFloat = 64
    private var complete: Bool { code.allSatisfy { !$0.isEmpty } }

    var body: some View {
        ZStack {
            VoiidBackground()
                .dismissKeyboardOnTap()
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

                // 6 circular OTP fields
                HStack(spacing: 10) {
                    ForEach(0..<6, id: \.self) { i in otpCircle(i) }
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.xl)

                // Resend row
                Button("Resend code") { Haptics.tap() }
                    .font(VoiidFont.rounded(14, .medium))
                    .foregroundColor(VoiidColor.primary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.md)

                Spacer()

                Button(action: { Haptics.success(); onContinue() }) {
                    Text("Continue")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: pillHeight)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                        .opacity(complete ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(!complete)
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        .onAppear { focusedIndex = 0 }
    }

    private func otpCircle(_ i: Int) -> some View {
        TextField("", text: Binding(
            get: { code[i] },
            set: { newVal in
                let filtered = String(newVal.prefix(1)).filter(\.isNumber)
                code[i] = filtered
                if !filtered.isEmpty {
                    Haptics.selection()
                    if i < 5 { focusedIndex = i + 1 } else { focusedIndex = nil }
                } else if newVal.isEmpty, i > 0 {
                    focusedIndex = i - 1   // backspace moves back
                }
            })
        )
        .multilineTextAlignment(.center)
        .font(VoiidFont.rounded(22, .semibold))
        .foregroundColor(VoiidColor.textPrimary)
        .keyboardType(.numberPad)
        .focused($focusedIndex, equals: i)
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .background(VoiidColor.fieldFill)
        .clipShape(Circle())
        .overlay(Circle().stroke(
            focusedIndex == i ? VoiidColor.primary : VoiidColor.fieldBorder,
            lineWidth: focusedIndex == i ? 2 : 1))
        .scaleEffect(focusedIndex == i ? 1.06 : 1)
        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: focusedIndex)
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
