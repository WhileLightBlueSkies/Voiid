//
//  EditProfileView.swift
//  Voiid
//
//  ┌──────────────────────────────────────────────────────────────────────────────┐
//  │ INTERIM IMPLEMENTATION — owned by Implementer 2, who replaces this FILE       │
//  │ WHOLESALE with the full screen in spec §5.1.                                  │
//  │                                                                              │
//  │ Still to come from §5.1: About/bio field, Username with debounced async       │
//  │ availability checking, Email, and "Delete My Account" (which calls            │
//  │ `SessionTeardown.wipeLocalAccountState()` — already shipped — then            │
//  │ `session.signOut()`).                                                        │
//  │                                                                              │
//  │ What is here now is NOT a placeholder: it is exactly the profile editing the  │
//  │ old settings sheet already had (photo, display name, phone), moved onto its   │
//  │ own screen with cancel-safety it did not previously have. The shell must not  │
//  │ regress a shipped capability while the full screen is being written, and a    │
//  │ screen titled "Profile" that could not edit your profile would be its own     │
//  │ small lie.                                                                    │
//  │                                                                              │
//  │ Contract this file must keep: `EditProfileView()` — no arguments, reads from  │
//  │ `@EnvironmentObject var session: AppSession`.                                 │
//  └──────────────────────────────────────────────────────────────────────────────┘
//
//  Presentation decision (§5.1): a pushed screen with an explicit Save, not inline
//  tap-to-mutate labels. Multi-field inline editing has no cancel-safety — the old sheet
//  could only cancel one field at a time.
//
//  Save is LOCAL FIRST: `session.updateProfile` persists and re-renders before the request
//  is attempted, so editing your name offline shows the new name immediately. A failed
//  sync never rolls back what the user sees; it says so instead.
//

import SwiftUI
import PhotosUI

struct EditProfileView: View {
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var bio = ""
    @State private var username = ""
    @State private var loaded = false

    @State private var photoItem: PhotosPickerItem?
    /// Camera or library — asked before either is presented, so the user picks the SOURCE
    /// rather than being dropped into whichever one we guessed.
    @State private var showPhotoSource = false
    @State private var showCamera = false
    @State private var showLibrary = false
    @State private var uploading = false

    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var syncWarning: String?

