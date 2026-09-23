//
//  CollegeEmailSheet.swift
//  Voiid
//
//  "Use your college email" — what joining an institution community asks first (088).
//
//  Two steps in one sheet: the address, then the 6-digit code emailed to it. The server does
//  the checking (domain, code, expiry, attempts) and the join route refuses anyone who hasn't
//  done this, so this sheet is guidance, not the gate. Once an address is proven it counts
//  for every community that accepts its domain, so nobody does this twice for one college.
//

import SwiftUI

struct CollegeEmailSheet: View {
    let card: CommunityService.CommunityCard
    /// Called after the address is proven; the caller retries the join.
    var onVerified: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?
    @FocusState private var focused: Bool

    private var domains: [String] { card.email_domains ?? [] }
    private var domainText: String { domains.map { "@\($0)" }.joined(separator: " or ") }
    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespaces).lowercased() }

    /// Same rule as the server: the host is a domain or a subdomain of one.
    private var emailMatches: Bool {
        guard let at = trimmedEmail.lastIndex(of: "@"), at != trimmedEmail.startIndex else { return false }
        let host = String(trimmedEmail[trimmedEmail.index(after: at)...])
        return domains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    VStack(alignment: .leading, spacing: 6) {
                        InstitutionMark(name: card.institution_name)
                        Text(codeSent ? "Check your inbox" : "Use your college email")
                            .font(VoiidFont.rounded(24, .bold))
                            .foregroundColor(VoiidColor.textPrimary)
                        Text(codeSent
                             ? "We sent a 6-digit code to \(trimmedEmail). It expires in 10 minutes."
                             : "\(card.name) is only for people with a \(domainText) email. We\u{2019}ll send you a code to confirm it\u{2019}s yours.")
                            .font(VoiidFont.rounded(14))
                            .foregroundColor(VoiidColor.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    VoiidCardSection {
                        if codeSent {
                            TextField("6-digit code", text: Binding(get: { code }, set: { code = String($0.filter(\.isNumber).prefix(6)) }))
                                .keyboardType(.numberPad)
                                .textContentType(.oneTimeCode)
                                .font(VoiidFont.rounded(20, .semibold))
                                .monospacedDigit()
                                .focused($focused)
                                .padding(.horizontal, VoiidSpacing.md)
                                .frame(height: 52)
                        } else {
                            TextField(domains.first.map { "you@\($0)" } ?? "College email", text: $email)
                                .keyboardType(.emailAddress)
                                .textContentType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .font(VoiidFont.rounded(16))
                                .focused($focused)
                                .padding(.horizontal, VoiidSpacing.md)
                                .frame(height: 52)
                        }
                    }

                    if let error {
                        Label(error, systemImage: "exclamationmark.circle.fill")
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.error)
                    } else if !codeSent && !email.isEmpty && !emailMatches && email.contains("@") {
                        Text("Use your \(domainText) address.")
                            .font(VoiidFont.rounded(13))
                            .foregroundColor(VoiidColor.textSecondary)
                    }

                    Button {
                        Task { codeSent ? await confirm() : await send() }
                    } label: {
                        Group {
                            if busy { ProgressView().tint(VoiidColor.textOnAccent) }
                            else { Text(codeSent ? "Verify and join" : "Send code").font(VoiidFont.rounded(16.5, .semibold)) }
                        }
                        .foregroundColor(VoiidColor.textOnAccent)
                        .frame(maxWidth: .infinity).frame(height: 52)
                        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous).fill(VoiidColor.accent))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(busy || (codeSent ? code.count != 6 : !emailMatches))
                    .opacity((codeSent ? code.count == 6 : emailMatches) ? 1 : 0.45)

                    if codeSent {
                        HStack {
                            Button("Use a different email") {
                                codeSent = false; code = ""; error = nil
                            }
                            Spacer()
                            Button("Resend code") { Task { await send() } }
                                .disabled(busy)
                        }
                        .font(VoiidFont.rounded(13.5, .semibold))
                        .tint(VoiidColor.accentInk)
                    }
                }
                .padding(VoiidSpacing.md)
            }
            .softScrollEdge([.top, .bottom])
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Join \(card.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(busy) }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func send() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await CommunityService.shared.startEmailVerification(communityId: card.id, email: trimmedEmail)
            Haptics.success()
            withAnimation(.easeOut(duration: 0.2)) { codeSent = true }
            code = ""
            focused = true
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t send the code. Try again."
        }
    }

    private func confirm() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            try await CommunityService.shared.confirmEmailVerification(communityId: card.id, email: trimmedEmail, code: code)
            Haptics.success()
            dismiss()
            onVerified()
        } catch {
            Haptics.error()
            self.error = (error as? APIError)?.errorDescription ?? "That code didn\u{2019}t work. Try again."
        }
    }
}
