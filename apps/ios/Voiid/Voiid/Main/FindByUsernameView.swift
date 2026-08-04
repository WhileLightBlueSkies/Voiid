//
//  FindByUsernameView.swift
//  Voiid
//
//  Reach someone by @username (see 020_reachability.sql).
//
//  A SEPARATE screen from "New chat", deliberately. New chat browses people you already have —
//  your address book, already matched. This is the opposite: someone you may never have met,
//  found by a handle they gave you. Mixing the two would put strangers in the same list as
//  your contacts, which is exactly the boundary the whole reachability design protects.
//
//  THE FLOW, and why each step exists:
//    1. type a handle          — resolves to a PUBLIC profile only, never a phone number
//    2. if you are mutual contacts, send straight away — you have already proved acquaintance
//    3. otherwise enter their 6-digit PIN — proof they actually gave you their handle
//    4. the message lands as a REQUEST — they still choose whether to accept
//
//  Two independent gates, so a leaked PIN alone is never enough to reach someone.
//

import SwiftUI

struct FindByUsernameView: View {
    /// Called with the conversation id once a chat is opened, so the caller can navigate.
    var onOpen: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    @State private var profile: ContactPinService.PublicProfile?
    @State private var pin = ""
    @State private var looking = false
    @State private var sending = false
    @State private var error: String?
    @FocusState private var handleFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 6) {
                        Text("@")
                            .font(VoiidFont.rounded(17, .medium))
                            .foregroundStyle(VoiidColor.textSecondary)
                        TextField("username", text: $handle)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .focused($handleFocused)
                            .submitLabel(.search)
                            .onSubmit { lookup() }
                            // A new handle invalidates whatever we resolved before — otherwise
                            // you could look up one person, retype, and send to the first.
                            .onChange(of: handle) { _, _ in profile = nil; error = nil; pin = "" }
                        if looking { ProgressView() }
                    }
                } footer: {
                    Text("Ask for someone's Voiid handle, then their PIN if you're not already in each other's contacts.")
                }

                if let p = profile {
                    resultSection(p)
                }

                if let error {
                    Section {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(VoiidColor.error)
                    }
                }
            }
            .voiidSettingsList()
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Find by username")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(VoiidColor.textSecondary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Find") { lookup() }
                        .disabled(cleanHandle.isEmpty || looking)
                        .foregroundStyle(VoiidColor.primary)
                }
            }
            .onAppear { handleFocused = true }
        }
        .tint(VoiidColor.primary)
    }

    @ViewBuilder
    private func resultSection(_ p: ContactPinService.PublicProfile) -> some View {
        Section {
            HStack(spacing: VoiidSpacing.md) {
                ProfileAvatarButton(photoURL: p.photo_url,
                                    name: p.full_name ?? p.username ?? "?",
                                    size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(p.full_name?.isEmpty == false ? p.full_name! : (p.username ?? "Unknown"))
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                    if let u = p.username {
                        Text("@\(u)")
                            .font(VoiidFont.rounded(13, .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                    }
                }
                Spacer()
            }
            .padding(.vertical, 4)

            if !p.reachable_by_username {
                // They never set a PIN. Say so plainly rather than letting the user type six
                // digits that could never work.
                Text("This person can’t be reached by username.")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
            } else if p.requires_pin {
                // 6 digits, numeric, no autocorrect. `.oneTimeCode` gets the numeric keypad
                // without claiming this is an SMS code.
                TextField("6-digit PIN", text: $pin)
                    .keyboardType(.numberPad)
                    .textContentType(.oneTimeCode)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .onChange(of: pin) { _, v in
                        // Digits only, capped at 6 — a paste of "418 302" should still work.
                        let digits = v.filter(\.isNumber)
                        if digits != v || digits.count > 6 { pin = String(digits.prefix(6)) }
                    }
            }

            if p.reachable_by_username {
                Button {
                    Haptics.rigid()
                    send(p)
                } label: {
                    HStack {
                        Text(p.is_mutual_contact ? "Message" : "Send request")
                            .font(VoiidFont.rounded(16, .semibold))
                        if sending { Spacer(); ProgressView() }
                    }
                }
                .disabled(sending || (p.requires_pin && pin.count != 6))
                .foregroundStyle(VoiidColor.primary)
            }
        } footer: {
            if p.is_mutual_contact {
                Text("You’re both in each other’s contacts, so this opens a normal chat.")
            } else if p.requires_pin {
                Text("They’ll get a request to accept before your message appears in their chats.")
            }
        }
    }

    private var cleanHandle: String {
        handle.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "@", with: "")
    }

    private func lookup() {
        let h = cleanHandle
        guard !h.isEmpty else { return }
        looking = true
        error = nil
        profile = nil
        Task {
            do {
                profile = try await ContactPinService.shared.lookup(username: h)
            } catch {
                // Do not distinguish "no such handle" from other failures any more than the
                // server already does — a precise message here would help someone enumerate
                // which handles exist.
                self.error = "No one found with that username."
            }
            looking = false
        }
    }

    private func send(_ p: ContactPinService.PublicProfile) {
        sending = true
        error = nil
        Task {
            do {
                let result = try await ContactPinService.shared.requestChat(
                    username: p.username ?? cleanHandle,
                    pin: p.requires_pin ? pin : nil)
                dismiss()
                onOpen(result.conversationId, result.pending)
            } catch let APIError.http(status, message, _) {
                // 403 is a wrong PIN, 429 is the throttle. Both are things the user can act
                // on, so they are surfaced verbatim rather than flattened into "try again".
                error = status == 403 ? "That PIN isn’t correct."
                      : status == 429 ? "Too many attempts. Try again later."
                      : (message.isEmpty ? "Couldn’t send that request." : message)
            } catch let failure {
                // Bind the caught error explicitly: a bare `catch` introduces an implicit
                // `error` constant that shadows this view's `@State var error`, so the
                // assignment below was targeting the immutable caught value and would not
                // compile. Naming it `failure` keeps the state property reachable.
                _ = failure
                error = "Couldn’t send that request. Check your connection."
            }
            sending = false
        }
    }
}
