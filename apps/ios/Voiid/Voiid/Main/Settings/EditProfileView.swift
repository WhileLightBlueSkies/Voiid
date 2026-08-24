//
//  EditProfileView.swift
//  Voiid
//
//  ┌──────────────────────────────────────────────────────────────────────────────┐
//  │ INTERIM IMPLEMENTATION — owned by Implementer 2, who replaces this FILE       │
//  │ WHOLESALE with the full screen in spec §5.1.                                  │
//  │                                                                              │
//  │ Still to come from §5.1: Email.                                              │
//  │                                                                              │
//  │ DONE since this box was written: About/bio, Username with debounced async     │
//  │ availability checking, and "Delete My Account" — which files a DPDP erasure   │
//  │ request (DPDPService) and then runs                                          │
//  │ `SessionTeardown.wipeLocalAccountState()` + `session.signOut()`. See          │
//  │ `dangerZone` for why it says "request" and not "deleted".                     │
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
//  CHROME NOTE: this screen is built on the shared card vocabulary in `SettingsChrome.swift`
//  (`VoiidSettingsHeader` / `VoiidCardSection` / `VoiidSettingsRow`) rather than an
//  inset-grouped `List`, so it matches every other pushed Settings screen. That conversion was
//  purely visual — every binding, validation rule, upload path and save call below is
//  unchanged from the List version.
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

    // Delete my account (DPDP erasure). See `dangerZone`.
    @State private var confirmDelete = false
    @State private var deleting = false
    /// The server's own note about what filing the request did and did not do.
    @State private var deleteNote: String?
    @State private var deleteDue: String?
    @State private var deleteError: String?
    /// True once a request is on file and the user has yet to acknowledge it. Gates the
    /// local teardown so the device is not wiped out from under the message explaining it.
    @State private var awaitingSignOut = false
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
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                // The header carries the end-to-end-encryption statement as its badge — the
                // same promise the standalone pill used to make, in the slot the shared
                // vocabulary provides for exactly that. It is a statement, not a control, and
                // nothing happens when you tap it.
                //
                // Why it is on this screen at all: this screen collects a name, a username, a
                // photo and an "about" line, and the live app said nothing at all about where
                // any of it goes. On a privacy-first messenger that silence is the wrong
                // default — the reassurance belongs ON the screen doing the collecting, not
                // buried in a settings page nobody opens.
                VoiidSettingsHeader("Edit Profile",
                                    subtitle: "Your name, photo and handle, as everyone you "
                                            + "chat with sees them.",
                                    badge: (icon: "checkmark.shield.fill",
                                            text: "End-to-end encrypted"))

                photoSection

                VoiidCardSection("Name",
                                 footer: "Your name and photo are shown to everyone you chat with.") {
                    fieldRow(icon: "person") {
                        TextField("Your name", text: $name)
                            .font(.body)
                            .foregroundStyle(VoiidColor.textPrimary)
                            .textContentType(.name)
                            .submitLabel(.done)
                            .onChange(of: name) { _, new in
                                if new.count > 50 { name = String(new.prefix(50)) }
                            }
                    }
                }

                VoiidCardSection("Username",
                                 footer: usernameFooter) {
                    fieldRow(icon: "at") {
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
                }

                VoiidCardSection("About",
                                 footer: "A short line about you, shown on your profile.") {
                    fieldRow(icon: "text.alignleft") {
                        TextField("Add a few words about you", text: $bio, axis: .vertical)
                            .font(.body)
                            .foregroundStyle(VoiidColor.textPrimary)
                            .lineLimit(1...4)
                            .onChange(of: bio) { _, new in
                                if new.count > 140 { bio = String(new.prefix(140)) }
                            }
                    }
                }

                VoiidCardSection("Phone",
                                 footer: "Verified when you signed up. Changing your number isn't supported in this version.") {
                    // No `action`, so this reads as a value row rather than a door — which is
                    // the truth: the number cannot be changed here.
                    VoiidSettingsRow(icon: "phone", title: "Number") {
                        Text(session.profile.phoneNumber.isEmpty ? "—" : session.profile.phoneNumber)
                            .font(.subheadline)
                            .foregroundStyle(VoiidColor.textSecondary)
                    }
                }

                if let syncWarning {
                    VoiidCardSection {
                        Text(syncWarning)
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, VoiidSpacing.md)
                            .padding(.vertical, 11)
                    }
                }

                dangerZone
            }
            .padding(VoiidSpacing.md)
        }
        .voiidSettingsPage()
        // ── DELETING THE ACCOUNT ────────────────────────────────────────────────────────
        // Three steps, deliberately: confirm, report what the server actually did, then tear
        // the device down. Collapsing them would either wipe the device before the user could
        // read the deadline, or claim a deletion that has not happened.
        .confirmationDialog("Delete your Voiid account?",
                            isPresented: $confirmDelete,
                            titleVisibility: .visible) {
            Button("Delete my account", role: .destructive) { Task { await performDelete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            // What actually happens, not "are you sure". The distinction between a filed
            // request and a completed deletion is the whole point of this sentence.
            Text("""
                 This opens an erasure request and signs you out of this iPhone immediately, \
                 wiping its messages and keys. Your account itself is erased once the request \
                 is actioned — until then you can still sign in and cancel by contacting \
                 support.
                 """)
        }
        // The outcome. Dismissing it is what triggers the local wipe, so the user cannot lose
        // the screen before reading when their data goes.
        .alert("Erasure request recorded",
               isPresented: Binding(get: { awaitingSignOut },
                                    set: { if !$0 { awaitingSignOut = false } })) {
            Button("Sign out of this iPhone") { Task { await tearDownDevice() } }
        } message: {
            Text(deleteMessage)
        }
        .alert("Couldn\u{2019}t open the request",
               isPresented: Binding(get: { deleteError != nil },
                                    set: { if !$0 { deleteError = nil } })) {
            Button("OK", role: .cancel) { deleteError = nil }
        } message: {
            // Says the account is untouched, because a failed delete that LOOKED like it
            // might have half-worked is the most alarming possible outcome here.
            Text((deleteError ?? "") + "\n\nYour account and this device are unchanged.")
        }
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
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task { await uploadPhoto(item) }
        }
        .onAppear {
            guard !loaded else { return }
            name = session.profile.fullName
            bio = session.profile.bio ?? ""
            username = session.profile.username ?? ""
            loaded = true
        }
    }

    /// The server's sentence, plus the deadline when one parsed. Built here rather than
    /// inline in the alert: the nested optional chain was too much for the type-checker to
    /// solve inside a ViewBuilder, which it reports as a spurious "failed to produce
    /// diagnostic" rather than as the expression-complexity error it is.
    private var deleteMessage: String {
        let note = deleteNote ?? "Your erasure request has been recorded."
        guard let raw = deleteDue, let due = shortDate(raw) else { return note }
        return note + "\n\nDue by \(due)."
    }

    /// ISO-8601 from Postgres, rendered short. Falls back to nil rather than to the raw
    /// string: a due date is only worth showing if it reads as a date.
    private func shortDate(_ iso: String) -> String? {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        else { return nil }
        return date.formatted(date: .abbreviated, time: .omitted)
    }

    // MARK: - Delete my account

    /// LAST, and alone. Two irreversible actions must not share a card, and a destructive
    /// control at the bottom of a scroll is one a thumb cannot land on by accident.
    ///
    /// ── WHY THIS LIVES ON EDIT PROFILE ──────────────────────────────────────────────
    /// Deleting an account is an IDENTITY operation, not a session one, so it belongs on the
    /// screen that owns your name and handle rather than beside Log Out at the settings root.
    /// One tap from root also satisfies App Review 5.1.1(v), which requires account deletion
    /// to be reachable inside the app when the app supports account creation.
    ///
    /// ── IT SAYS "REQUEST", BECAUSE THAT IS WHAT IT IS ───────────────────────────────
    /// `POST /dpdp/requests` OPENS AN ERASURE REQUEST. It queues work for a person and
    /// returns a due date; it does not delete the row. The button therefore says "Delete my
    /// account", the dialog says what actually happens, and the confirmation reports the
    /// server's own sentence plus the deadline. Wording this as "deleted" would be false at
    /// the moment of tapping — and this is the one screen where that lie would matter most.
    ///
    /// What IS immediate is local: after the request is filed, the same teardown Log Out runs
    /// wipes this device's keys, database and token. That is true and it is worth doing, so
    /// the account cannot keep receiving messages on a handset its owner meant to abandon.
    private var dangerZone: some View {
        VoiidCardSection(footer: "Voiid keeps your account until the request is actioned, so "
                               + "you can still sign in if you change your mind. This iPhone "
                               + "is signed out and wiped straight away.") {
            VoiidSettingsRow(icon: "trash",
                             title: "Delete my account",
                             detail: "Opens an erasure request and signs this device out",
                             destructive: true,
                             action: {
                                 Haptics.rigid()
                                 confirmDelete = true
                             }) {
                if deleting { ProgressView().controlSize(.small) }
            }
            .disabled(deleting)
        }
        .padding(.top, VoiidSpacing.lg)
    }

    /// File the request, then tear this device down.
    ///
    /// ORDER MATTERS: the request is filed FIRST, because `wipeLocalAccountState()` clears
    /// the JWT and an unauthenticated client cannot open a request. A failure here therefore
    /// leaves the account fully intact and signed in, which is the correct outcome — better a
    /// user who must try again than one signed out of an account that was never queued.
    private func performDelete() async {
        deleting = true
        defer { deleting = false }
        do {
            let outcome = try await DPDPService.shared.requestErasure()
            // The server's own sentence, not a paraphrase — it is the statement that a
            // request is not a deletion, and two copies of a compliance claim drift.
            deleteNote = outcome.note ?? "Your erasure request has been recorded."
            deleteDue = outcome.request?.due_at
            Haptics.success()
        } catch let error as APIError {
            // 409 = one open request per kind already exists. The user asked for something
            // that is already happening, so this is not a failure to report as one.
            if case .http(let status, _, _) = error, status == 409 {
                deleteNote = "You already have an erasure request open. It is still being "
                           + "actioned; filing another would not make it faster."
                Haptics.success()
            } else {
                deleteError = error.errorDescription ?? "Couldn\u{2019}t open the request."
                return
            }
        } catch {
            deleteError = error.localizedDescription
            return
        }
        // Only reached when the request is genuinely on file.
        awaitingSignOut = true
    }

    /// The local half, run after the user has read what the server said.
    private func tearDownDevice() async {
        await SessionTeardown.wipeLocalAccountState()
        session.signOut()
        dismiss()
    }

    /// A full-width text-entry row inside a `VoiidCardSection`.
    ///
    /// `VoiidSettingsRow`'s trailing slot is too narrow for a field you type a sentence into,
    /// so text entry gets its own row shape — but it reuses the SAME icon column and the same
    /// horizontal (`VoiidSpacing.md`) and vertical (11) padding, so it lines up exactly with
    /// the value rows in the other cards.
    private func fieldRow<Field: View>(icon: String,
                                       @ViewBuilder field: () -> Field) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: icon)
            field()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
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

    /// The editable avatar, centred on the plain page background rather than inside a card:
    /// it is the subject of this screen, not one of its settings.
    private var photoSection: some View {
        VStack(spacing: VoiidSpacing.sm) {
            // THE AVATAR IS THE BUTTON, with a camera badge on it.
            //
            // The old layout put a 96pt avatar alone in one card with nothing else in
            // it — a band of empty white — and "Change Photo" in a SECOND card below,
            // which is what made the top of this screen read as blank. They are one
            // thing and now sit together, and the badge means the photo itself looks
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
                            // Ringed in the page's own ground so the badge reads as ON the
                            // avatar rather than floating beside it. (It rings `background`
                            // rather than `surfaceCard` now only because the avatar sits on
                            // the page, not in a card.)
                            .overlay(Circle().strokeBorder(VoiidColor.background, lineWidth: 3))
                    }
                }
            }
            .buttonStyle(.plain)
            .disabled(uploading)
            .accessibilityLabel("Change profile photo")

            // SAY THAT THE PHOTO IS ALREADY SAVED. It uploads the instant you pick it —
            // Save covers only the text fields — so without this line a user changes their
            // photo, sees Save still greyed out, and reasonably concludes nothing happened.
            Text("Your photo saves as soon as you choose it.")
                .font(.footnote)
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.sm)
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
