//
//  CreateProfileScreen.swift
//  Voiid
//
//  Onboarding — profile photo + about (Figma Screen-5). Native back button.
//

import SwiftUI
import PhotosUI

struct CreateProfileScreen: View {
    let onFinish: () -> Void
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var username = ""
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Image?

    // Username availability (Clips handle). Debounced live check.
    enum UStatus: Equatable { case idle, checking, available, taken(String) }
    @State private var uStatus: UStatus = .idle
    @State private var checkTask: Task<Void, Never>?
    @State private var saving = false
    @State private var errorText: String?

    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill
    private let avatar: CGFloat = 110

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && uStatus == .available && !saving
    }

    /// Debounced availability check as the user types the username.
    private func onUsernameChange(_ raw: String) {
        // Normalize to the allowed charset (lowercase, [a-z0-9_]).
        let v = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if v != username { username = v }
        checkTask?.cancel()
        guard v.count >= 3 else { uStatus = .idle; return }
        uStatus = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)   // debounce
            if Task.isCancelled { return }
            do {
                let r = try await ProfileService.shared.checkUsername(v)
                if Task.isCancelled || v != username { return }
                uStatus = r.available ? .available : .taken(r.reason ?? "Username taken")
            } catch {
                uStatus = .taken("Couldn’t check — try again")
            }
        }
    }

    /// Save profile (name + username + about + photo placeholder) then finish.
    private func submit() {
        guard canSubmit else { return }
        saving = true; errorText = nil
        Task {
            do {
                _ = try await ProfileService.shared.updateProfile(
                    fullName: name.trimmingCharacters(in: .whitespaces),
                    bio: about.isEmpty ? nil : about,
                    username: username
                )
                session.profile.bio = about
                Haptics.success(); onFinish()
            } catch let APIError.http(status, _) where status == 409 {
                uStatus = .taken("Just taken — pick another")
                errorText = "That username was just taken."
                Haptics.error()
            } catch {
                errorText = (error as? APIError)?.errorDescription ?? "Couldn’t save profile."
                Haptics.error()
            }
            saving = false
        }
    }

    var body: some View {
        ZStack {
            VoiidBackground().dismissKeyboardOnTap()
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 8)
                // Title matches the Phone/OTP screens (22 bold), left-aligned
                Text("Create profile")
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)

                // Avatar with pink camera badge (centered)
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
                .frame(maxWidth: .infinity)   // center the avatar
                .padding(.top, VoiidSpacing.xl)
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let ui = UIImage(data: data) { photo = Image(uiImage: ui) }
                    }
                }

                // Name field
                VoiidTextField(placeholder: "Your name", text: $name)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.xl)

                // Username field (Clips handle) + live availability indicator
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text("@").font(VoiidFont.body).foregroundColor(VoiidColor.placeholder)
                        TextField("", text: Binding(get: { username }, set: onUsernameChange),
                                  prompt: Text("username").foregroundColor(VoiidColor.placeholder))
                            .font(VoiidFont.body)
                            .foregroundColor(VoiidColor.textPrimary)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        usernameStatusIcon
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .frame(height: 61)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md)
                        .stroke(usernameBorderColor, lineWidth: 1))

                    if case .taken(let why) = uStatus {
                        Text(why).font(VoiidFont.caption).foregroundColor(VoiidColor.error)
                    } else {
                        Text("Used only in Clips. Letters, digits, underscore.")
                            .font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                    }
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.top, VoiidSpacing.md)

                // About you pill text area
                TextField("", text: $about,
                          prompt: Text("About you").foregroundColor(VoiidColor.placeholder),
                          axis: .vertical)
                    .font(VoiidFont.rounded(17, .regular)).lineLimit(3...6)
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.vertical, VoiidSpacing.md)
                    .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.md)

                if let errorText {
                    Text(errorText).font(VoiidFont.caption).foregroundColor(VoiidColor.error)
                        .padding(.horizontal, VoiidSpacing.lg).padding(.top, 6)
                }

                Spacer()

                Button(action: submit) {
                    Group {
                        if saving { ProgressView().tint(VoiidColor.textPrimary) }
                        else { Text("Sign up").font(VoiidFont.rounded(18, .medium)) }
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: pillHeight)
                    .background(VoiidColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                    .opacity(canSubmit ? 1 : 0.55)
                }
                .buttonStyle(SoftPressStyle())
                .disabled(!canSubmit)
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        // Native back button (system chevron) — nav bar shown, transparent over our bg.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(VoiidColor.primary)   // native back chevron color
    }

    @ViewBuilder private var usernameStatusIcon: some View {
        switch uStatus {
        case .idle: EmptyView()
        case .checking: ProgressView().scaleEffect(0.7)
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundColor(VoiidColor.success)
        case .taken:
            Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.error)
        }
    }

    private var usernameBorderColor: Color {
        switch uStatus {
        case .available: return VoiidColor.success
        case .taken:     return VoiidColor.error
        default:         return VoiidColor.fieldBorder
        }
    }
}
