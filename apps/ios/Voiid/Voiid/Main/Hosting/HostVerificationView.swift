//
//  HostVerificationView.swift
//  Voiid
//
//  "Get verified to sell tickets" — the host's side of KYC (routes/kyc.ts).
//
//  ── ONE SCREEN, FIVE STATES ─────────────────────────────────────────────────────
//  Unavailable (the server has no verification provider), the form (not started, or
//  rejected with the reason shown above it), in review, and verified. Each state says what
//  happens next in one sentence, because "pending" with nothing after it reads as broken.
//
//  ── THE NUMBERS ─────────────────────────────────────────────────────────────────
//  PAN and account number live in this view's state only until Submit returns, then they are
//  cleared. Voiid keeps the last four characters; Cashfree checks the rest. The copy says so,
//  because a form asking for a PAN without saying where it goes is a form people abandon.
//

import AuthenticationServices
import PhotosUI
import SwiftUI

struct HostVerificationView: View {
    @Environment(\.dismiss) private var dismiss
    /// Safari's engine in a sheet — DigiLocker's own page, with its own OTP flow.
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession
    @State private var aadhaarBusy = false
    @State private var aadhaarError: String?
    /// Fired when the host becomes verified, so a price field behind this can unlock.
    var onVerified: () -> Void = {}

    @State private var status: KycService.Verification?
    @State private var loading = true
    @State private var loadError: String?

    @State private var legalName = ""
    @State private var email = ""
    @State private var pan = ""
    @State private var account = ""
    @State private var accountAgain = ""
    @State private var ifsc = ""
    /// Paid to a bank account or to a UPI ID — Cashfree pays out to either.
    @State private var payoutUPI = false
    @State private var upi = ""
    @State private var submitting = false
    @State private var submitError: String?

    @State private var docKind: KycService.DocumentKind = .pan_card
    @State private var pickedDoc: PhotosPickerItem?
    @State private var uploading = false
    @State private var uploadError: String?

    private static let panRE = /^[A-Z]{5}[0-9]{4}[A-Z]$/
    private static let ifscRE = /^[A-Z]{4}0[A-Z0-9]{6}$/
    private static let upiRE = /^[a-z0-9._-]{2,256}@[a-z][a-z0-9.-]{1,64}$/

