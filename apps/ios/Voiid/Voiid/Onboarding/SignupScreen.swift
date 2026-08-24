//
//  SignupScreen.swift
//  Voiid
//
//  Let's set up your profile — step 1 of 2, shown after verification when the number has NO
//  existing account.
//
//  Built to the design source (`Voiid Ui/Screens/ProfileSetupScreen.swift`) through
//  `OnboardingKit`.
//
//  ── WHY THE PROFILE IS TWO PAGES ────────────────────────────────────────────────
//  Four fields plus an avatar is a wall of form immediately after the user has already done two
//  steps, and the two halves are not the same kind of ask:
//
//    * THIS page is IDENTITY: photo, name, username. Required (bar the photo), and the things
//      that make the account theirs.
//    * The NEXT page is EXTRAS: email and bio. Both optional, and therefore skippable in one
//      tap — which is only honest if they are not mixed in with the required fields.
//
//  Splitting on that seam is what makes page 2 skippable at all. Splitting merely by COUNT would
//  have produced two pages that each have to be completed, which is worse than one.
//
//  ── THE USERNAME CHECK IS REAL ──────────────────────────────────────────────────
//  The design source validates FORMAT only and says so, because it has no server. This screen
//  keeps the app's existing DEBOUNCED AVAILABILITY CHECK against `ProfileService.checkUsername`,
//  so the tick means "this name is free", not merely "this name is well formed". That is a
//  stronger promise than the reference could make and it is worth keeping.
//
//  Nothing is SAVED here — the profile is written once, on the next page, so a user who backs
//  out has not half-created an account. The photo is optional and stays optional: a required
//  avatar at signup is a wall in front of an account the user has already proven they own.
//

import SwiftUI
import PhotosUI

/// What the two profile pages collect between them.
///
/// Hashable as well as Equatable: it travels inside a navigation Route, and NavigationPath
/// requires its values to hash.
struct ProfileDraft: Equatable, Hashable {
    var fullName = ""
    var username = ""
    var email = ""
    var bio = ""
    /// Encoded image data, if the user picked one. Data rather than a `UIImage` so the caller can
    /// hand it straight to an upload without a re-encode.
    var photo: Data?
}

struct SignupScreen: View {
    /// Hands the identity half forward. The caller collects the extras and saves once.
    let onContinue: (ProfileDraft) -> Void
    /// The real verified phone in E.164 (e.g. "+9199..."), shown read-only.
    var phone: String = ""

    @EnvironmentObject var session: AppSession

    @State private var draft = ProfileDraft()
    @State private var pickerItem: PhotosPickerItem?
    @State private var photo: Image?

    /// Username availability, checked against the server as the user types.
    enum UStatus: Equatable { case idle, checking, available, taken(String) }
    @State private var uStatus: UStatus = .idle
    @State private var checkTask: Task<Void, Never>?

    // MARK: Validation

    /// Trimmed, so a name of three spaces does not pass.
    private var nameValid: Bool {
        draft.fullName.trimmingCharacters(in: .whitespaces).count >= 2
    }

