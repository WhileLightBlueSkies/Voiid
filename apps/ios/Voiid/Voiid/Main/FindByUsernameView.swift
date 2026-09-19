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
    /// A handle to resolve on appear, from a scanned QR or an opened voiid.app/u/<handle>
    /// link. The SCAN REPLACES TYPING AND NOTHING ELSE: the PIN step and the request still
    /// happen exactly as they do for a typed handle, because a QR proves someone showed you
    /// a code, not that its owner agreed to hear from you.
    var prefilledHandle: String? = nil
    var onScanAgain: (() -> Void)? = nil

    /// Called with the conversation id once a chat is opened, so the caller can navigate.
    /// Declared last so a trailing closure reads naturally at both call sites.
    var onOpen: (String, Bool) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var handle = ""
    /// Guards the prefill so re-rendering cannot re-run the lookup underneath the user.
    @State private var didPrefill = false
    @State private var profile: ContactPinService.PublicProfile?
    @State private var pin = ""
    @State private var looking = false
    @State private var sending = false
    @State private var error: String?
    @FocusState private var handleFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var lookupTask: Task<Void, Never>?
    @State private var pendingConversationId: String?

    var body: some View {
        Group {
            if onScanAgain != nil { scannedBody } else { usernameBody }
        }
        .onDisappear { lookupTask?.cancel() }
        .interactiveDismissDisabled(sending)
    }

    private var usernameBody: some View {
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
                        // The person RESOLVES INTO PLACE rather than appearing. Arriving here
                        // from a scan, this card is the answer to "who did I just scan" — a
                        // hard cut makes the two screens feel unrelated, and the PIN field
                        // inside it is a demand that lands better after a beat of arrival.
                        //
                        // Damped, no bounce: the celebration already happened on the scanner.
                        // This is a result settling, not a reward.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 8)),
                            removal: .opacity
                        ))
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
            .onAppear {
                // A scanned handle resolves itself and leaves the keyboard down — the user
                // has nothing left to type at this step. A typed handle focuses the field.
                if let scanned = prefilledHandle, !didPrefill {
                    didPrefill = true
                    handle = scanned
                    lookup()
                } else if !didPrefill {
                    handleFocused = true
                }
            }
        }
        .tint(VoiidColor.primary)
    }

    private var scannedBody: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    QRScreenHeading(title: pendingConversationId == nil ? "Profile preview" : "Request sent",
                                    subtitle: pendingConversationId == nil ? "Here’s the person from your QR code." : "They’ll decide whether to accept your request.")
                    if let p = profile {
                        scannedProfileCard(p)
                    } else {
                        VStack(spacing: 16) {
                            if looking {
                                ProgressView()
                                Text("Looking up @\(cleanHandle)…")
                            } else {
                                Image(systemName: "person.crop.circle.badge.questionmark")
                                    .font(.system(size: 40))
                                Text("Couldn’t load this profile")
                            }
                        }
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    if let error {
                        Text(error)
                            .font(.system(.subheadline, design: .rounded))
                            .foregroundStyle(VoiidColor.error)
                            .accessibilityIdentifier("scan.profileError")
                    }
                }
                .frame(maxWidth: 520)
                .frame(maxWidth: .infinity)
                .padding(24)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(VoiidColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { scannedActions }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { onScanAgain?() } label: {
                        Image(systemName: "chevron.left").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Back to scanner")
                    .disabled(sending)
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                guard !didPrefill else { return }
                didPrefill = true
                handle = prefilledHandle ?? ""
                lookup()
            }
        }
        .tint(VoiidColor.primary)
    }

    private func scannedProfileCard(_ p: ContactPinService.PublicProfile) -> some View {
        VStack(spacing: 16) {
            QRIdentityAvatar(photoURL: p.photo_url, name: p.full_name ?? p.username ?? "?")
            Text(p.full_name?.isEmpty == false ? p.full_name! : (p.username ?? "Voiid profile"))
                .font(.system(.title2, design: .rounded, weight: .bold))
                .foregroundStyle(VoiidColor.textPrimary)
                .multilineTextAlignment(.center)
            Text("@\(p.username ?? cleanHandle)")
                .font(.system(.subheadline, design: .rounded))
                .foregroundStyle(VoiidColor.textSecondary)
            if let bio = p.bio, !bio.isEmpty {
                Text(bio).font(.system(.body, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Divider().padding(.vertical, 4)
            if pendingConversationId != nil {
                Label("Waiting for them to accept", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(VoiidColor.accentInk)
                    .font(.system(.headline, design: .rounded))
                    .accessibilityIdentifier("scan.requestSent")
            } else if !p.reachable_by_username {
                Text("This person can’t be reached by username.")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            } else if p.requires_pin {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Contact PIN", systemImage: "lock")
                        .font(.system(.headline, design: .rounded))
                    Text("Ask them for their 6-digit PIN to send a request.")
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(VoiidColor.textSecondary)
                    TextField("6-digit PIN", text: $pin)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .font(.system(.title2, design: .rounded)).monospacedDigit()
                        .padding(16)
                        .background(VoiidColor.fieldFill, in: RoundedRectangle(cornerRadius: 14))
                        .onChange(of: pin) { _, value in
                            let digits = String(value.filter { $0 >= "0" && $0 <= "9" }.prefix(6))
                            if pin != digits { pin = digits }
                        }
                        .accessibilityLabel("Contact PIN")
                        .accessibilityIdentifier("scan.contactPin")
                }
                .foregroundStyle(VoiidColor.textPrimary)
            } else {
                Label(p.is_mutual_contact ? "You’re in each other’s contacts" : "They’ll receive a message request",
                      systemImage: "person.crop.circle.badge.checkmark")
                    .font(.system(.subheadline, design: .rounded))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
    }

    private var scannedActions: some View {
        VStack(spacing: 12) {
            if let conversationId = pendingConversationId {
                Button("Done") {
                    dismiss()
                    onOpen(conversationId, true)
                }
                .buttonStyle(QRActionButtonStyle())
            } else if let p = profile, p.reachable_by_username {
                Button { Haptics.rigid(); send(p) } label: {
                    if sending { ProgressView().tint(VoiidColor.textOnPrimary) }
                    else { Text(p.is_mutual_contact ? "Message" : "Send request") }
                }
                .buttonStyle(QRActionButtonStyle())
                .disabled(sending || (p.requires_pin && pin.count != 6))
                .opacity(sending || (p.requires_pin && pin.count != 6) ? 0.5 : 1)
                .accessibilityIdentifier("scan.messageProfile")
            } else if !looking && profile == nil {
                Button("Try again", action: lookup).buttonStyle(QRActionButtonStyle())
            }
            Button("Scan again") { onScanAgain?() }
                .buttonStyle(QRActionButtonStyle(secondary: true))
                .disabled(sending)
                .accessibilityIdentifier("scan.again")
        }
        .frame(maxWidth: 520)
        .padding(.horizontal, 24)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity)
        .background(VoiidColor.background)
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
                    .font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
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
        lookupTask?.cancel()
        looking = true
        error = nil
        profile = nil
        pin = ""
        lookupTask = Task {
            do {
                let found = try await ContactPinService.shared.lookup(username: h)
                guard !Task.isCancelled else { return }
                guard cleanHandle == h else { looking = false; return }
                withAnimation(.easeOut(duration: reduceMotion ? 0.15 : 0.2)) { profile = found }
            } catch {
                // Do not distinguish "no such handle" from other failures any more than the
                // server already does — a precise message here would help someone enumerate
                // which handles exist.
                guard !Task.isCancelled else { return }
                guard cleanHandle == h else { looking = false; return }
                if case APIError.http(404, _, _) = error {
                    self.error = "No one found with that username."
                } else {
                    self.error = "Couldn’t load this profile. Check your connection and try again."
                }
            }
            looking = false
        }
    }

    private func send(_ p: ContactPinService.PublicProfile) {
        guard !sending, pendingConversationId == nil, p.reachable_by_username,
              !p.requires_pin || pin.count == 6 else { return }
        sending = true
        error = nil
        Task {
            do {
                let result = try await ContactPinService.shared.requestChat(
                    username: p.username ?? cleanHandle,
                    pin: p.requires_pin ? pin : nil)
                if onScanAgain != nil && result.pending {
                    pendingConversationId = result.conversationId
                    pin = ""
                    Haptics.success()
                } else {
                    dismiss()
                    onOpen(result.conversationId, result.pending)
                }
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