    /// Live username availability. nil = not checked / unchanged; true/false = last result.
    @State private var usernameAvailable: Bool?
    @State private var checkingUsername = false
    @State private var usernameCheckTask: Task<Void, Never>?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private var trimmedBio: String { bio.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedUsername: String {
        username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var isDirty: Bool {
        loaded && (trimmedName != session.profile.fullName
                   || trimmedBio != (session.profile.bio ?? "")
                   || trimmedUsername != (session.profile.username ?? ""))
    }

    /// Block save when the chosen username is known-taken.
    /// Everything that must hold for Save to do anything, in ONE place — the button's look
    /// and its enabled state read the same value, so they cannot drift apart.
    private var canSave: Bool {
        isDirty && !saving && !trimmedName.isEmpty && !usernameBlocksSave && !checkingUsername
    }

    private var usernameBlocksSave: Bool {
        trimmedUsername != (session.profile.username ?? "") && usernameAvailable == false
    }

    var body: some View {
        List {
            photoSection

            SettingsSection("Name",
                            footer: "Your name and photo are shown to everyone you chat with.") {
                TextField("Your name", text: $name)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .textContentType(.name)
                    .submitLabel(.done)
                    .onChange(of: name) { _, new in
                        if new.count > 50 { name = String(new.prefix(50)) }
                    }
            }

            SettingsSection("Username",
                            footer: usernameFooter) {
                HStack(spacing: 4) {
                    Text("@").foregroundStyle(VoiidColor.textSecondary)
                    TextField("username", text: $username)
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onChange(of: username) { _, new in
                            // Handle chars only, capped; then debounce an availability check.
                            let cleaned = new.lowercased().filter { $0.isLetter || $0.isNumber || $0 == "_" }
                            if cleaned != new { username = String(cleaned.prefix(20)); return }
                            if new.count > 20 { username = String(new.prefix(20)) }
                            scheduleUsernameCheck()
                        }
                    if checkingUsername { ProgressView().controlSize(.small) }
                    else if usernameBlocksSave { Image(systemName: "xmark.circle.fill").foregroundStyle(VoiidColor.error) }
                    else if usernameAvailable == true { Image(systemName: "checkmark.circle.fill").foregroundStyle(VoiidColor.primary) }
                }
            }

            SettingsSection("About",
                            footer: "A short line about you, shown on your profile.") {
                TextField("Add a few words about you", text: $bio, axis: .vertical)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .lineLimit(1...4)
                    .onChange(of: bio) { _, new in
                        if new.count > 140 { bio = String(new.prefix(140)) }
                    }
            }

            SettingsSection("Phone",
                            footer: "Verified when you signed up. Changing your number isn't supported in this version.") {
                LabeledContent("Number") {
                    Text(session.profile.phoneNumber.isEmpty ? "—" : session.profile.phoneNumber)
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }

            if let syncWarning {
                SettingsSection {
                    Text(syncWarning)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.error)
                }
            }
        }
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Profile")
        // While there are unsaved edits the native back button would discard them
        // silently, so it is replaced by a Cancel that asks.
        .navigationBarBackButtonHidden(isDirty)
        .toolbar {
            if isDirty {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { Haptics.tap(); confirmDiscard = true }
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                // SAVE HAS TO LOOK DISABLED WHEN IT IS.
                //
                // It was always `VoiidColor.primary`, so a Save that could not run looked
                // exactly like one that could — you tapped it, nothing happened, and the
                // screen appeared broken. It is disabled far more often than not: the photo
                // uploads the instant you pick it (nothing to save), and Save is also
                // blocked while a username check is in flight or has come back taken.
                //
                // Dimming it says "not yet" before the tap instead of after it, and the
                // spinner distinguishes "in flight" from "inert".
                Button {
                    Task { await save() }
                } label: {
                    if saving {
                        ProgressView().tint(VoiidColor.primary)
                    } else {
                        Text("Save").fontWeight(.semibold)
                    }
                }
                .foregroundStyle(canSave ? VoiidColor.primary : VoiidColor.placeholder)
                .disabled(!canSave)
            }
        }
        .confirmationDialog("Discard changes?",
                            isPresented: $confirmDiscard,
                            titleVisibility: .visible) {
            Button("Discard Changes", role: .destructive) { dismiss() }
            Button("Cancel", role: .cancel) {}
        }
        .onAppear {
            guard !loaded else { return }
            name = session.profile.fullName
            bio = session.profile.bio ?? ""
            username = session.profile.username ?? ""
            loaded = true
        }
    }

    private var usernameFooter: String {
        if trimmedUsername == (session.profile.username ?? "") {
            return "Your @handle for Clips. Letters, numbers and underscores."
        }
        if trimmedUsername.isEmpty { return "Your @handle for Clips. Letters, numbers and underscores." }
        if usernameBlocksSave { return "That username is taken. Try another." }
        if usernameAvailable == true { return "“@\(trimmedUsername)” is available." }
        return "Checking availability…"
    }

    /// Debounced live availability check against the server.
    private func scheduleUsernameCheck() {
        usernameCheckTask?.cancel()
        usernameAvailable = nil
        let candidate = trimmedUsername
        // Unchanged from the saved value or too short: nothing to check.
        guard candidate != (session.profile.username ?? ""), candidate.count >= 3 else {
            checkingUsername = false; return
        }
        checkingUsername = true
        usernameCheckTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000)   // 0.5s debounce
            if Task.isCancelled { return }
            let result = try? await ProfileService.shared.checkUsername(candidate)
            if Task.isCancelled { return }
            await MainActor.run {
                usernameAvailable = result?.available
                checkingUsername = false
            }
        }
    }

    // MARK: - Photo