    /// FORMAT rules: 3–20 characters, letters/digits/underscore, not starting with a digit.
    /// Availability is a separate question — see `uStatus`.
    private var usernameWellFormed: Bool {
        let u = draft.username
        guard (3...20).contains(u.count) else { return false }
        guard u.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return false }
        return !(u.first?.isNumber ?? true)
    }

    private var canContinue: Bool { nameValid && uStatus == .available }

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    OnboardingHeader(
                        title: .stacked("Let's set up", accent: "your profile"),
                        blurb: "Add a few details to get started."
                    )

                    avatarPicker
                        .padding(.top, VoiidSpacing.md)

                    fields
                        .padding(.top, VoiidSpacing.md)

                    verifiedNumber
                        .padding(.top, 12)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.bottom, 185)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footer
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .onChange(of: pickerItem) { _, item in
            Task { await load(item) }
        }
    }

    // MARK: Avatar

    private var avatarPicker: some View {
        VStack(spacing: VoiidSpacing.sm) {
            PhotosPicker(selection: $pickerItem, matching: .images, photoLibrary: .shared()) {
                ZStack(alignment: .bottomTrailing) {
                    Circle()
                        .fill(VoiidBrand.card)
                        .frame(width: 84, height: 84)
                        .overlay(Circle().stroke(VoiidBrand.hairline, lineWidth: 1))
                        .overlay {
                            if let photo {
                                photo
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 84, height: 84)
                                    .clipShape(Circle())
                            } else {
                                Image(systemName: "camera")
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundColor(VoiidBrand.lime)
                            }
                        }

                    // The affordance. Present even once a photo is chosen, because it then means
                    // "change it" — and a filled avatar with no visible way to alter it is a
                    // dead end the user has to guess their way out of.
                    Circle()
                        .fill(VoiidBrand.lime)
                        .frame(width: 28, height: 28)
                        .overlay {
                            Image(systemName: photo == nil ? "plus" : "pencil")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(VoiidBrand.onLime)
                        }
                        .overlay(Circle().stroke(VoiidBrand.ground, lineWidth: 3))
                        .offset(x: 2, y: 2)
                }
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(photo == nil ? "Add profile photo" : "Change profile photo")

            Text(photo == nil ? "Add profile photo" : "Profile photo added")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidBrand.text)

            Text("PNG, JPG or WEBP. Max 5MB.")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidBrand.textDim)
        }
        .frame(maxWidth: .infinity)
    }

    /// Loads the picked image and enforces the size limit stated above the picker.
    ///
    /// The limit is checked HERE rather than at upload, because a user who picks a 12MB photo
    /// should learn that immediately, not after filling in the rest of the form.
    private func load(_ item: PhotosPickerItem?) async {
        guard let item,
              let data = try? await item.loadTransferable(type: Data.self),
              let ui = UIImage(data: data)
        else { return }

        let resized = ui.resized(maxDimension: 1024)
        guard let jpeg = resized.jpegData(compressionQuality: 0.85),
              jpeg.count <= 5 * 1024 * 1024
        else {
            Haptics.error()
            return
        }

        draft.photo = jpeg
        photo = Image(uiImage: resized)
        Haptics.success()
    }

    // MARK: Fields

    private var fields: some View {
        VStack(spacing: 12) {
            OnboardingField(
                icon: "person",
                label: "Full name",
                prompt: "Enter your full name",
                text: $draft.fullName,
                contentType: .name,
                autocapitalization: .words
            )

            VStack(alignment: .leading, spacing: 6) {
                OnboardingField(
                    icon: "at",
                    label: "Username",
                    prompt: "Choose a unique username",
                    text: $draft.username,
                    contentType: .username,
                    autocapitalization: .never
                ) {
                    usernameStatusGlyph
                }
                .onChange(of: draft.username) { _, new in onUsernameChange(new) }
                .animation(.easeOut(duration: 0.15), value: uStatus)

                Text(usernameHelp)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(usernameHelpColor)
                    .padding(.leading, 4)
            }
        }
    }

    /// Only shown once something is typed: a validity marker on an untouched field is noise,
    /// and a red cross before the user has done anything is worse.
    @ViewBuilder
    private var usernameStatusGlyph: some View {
        switch uStatus {
        case .idle:
            if !draft.username.isEmpty && !usernameWellFormed {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(VoiidColor.warning)
            }
        case .checking:
            ProgressView().controlSize(.small).tint(VoiidBrand.textDim)
        case .available:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(VoiidBrand.lime)
        case .taken:
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(VoiidColor.warning)
        }
    }

    /// Debounced availability check as the user types.
    ///
    /// The format rules are applied FIRST and locally, so an obviously invalid name never costs
    /// a round trip — and the server is only asked about names it could plausibly accept.
    private func onUsernameChange(_ raw: String) {
        // Usernames are lowercase and unspaced. Correcting as they type beats rejecting after.
        let v = raw.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
        if v != draft.username { draft.username = v }

        checkTask?.cancel()
        guard usernameWellFormed else { uStatus = .idle; return }
        uStatus = .checking
        checkTask = Task {
            try? await Task.sleep(nanoseconds: 400_000_000)   // debounce
            if Task.isCancelled { return }
            do {
                let r = try await ProfileService.shared.checkUsername(v)
                if Task.isCancelled || v != draft.username { return }
                uStatus = r.available ? .available : .taken(r.reason ?? "Username taken")
            } catch {
                uStatus = .taken("Couldn't check — try again")
            }
        }
    }

    /// Says what is actually true at each stage.
    private var usernameHelp: String {
        if draft.username.isEmpty { return "This will be your unique Voiid ID." }
        if draft.username.count < 3 { return "At least 3 characters." }
        if draft.username.first?.isNumber == true { return "Can't start with a number." }
        if !usernameWellFormed { return "Letters, numbers and underscores only." }
        switch uStatus {
        case .checking:          return "Checking availability…"
        case .available:         return "Available."
        case .taken(let reason): return reason
        case .idle:              return "This will be your unique Voiid ID."
        }
    }

    private var usernameHelpColor: Color {
        if draft.username.isEmpty { return VoiidBrand.textDim }
        switch uStatus {
        case .available: return VoiidBrand.lime
        case .taken:     return VoiidColor.warning
        default:         return usernameWellFormed ? VoiidBrand.textDim : VoiidColor.warning
        }
    }

    // MARK: Verified number

    /// The number is already proven, so it is shown rather than asked for — inert fill, no
    /// border, and a tick. Nothing here is editable.
    private var verifiedNumber: some View {
        HStack(spacing: VoiidSpacing.md) {
            Circle()
                .fill(VoiidBrand.lime.opacity(0.10))
                .frame(width: 38, height: 38)
                .overlay {
                    Image(systemName: "phone")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(VoiidBrand.lime)
                }

            VStack(alignment: .leading, spacing: 2) {
                Text("Verified number")
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidBrand.textDim)
                Text(phone.isEmpty ? session.profile.phoneNumber : phone)
                    .font(VoiidFont.rounded(16))
                    .foregroundColor(VoiidBrand.text)
            }

            Spacer(minLength: 0)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 20))
                .foregroundColor(VoiidColor.success)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .background(VoiidBrand.card)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.hairline, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    private var footer: some View {
        OnboardingFooter {
            OnboardingKitButton(title: "Continue", enabled: canContinue) {
                var d = draft
                d.fullName = draft.fullName.trimmingCharacters(in: .whitespaces)
                // Kept in the session too, so anything reading the live profile before the save
                // lands (the tab bar's avatar, for one) shows the real name rather than a blank.
                session.profile.fullName = d.fullName
                onContinue(d)
            }

            StepDots(current: 0, total: 2)
        }
    }
}
