//
//  CreatorHandleSheet.swift
//  Voiid
//
//  THE GATE — a creator profile is required before a first clip can be posted, and this is
//  where it gets created: on demand, at first post, not at signup (see 029's header for why
//  manufacturing a public identity for every account is both a privacy and a namespace
//  problem).
//
//  ── THIS IS PUBLIC, AND THE COPY SAYS SO ─────────────────────────────────────────
//  A creator handle is BROADCAST IDENTITY: visible to strangers, attached to every clip.
//  It is NOT the chat @username, which is half a private credential (username + PIN opens a
//  message request). They share one namespace so that a single @name can never mean two
//  different people, but they are different things and the sheet must not imply otherwise.
//

import SwiftUI

struct CreatorHandleSheet: View {
    @EnvironmentObject var creators: CreatorEngine
    @Environment(\.dismiss) private var dismiss

    /// Called with the created profile once the gate is satisfied. The caller resumes
    /// whatever it was trying to do (posting a clip).
    var onCreated: (CreatorService.Profile) -> Void

    @State private var handle = ""
    @State private var displayName = ""
    @State private var bio = ""
    @State private var state: CreatorEngine.HandleState = .idle
    @State private var submitting = false
    @State private var errorText: String?
    @FocusState private var handleFocused: Bool

    /// Submission needs only a well-formed handle. The availability check is ADVISORY —
    /// blocking on `.available` would strand the user whenever the check itself failed,
    /// and the create call re-validates under the real unique constraint regardless.
    private var canSubmit: Bool {
        !submitting && CreatorEngine.isWellFormed(normalized) && state != .taken
    }

    private var normalized: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    header
                    handleField
                    displayNameField
                    bioField
                    publicNotice
                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                    }
                    VoiidPrimaryButton(title: submitting ? "Creating…" : "Create profile",
                                       enabled: canSubmit) {
                        Haptics.tap()
                        Task { await submit() }
                    }
                    .padding(.top, VoiidSpacing.sm)
                }
                .padding(VoiidSpacing.md)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Choose your handle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .onAppear { handleFocused = true }
            .onDisappear { creators.cancelHandleCheck() }
        }
        .interactiveDismissDisabled(submitting)
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text("Pick a name for your clips")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("This is how people find and follow you on Clips.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
        }
    }

    private var handleField: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            HStack(spacing: 0) {
                Text("@")
                    .font(VoiidFont.body)
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.leading, VoiidSpacing.md)
                TextField("", text: $handle, prompt:
                    Text("handle").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.body)
                    .foregroundColor(VoiidColor.textPrimary)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($handleFocused)
                    .padding(.horizontal, VoiidSpacing.sm)
                statusIcon
                    .padding(.trailing, VoiidSpacing.md)
            }
            .frame(height: 61)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            // Lowercased as you type rather than at submit, so what the field shows is
            // exactly what gets reserved — handles are case-insensitive server-side.
            .onChange(of: handle) { _, new in
                let lower = new.lowercased()
                if lower != new { handle = lower; return }
                errorText = nil
                creators.checkHandle(lower) { state = $0 }
            }

            Text(hint)
                .font(VoiidFont.caption)
                .foregroundColor(hintColor)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch state {
        case .checking:
            ProgressView().controlSize(.small).tint(VoiidColor.textSecondary)
        case .available:
            Image(systemName: "checkmark.circle.fill").foregroundColor(VoiidColor.success)
        case .taken, .badFormat:
            Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.error)
        case .idle, .failed:
            EmptyView()
        }
    }

    private var borderColor: Color {
        switch state {
        case .available: return VoiidColor.success
        case .taken, .badFormat: return VoiidColor.error
        default: return handleFocused ? VoiidColor.primary : VoiidColor.fieldBorder
        }
    }

    private var hint: String {
        switch state {
        case .available: return "@\(normalized) is available."
        case .taken: return "That handle is taken."
        case .badFormat, .idle:
            return "3–20 characters. Letters, numbers and underscores, starting with a letter."
        case .checking: return "Checking…"
        case .failed(let m): return m
        }
    }

    private var hintColor: Color {
        switch state {
        case .available: return VoiidColor.success
        case .taken, .badFormat: return VoiidColor.error
        default: return VoiidColor.textSecondary
        }
    }

    private var displayNameField: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text("Display name").font(VoiidFont.footnote)
                .foregroundColor(VoiidColor.textSecondary)
            VoiidTextField(placeholder: "Optional", text: $displayName)
        }
    }

    private var bioField: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text("Bio").font(VoiidFont.footnote)
                .foregroundColor(VoiidColor.textSecondary)
            VoiidTextField(placeholder: "Optional", text: $bio)
        }
    }

    /// Clips are not end-to-end encrypted, and §6 of the rebuild doc is explicit that the UI
    /// must say so plainly rather than let someone assume Clips behaves like their chats.
    private var publicNotice: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "globe")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            Text("Your handle, profile and clips are public and are not end-to-end encrypted. "
                 + "Your messages, calls and locations stay encrypted.")
                .font(VoiidFont.caption)
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.fieldFill.opacity(0.6))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: - Submit

    private func submit() async {
        submitting = true
        errorText = nil
        defer { submitting = false }

        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bio.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let profile = try await creators.createProfile(
                handle: normalized,
                displayName: name.isEmpty ? nil : name,
                bio: b.isEmpty ? nil : b,
                linkURL: nil)
            Haptics.tap()
            onCreated(profile)
            dismiss()
        } catch let e as APIError {
            // 409 is the race this sheet cannot prevent: the advisory check said free, and
            // somebody took the name in between. Surfaced on the field, not as a generic
            // failure, so the fix (pick another) is obvious.
            if case .http(let status, let message, _) = e {
                switch status {
                case 409: state = .taken; errorText = "That handle was just taken. Try another."
                case 400: state = .badFormat; errorText = message
                default: errorText = message
                }
            } else {
                errorText = e.localizedDescription
            }
        } catch {
            errorText = error.localizedDescription
        }
    }
}