    private var photoSection: some View {
        SettingsSection {
            // The avatar itself is not the tap target — the labelled button below it is.
            // One unambiguous control beats a picture that might be a button.
            HStack {
                Spacer()
                // THE AVATAR IS THE BUTTON, with a camera badge on it.
                //
                // The old layout put a 96pt avatar alone in one card with nothing else in
                // it — a band of empty white — and "Change Photo" in a SECOND card below,
                // which is what made the top of this screen read as blank. They are one
                // thing and now sit in one card, and the badge means the photo itself looks
                // tappable instead of relying on a separate row to say so.
                Button {
                    Haptics.tap()
                    showPhotoSource = true
                } label: {
                    ZStack(alignment: .bottomTrailing) {
                        ProfileAvatarButton(photoURL: session.profile.photoURL,
                                            name: session.profile.fullName,
                                            size: 104)
                            .overlay(Circle().strokeBorder(VoiidColor.textPrimary.opacity(0.08), lineWidth: 1))
                            .opacity(uploading ? 0.5 : 1)

                        if uploading {
                            ProgressView().tint(VoiidColor.primary)
                        } else {
                            Image(systemName: "camera.fill")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(VoiidColor.textOnPrimary)
                                .frame(width: 32, height: 32)
                                .background(Circle().fill(VoiidColor.primary))
                                // Ringed in the card's own fill so the badge reads as ON the
                                // avatar rather than floating beside it.
                                .overlay(Circle().strokeBorder(VoiidColor.surfaceCard, lineWidth: 3))
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(uploading)
                .accessibilityLabel("Change profile photo")
                Spacer()
            }
            .padding(.vertical, VoiidSpacing.md)
            .listRowBackground(Color.clear)

            // SAY THAT THE PHOTO IS ALREADY SAVED. It uploads the instant you pick it —
            // Save covers only the text fields — so without this line a user changes their
            // photo, sees Save still greyed out, and reasonably concludes nothing happened.
            HStack {
                Spacer()
                Text("Your photo saves as soon as you choose it.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
                Spacer()
            }
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: VoiidSpacing.sm, trailing: 0))

            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await uploadPhoto(item) }
            }
        }
        // TWO SOURCES, asked explicitly. Tapping the avatar used to open the library
        // directly, so taking a NEW photo meant leaving the app, using the camera, coming
        // back and picking it — for what is overwhelmingly a selfie.
        .confirmationDialog("Profile photo", isPresented: $showPhotoSource, titleVisibility: .hidden) {
            // Only offered when there IS a camera. On a device without one this button
            // would open a black screen with no way out.
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo") { showCamera = true }
            }
            Button("Choose from Library") { showLibrary = true }
            Button("Cancel", role: .cancel) {}
        }
        .fullScreenCover(isPresented: $showCamera) {
            CameraPicker { image in
                Task { await uploadCaptured(image) }
            }
            .ignoresSafeArea()
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
    }

    // MARK: - Actions

    private func save() async {
        let newName = trimmedName
        guard !newName.isEmpty else { return }
        saving = true
        defer { saving = false }

        // Only send fields that actually changed. username unchanged → omit it (avoids a
        // spurious 409 for re-submitting your own handle).
        let newBio = trimmedBio
        let newUsername = trimmedUsername
        let bioChanged = newBio != (session.profile.bio ?? "")
        let usernameChanged = newUsername != (session.profile.username ?? "")

        // Local first. This is on screen and on disk before the network is touched.
        session.updateProfile(fullName: newName,
                              bio: bioChanged ? newBio : nil,
                              username: usernameChanged ? newUsername : nil)
        do {
            _ = try await ProfileService.shared.updateProfile(
                fullName: newName,
                bio: bioChanged ? newBio : nil,
                username: usernameChanged ? newUsername : nil)
            syncWarning = nil
            Haptics.success()
            dismiss()
        } catch let APIError.http(status, _, _) where status == 409 {
            // The username was taken between the check and the save.
            usernameAvailable = false
            syncWarning = "That username was just taken. Pick another."
            Haptics.error()
        } catch {
            // Do not pop: the user should see that the local save landed and the sync did
            // not. Be honest about the retry story — there is NO background retry queue for
            // the profile, so "will sync when you're back online" was a promise the app does
            // not keep. It syncs next time the user edits and saves; say that.
            syncWarning = "Saved on this device. It’ll sync the next time you save with a connection."
            Haptics.error()
        }
    }

    /// A camera capture. Shares the upload path with the library picker rather than
    /// duplicating it — the only difference is where the bytes came from.
    ///
    /// JPEG at 0.85: a full-resolution capture from a modern iPhone is several megabytes,
    /// and this is displayed at 104pt. Uploading the original would cost the user's data
    /// for detail no screen in the app can show.
    private func uploadCaptured(_ image: UIImage) async {
        guard let data = image.jpegData(compressionQuality: 0.85) else { return }
        await uploadImageData(data)
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self) else { return }
        await uploadImageData(data)
    }

    /// The one upload path, shared by camera and library.
    private func uploadImageData(_ data: Data) async {
        uploading = true
        defer { uploading = false }
        do {
            let url = try await MediaService.shared.uploadProfilePhoto(data)
            // Local-first: cache the bytes we just uploaded under the returned key so the
            // avatar shows INSTANTLY everywhere — no presigned re-download (the 15–20s wait).
            if let img = UIImage(data: data) { AvatarCache.store(img, data: data, forKey: url) }
            session.updateProfile(photoURL: url)
            _ = try await ProfileService.shared.updateProfile(photoURL: url)
            syncWarning = nil
            Haptics.success()
        } catch {
            // Be precise about which half failed. The photo is already applied locally,
            // so "try again" would be wrong — but there is no retry queue for profile
            // sync yet, so promising it will sync would also be wrong. Say exactly that.
            syncWarning = "Photo saved on this device, but syncing failed. Pick it again to retry."
            Haptics.error()
        }
    }
}