    private var formProblem: String? {
        if legalName.trimmingCharacters(in: .whitespaces).count < 2 { return "Enter your full name as on your PAN." }
        if !email.contains("@") || !email.contains(".") { return "Enter your email." }
        if pan.wholeMatch(of: Self.panRE) == nil { return "Enter a valid PAN, e.g. ABCDE1234F." }
        if payoutUPI {
            if upi.wholeMatch(of: Self.upiRE) == nil { return "Enter your UPI ID, e.g. name@okhdfcbank." }
            return nil
        }
        if account.count < 6 { return "Enter your bank account number." }
        if account != accountAgain { return "The account numbers don\u{2019}t match." }
        if ifsc.wholeMatch(of: Self.ifscRE) == nil { return "Enter a valid IFSC, e.g. HDFC0001234." }
        return nil
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    if loading {
                        ProgressView().frame(maxWidth: .infinity).padding(.top, 60)
                    } else if let loadError {
                        message(icon: "wifi.exclamationmark", title: "Couldn\u{2019}t load", text: loadError)
                    } else if let status {
                        content(status)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.md)
            }
            .scrollDismissesKeyboard(.interactively)
            .softScrollEdge([.top, .bottom])
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Get verified")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }.disabled(submitting || uploading)
                }
            }
            .interactiveDismissDisabled(submitting || uploading)
            .task { await load() }
            .onChange(of: pickedDoc) { _, item in
                guard let item else { return }
                Task { await upload(item) }
            }
        }
    }

    // MARK: States

    @ViewBuilder
    private func content(_ v: KycService.Verification) -> some View {
        if v.available == false && !v.isVerified {
            message(icon: "clock", title: "Paid events are coming soon",
                    text: "Voiid can\u{2019}t verify hosts yet. Free events work as usual.")
        } else if v.isVerified {
            message(icon: "checkmark.seal.fill", title: "You\u{2019}re verified",
                    text: "You can sell tickets in communities you own. Your share of each sale is paid to \(v.payout_method == "upi" ? "your UPI ID \(v.upi_masked ?? "")" : "the bank account ending \(v.bank_last4 ?? "••••")").")
            payoutSummary(v)
        } else if v.isInReview {
            message(icon: "hourglass", title: "We\u{2019}re reviewing your details",
                    text: "Your PAN and payout account passed the automatic checks. Voiid reviews every host before they can take payments \u{2014} usually within a day. Adding a document can speed it up.")
            payoutSummary(v)
            aadhaar(v)
            documents(v)
        } else {
            if v.isRejected, let reason = v.rejection_reason {
                message(icon: "exclamationmark.triangle.fill", title: "Your last application wasn\u{2019}t approved",
                        text: reason, tone: VoiidColor.error)
            }
            intro
            form
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Verify to sell tickets")
                .font(VoiidFont.rounded(24, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Ticket money is paid to your bank account or UPI ID, so we need to confirm who you are. It takes about two minutes. Free events never need this.")
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VoiidCardSection("You") {
                input("Full name as on your PAN", text: $legalName, content: .name, caps: .words)
                VoiidRowDivider(inset: VoiidSpacing.md)
                input("Email for payout updates", text: $email, content: .emailAddress, keyboard: .emailAddress, caps: .never)
                VoiidRowDivider(inset: VoiidSpacing.md)
                input("PAN", text: Binding(get: { pan }, set: { pan = String($0.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(10)) }),
                      caps: .characters)
            }
            Picker("Get paid to", selection: $payoutUPI.animation(.easeOut(duration: 0.18))) {
                Text("Bank account").tag(false)
                Text("UPI ID").tag(true)
            }
            .pickerStyle(.segmented)
            .disabled(submitting)

            if payoutUPI {
                VoiidCardSection("UPI ID for payouts",
                                 footer: "Cashfree sends ₹1 to check the UPI ID and who it belongs to.") {
                    input("name@okhdfcbank", text: Binding(get: { upi }, set: { upi = String($0.lowercased().filter { !$0.isWhitespace }.prefix(100)) }),
                          keyboard: .emailAddress)
                }
            } else {
                VoiidCardSection("Bank account for payouts",
                                 footer: "Cashfree deposits ₹1 to check the account. It\u{2019}s paid out to the name on your PAN.") {
                    input("Account number", text: Binding(get: { account }, set: { account = String($0.filter { $0.isNumber || $0.isLetter }.prefix(40)) }),
                          keyboard: .numberPad, secure: true)
                    VoiidRowDivider(inset: VoiidSpacing.md)
                    input("Re-enter account number", text: Binding(get: { accountAgain }, set: { accountAgain = String($0.filter { $0.isNumber || $0.isLetter }.prefix(40)) }),
                          keyboard: .numberPad)
                    VoiidRowDivider(inset: VoiidSpacing.md)
                    input("IFSC", text: Binding(get: { ifsc }, set: { ifsc = String($0.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(11)) }),
                          caps: .characters)
                }
            }

            Label("Voiid keeps only the last four digits of your PAN and account. Cashfree checks the rest.",
                  systemImage: "lock.shield")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)

            if let submitError {
                Label(submitError, systemImage: "exclamationmark.circle.fill")
                    .font(VoiidFont.rounded(13))
                    .foregroundColor(VoiidColor.error)
            }

            Button {
                Task { await submit() }
            } label: {
                Group {
                    if submitting { ProgressView().tint(VoiidColor.textOnAccent) }
                    else { Text("Verify").font(VoiidFont.rounded(16.5, .semibold)) }
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(maxWidth: .infinity).frame(height: 52)
                .background(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous).fill(VoiidColor.accent))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(formProblem != nil || submitting)
            .opacity(formProblem == nil ? 1 : 0.45)

            if let formProblem, !legalName.isEmpty || !pan.isEmpty || !account.isEmpty {
                Text(formProblem)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }

    private func payoutSummary(_ v: KycService.Verification) -> some View {
        VoiidCardSection("Payout details") {
            VoiidSettingsRow(icon: "person.text.rectangle", title: v.legal_name ?? "—",
                             detail: v.pan_last4.map { "PAN ending \($0)" })
            VoiidRowDivider()
            if v.payout_method == "upi" {
                VoiidSettingsRow(icon: "indianrupeesign.circle", title: "UPI ID",
                                 detail: [v.upi_masked, v.bank_name].compactMap { $0 }.joined(separator: " · "))
            } else {
                VoiidSettingsRow(icon: "building.columns", title: v.bank_name ?? "Bank account",
                                 detail: [v.bank_last4.map { "Account ending \($0)" }, v.ifsc].compactMap { $0 }.joined(separator: " · "))
            }
        }
    }

    // MARK: Aadhaar

    @ViewBuilder
    private func aadhaar(_ v: KycService.Verification) -> some View {
        VoiidCardSection("Aadhaar",
                         footer: v.aadhaar_verified == true ? nil
                               : "You\u{2019}ll sign in to DigiLocker with your Aadhaar and an OTP. Voiid only receives the last four digits \u{2014} never your full Aadhaar number.") {
            if v.aadhaar_verified == true {
                VoiidSettingsRow(icon: "checkmark.seal.fill", title: "Verified with DigiLocker",
                                 detail: "Aadhaar ending \(v.aadhaar_last4 ?? "••••")")
            } else {
                Button {
                    Task { await verifyAadhaar() }
                } label: {
                    HStack {
                        VoiidSettingsRow(icon: "person.text.rectangle",
                                         title: "Verify Aadhaar with DigiLocker",
                                         detail: v.aadhaar_required == false ? "Optional, but speeds up review." : "Needed before Voiid can approve you.")
                        if aadhaarBusy { ProgressView().padding(.trailing, VoiidSpacing.md) }
                    }
                }
                .buttonStyle(.plain)
                .disabled(aadhaarBusy)
                if let aadhaarError {
                    Text(aadhaarError)
                        .font(VoiidFont.rounded(12.5))
                        .foregroundColor(VoiidColor.error)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.bottom, 8)
                }
            }
        }
    }

    /// Link → DigiLocker in a web sheet → back via `voiid-kyc://` → the server collects the
    /// result. The server's answer is what counts: closing the sheet early still asks it, so a
    /// host who finished DigiLocker but lost the redirect is not made to do it twice.
    private func verifyAadhaar() async {
        aadhaarBusy = true; aadhaarError = nil
        defer { aadhaarBusy = false }
        do {
            let url = try await KycService.shared.startAadhaar()
            _ = try? await webAuthenticationSession.authenticate(using: url, callbackURLScheme: "voiid-kyc",
                                                                 preferredBrowserSession: .shared)
            let v = try await KycService.shared.completeAadhaar()
            Haptics.success()
            withAnimation(.easeOut(duration: 0.2)) { status = v }
        } catch {
            aadhaarError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t verify with DigiLocker. Try again."
        }
    }

    private func documents(_ v: KycService.Verification) -> some View {
        VoiidCardSection("Documents (optional)",
                         footer: "Photos go straight to private storage. Only Voiid reviewers can open them.") {
            ForEach(v.documents ?? []) { doc in
                HStack {
                    VoiidSettingsRow(icon: "doc.text", title: KycService.DocumentKind(rawValue: doc.kind)?.title ?? doc.kind)
                    Button("Remove", role: .destructive) { Task { await remove(doc.id) } }
                        .font(VoiidFont.rounded(13, .semibold))
                        .padding(.trailing, VoiidSpacing.md)
                        .disabled(uploading)
                }
                VoiidRowDivider()
            }
            HStack(spacing: VoiidSpacing.sm) {
                Picker("Document", selection: $docKind) {
                    ForEach(KycService.DocumentKind.allCases) { Text($0.title).tag($0) }
                }
                .labelsHidden()
                .tint(VoiidColor.textPrimary)
                Spacer(minLength: 0)
                PhotosPicker(selection: $pickedDoc, matching: .images) {
                    if uploading { ProgressView() } else { Text("Add photo").font(VoiidFont.rounded(14, .semibold)) }
                }
                .disabled(uploading)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 8)
            if let uploadError {
                Text(uploadError)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.error)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.bottom, 8)
            }
        }
    }

    // MARK: Pieces

    private func message(icon: String, title: String, text: String, tone: Color = VoiidColor.accentInk) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(tone)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(VoiidFont.rounded(16, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Text(text).font(VoiidFont.rounded(13.5)).foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private func input(_ placeholder: String, text: Binding<String>, content: UITextContentType? = nil,
                       keyboard: UIKeyboardType = .default, caps: TextInputAutocapitalization = .never,
                       secure: Bool = false) -> some View {
        Group {
            if secure { SecureField(placeholder, text: text) } else { TextField(placeholder, text: text) }
        }
        .font(VoiidFont.rounded(15.5))
        .textContentType(content)
        .keyboardType(keyboard)
        .textInputAutocapitalization(caps)
        .autocorrectionDisabled()
        .disabled(submitting)
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 48)
    }

    // MARK: Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let v = try await KycService.shared.me()
            status = v
            loadError = nil
            if legalName.isEmpty { legalName = v.legal_name ?? "" }
            if email.isEmpty { email = v.email ?? "" }
        } catch {
            loadError = (error as? APIError)?.errorDescription ?? "Check your connection and try again."
        }
    }

    private func submit() async {
        guard formProblem == nil, !submitting else { return }
        submitting = true
        submitError = nil
        defer { submitting = false }
        do {
            let v = try await KycService.shared.verify(.init(
                legal_name: legalName.trimmingCharacters(in: .whitespaces),
                email: email.trimmingCharacters(in: .whitespaces),
                pan: pan, payout_method: payoutUPI ? "upi" : "bank",
                bank_account: payoutUPI ? nil : account, ifsc: payoutUPI ? nil : ifsc,
                upi_id: payoutUPI ? upi : nil))
            // The numbers have done their job; don't keep them on screen or in memory.
            pan = ""; account = ""; accountAgain = ""; ifsc = ""; upi = ""
            Haptics.success()
            withAnimation(.easeOut(duration: 0.2)) { status = v }
            if v.isVerified { onVerified() }
        } catch {
            Haptics.error()
            submitError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t verify right now. Try again."
        }
    }

    private func upload(_ item: PhotosPickerItem) async {
        uploading = true
        uploadError = nil
        defer { uploading = false; pickedDoc = nil }
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            uploadError = "Couldn\u{2019}t read that photo."
            return
        }
        do {
            try await KycService.shared.upload(image, kind: docKind)
            Haptics.success()
            await load()
        } catch {
            uploadError = (error as? APIError)?.errorDescription ?? "Upload failed. Try again."
        }
    }

    private func remove(_ id: String) async {
        do {
            try await KycService.shared.removeDocument(id: id)
            await load()
        } catch {
            uploadError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t remove that."
        }
    }
}
