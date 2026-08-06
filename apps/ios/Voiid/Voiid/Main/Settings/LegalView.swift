//
//  LegalView.swift
//  Voiid
//
//  Settings → Privacy & Legal. Three jobs, in this order:
//
//    1. Say, in four lines and before anything else, what Voiid can and cannot see. Most
//       people will never open the full notice; this screen is the version they read.
//    2. Give the notice and the terms somewhere to be opened from, at any time and not
//       only during sign-up.
//    3. Show what you agreed to, and let you withdraw it in one tap.
//
//  (3) is the load-bearing one. DPDP s.6(4) requires withdrawal to be as easy as giving,
//  and giving was a single tick on a single screen. A withdrawal that requires an email,
//  a support ticket or a hunt through three levels of settings does not meet that bar, so
//  the control lives on this screen, at the same depth as the documents themselves.
//
//  This screen deliberately does NOT delete the account when consent is withdrawn. Every
//  purpose in the current notice is one the service cannot run without, so withdrawal
//  genuinely does mean the account cannot continue — but destroying an account from a
//  "withdraw" tap, with no separate confirmation, would be a far worse surprise than the
//  extra step. The sheet says so plainly and points at the deletion screen.
//

import SwiftUI

@MainActor
struct LegalView: View {
    @ObservedObject private var consent = ConsentService.shared

    @State private var confirmWithdraw = false
    @State private var working = false
    @State private var errorText: String?
    @State private var withdrew = false

    var body: some View {
        List {
            summary
            documents
            consentStatus
            if liveConsent != nil { withdrawSection }
        }
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Privacy & Legal")
        .task { await consent.refreshStatus() }
        .confirmationDialog("Withdraw consent?",
                            isPresented: $confirmWithdraw,
                            titleVisibility: .visible) {
            Button("Withdraw Consent", role: .destructive) { Task { await performWithdraw() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                 Voiid needs your phone number to run your account and needs to know where to \
                 deliver messages, so it cannot keep working without this consent. Withdrawing \
                 records that you have withdrawn it — it does not delete your account. To have \
                 your data erased, use Delete My Account in Edit Profile.
                 """)
        }
        .alert("Couldn't update consent",
               isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    // MARK: - Sections

    /// The honest summary. Written to be read by someone who will not open the notice —
    /// which is most people — so it leads with the limit rather than the reassurance.
    private var summary: some View {
        SettingsSection("In short",
                        footer: "Clips are the exception: a Clip is a public post, stored unencrypted, and Voiid's moderators can see and remove it.") {
            claim(icon: "lock.fill",
                  tint: VoiidColor.success,
                  title: "Voiid cannot read what you send",
                  detail: "Messages, calls, live location and moments are encrypted on your device and decrypted on the other person's. The server holds the encrypted bytes and no key.")
            claim(icon: "eye.fill",
                  tint: VoiidColor.warning,
                  title: "Voiid can see who and when",
                  detail: "Your phone number, which account a message is addressed to and when it arrived, your device type and app version, and the IP address you connect from.")
            claim(icon: "nosign",
                  tint: VoiidColor.textSecondary,
                  title: "Voiid does not sell or profile you",
                  detail: "No advertising identifiers, no behavioural tracking, no background location.")
        }
    }

    private var documents: some View {
        SettingsSection("Documents",
                        footer: "Version \(LegalDocuments.noticeVersion). Stored in the app, so they open without a connection.") {
            ForEach(LegalDocuments.all) { doc in
                // A view-based NavigationLink rather than a `SettingsRoute` value: the
                // route enum exists so every pushed screen is constructible with no
                // arguments (see SettingsSheet), and a document screen needs its document.
                NavigationLink {
                    LegalDocumentView(document: doc)
                } label: {
                    Label(doc.title, systemImage: doc.id == "privacy" ? "hand.raised" : "doc.text")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                }
            }
        }
    }

    @ViewBuilder
    private var consentStatus: some View {
        SettingsSection("Your consent", footer: consentFooter) {
            if let live = liveConsent {
                LabeledContent {
                    Text(shortDate(live.given_at))
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                } label: {
                    Text("Agreed on")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                }
                LabeledContent {
                    Text(live.notice_version ?? "—")
                        .font(.subheadline)
                        .foregroundStyle(VoiidColor.textSecondary)
                } label: {
                    Text("Notice version")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                }
                ForEach(LegalDocuments.purposes) { purpose in
                    purposeRow(purpose, granted: live.purposes?[purpose.id] ?? false)
                }
            } else if withdrew {
                Text("Consent withdrawn.")
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
            } else {
                Text("No consent on record for this account.")
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
            }
        }
    }

    private var withdrawSection: some View {
        SettingsSection {
            Button(role: .destructive) {
                Haptics.rigid()
                confirmWithdraw = true
            } label: {
                Label("Withdraw Consent", systemImage: "hand.raised.slash")
                    .font(.body)
                    .foregroundStyle(VoiidColor.error)
            }
            .disabled(working)
        }
    }

    // MARK: - Parts

    private func claim(icon: String, tint: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body).foregroundStyle(VoiidColor.textPrimary)
                Text(detail).font(.footnote).foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func purposeRow(_ purpose: LegalDocuments.Purpose, granted: Bool) -> some View {
        LabeledContent {
            Image(systemName: granted ? "checkmark" : "xmark")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(granted ? VoiidColor.success : VoiidColor.textSecondary)
                .accessibilityLabel(granted ? "Agreed" : "Not agreed")
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(purpose.title).font(.body).foregroundStyle(VoiidColor.textPrimary)
                Text(purpose.detail).font(.footnote).foregroundStyle(VoiidColor.textSecondary)
            }
        }
    }

    // MARK: - State

    /// The live consent matching the version this build renders. A record against some
    /// other version is not shown as "your consent" here, because the words on this screen
    /// would not be the words that record refers to.
    private var liveConsent: ConsentRecordInfo? {
        consent.status?.consents?.first { $0.notice_version == LegalDocuments.noticeVersion }
            ?? consent.status?.consents?.first
    }

    private var consentFooter: String {
        if liveConsent != nil {
            return "You can withdraw this at any time, in one tap. Withdrawing does not delete your account — Delete My Account, in Edit Profile, does that."
        }
        return "Voiid asks for consent before it processes your phone number. If nothing is recorded here, you will be asked on next launch."
    }

    /// ISO-8601 from Postgres, rendered short. Falls back to the raw string rather than to
    /// an empty cell: an unparseable date is a bug worth seeing, not one worth hiding.
    private func shortDate(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = parser.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return iso }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    private func performWithdraw() async {
        working = true
        defer { working = false }
        do {
            _ = try await ConsentService.shared.withdraw()
            withdrew = true
            Haptics.success()
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
