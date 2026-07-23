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
    @State private var loaded = false

    @State private var photoItem: PhotosPickerItem?
    @State private var uploading = false

    @State private var saving = false
    @State private var confirmDiscard = false
    @State private var syncWarning: String?

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isDirty: Bool {
        loaded && trimmedName != session.profile.fullName
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
                Button("Save") { Task { await save() } }
                    .fontWeight(.semibold)
                    .foregroundStyle(VoiidColor.primary)
                    .disabled(!isDirty || saving || trimmedName.isEmpty)
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
            loaded = true
        }
    }

    // MARK: - Photo

    private var photoSection: some View {
        SettingsSection {
            // The avatar itself is not the tap target — the labelled button below it is.
            // One unambiguous control beats a picture that might be a button.
            HStack {
                Spacer()
                ProfileAvatarButton(photoURL: session.profile.photoURL,
                                    name: session.profile.fullName,
                                    size: 96)
                Spacer()
            }
            .padding(.vertical, VoiidSpacing.sm)
            .listRowBackground(Color.clear)
            .accessibilityHidden(true)

            // No "Remove Photo": clearing photo_url server-side is unverified, and a
            // button that might not do what it says has no place here.
            PhotosPicker(selection: $photoItem, matching: .images) {
                HStack {
                    Spacer()
                    if uploading {
                        ProgressView().tint(VoiidColor.primary)
                    } else {
                        Text("Change Photo")
                            .font(.body)
                            .foregroundStyle(VoiidColor.primary)
                    }
                    Spacer()
                }
            }
            .disabled(uploading)
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await uploadPhoto(item) }
            }
        }
    }

    // MARK: - Actions

    private func save() async {
        let newName = trimmedName
        guard !newName.isEmpty else { return }
        saving = true
        defer { saving = false }

        // Local first. This is on screen and on disk before the network is touched.
        session.updateProfile(fullName: newName)
        do {
            _ = try await ProfileService.shared.updateProfile(fullName: newName)
            syncWarning = nil
            Haptics.success()
            dismiss()
        } catch {
            // Do not pop: the user should see that the local save landed and the sync did
            // not. Be honest about the retry story — there is NO background retry queue for
            // the profile, so "will sync when you're back online" was a promise the app does
            // not keep. It syncs next time the user edits and saves; say that.
            syncWarning = "Saved on this device. It’ll sync the next time you save with a connection."
            Haptics.error()
        }
    }

    private func uploadPhoto(_ item: PhotosPickerItem) async {
        uploading = true
        defer { uploading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else { return }
            let url = try await MediaService.shared.uploadProfilePhoto(data)
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
