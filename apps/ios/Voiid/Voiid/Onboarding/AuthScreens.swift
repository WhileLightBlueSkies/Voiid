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
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select country")
                    .font(VoiidFont.rounded(18, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.md)

            // Custom search field (brand colors, not system)
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
                TextField("", text: $query,
                          prompt: Text("Search country or code").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.placeholder)
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 48)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.sm)

            // List (custom scroll, brand background)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { c in
                        Button {
                            Haptics.selection(); selected = c; dismiss()
                        } label: {
                            HStack(spacing: VoiidSpacing.md) {
                                Text(c.flag).font(.system(size: 24))
                                Text(c.name).font(VoiidFont.rounded(17, .regular))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Spacer()
                                Text(c.dialCode).font(VoiidFont.rounded(16, .regular))
                                    .foregroundColor(VoiidColor.textSecondary)
                                if c.id == selected.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(VoiidColor.primary)
                                }
                            }
                            .padding(.horizontal, VoiidSpacing.lg)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(VoiidColor.divider.opacity(0.4))
                            .padding(.leading, VoiidSpacing.lg)
                    }
                }
            }
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .preferredColorScheme(.light)   // fixed appearance — looks the same in light & dark
    }
}

// MARK: - OTP (Figma Screen-3) — 6 boxes, auto-advance

struct OTPScreen: View {
    let onContinue: () -> Void
    var phoneNumber: String = "+91 91234567890"

    // Single source of truth: one hidden field holds all 6 digits; circles display them.
    @State private var code = ""
    @FocusState private var keyboardUp: Bool

    private let pillHeight: CGFloat = 64
    private let length = 6
    private var complete: Bool { code.count == length }

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

// MARK: - Signup (Figma Screen-4) — full name + email

struct SignupScreen: View {
    let onContinue: () -> Void
    @EnvironmentObject var session: AppSession
    @State private var name = ""
    @State private var email = ""

    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill
    private var valid: Bool { !name.trimmingCharacters(in: .whitespaces).isEmpty && email.contains("@") && email.contains(".") }

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
                    Text("+91").font(VoiidFont.rounded(17, .regular)).foregroundColor(VoiidColor.textPrimary)
                    Text("91234567890").font(VoiidFont.rounded(17, .regular)).foregroundColor(VoiidColor.textPrimary)
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
                    session.profile.fullName = name; Haptics.tap(); onContinue()
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

// MARK: - Create Profile (Figma Screen-5) — photo + about

struct CreateProfileScreen: View {
    let onFinish: () -> Void
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Image?

    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill
    private let avatar: CGFloat = 110

    var body: some View {
        ZStack {
            VoiidBackground().dismissKeyboardOnTap()
            VStack(spacing: 0) {
                // Header: back + CREATE PROFILE
                HStack(spacing: VoiidSpacing.sm) {
                    Button { Haptics.tap(); dismiss() } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                    }
                    Text("CREATE PROFILE")
                        .font(VoiidFont.rounded(15, .medium))
                        .tracking(0.5)
                        .foregroundColor(VoiidColor.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.md)

                // Avatar with pink camera badge
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        ZStack {
                            Circle().fill(VoiidColor.fieldFill)
                            if let photo {
                                photo.resizable().scaledToFill()
                                    .frame(width: avatar, height: avatar).clipShape(Circle())
                            } else {
                                Image("VoiidWordmark")   // faint logo mark placeholder
                                    .resizable().scaledToFit()
                                    .frame(width: avatar * 0.5)
                                    .opacity(0.25)
                            }
                        }
                        .frame(width: avatar, height: avatar)

                        // pink camera badge
                        Circle().fill(VoiidColor.accent)
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "camera.fill")
                                .font(.system(size: 14)).foregroundColor(VoiidColor.primary))
                            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                    }
                }
                .padding(.top, VoiidSpacing.xxl)
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let ui = UIImage(data: data) { photo = Image(uiImage: ui) }
                    }
                }

                // About you pill text area
                TextField("", text: $about,
                          prompt: Text("About you").foregroundColor(VoiidColor.placeholder),
                          axis: .vertical)
                    .font(VoiidFont.rounded(17, .regular)).lineLimit(4...7)
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.vertical, VoiidSpacing.md)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.xxl)

                Spacer()

                Button(action: {
                    session.profile.bio = about
                    Haptics.success(); onFinish()
                }) {
                    Text("Sign up")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: pillHeight)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        .navigationBarBackButtonHidden(true)
    }
}
