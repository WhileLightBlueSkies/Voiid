//
//  WelcomeTermsScreen.swift
//  Voiid
//
//  Onboarding step 1 — the first screen a new user ever sees. Built to the brand reference.
//
//  ── THIS SCREEN IS THE CONSENT MOMENT, NOT JUST A SPLASH ─────────────────────────
//  DPDP s.5 wants notice "at or before" processing, so the affirmative action has to happen
//  HERE — before a phone number, before an OTP, before a JWT exists. There is no account to
//  attach consent to yet, which is exactly the sequencing problem ConsentService solves: the
//  tick is recorded LOCALLY the instant it happens and posted once an account exists.
//
//  So "I Agree & Continue" calls `recordLocalConsent`. It does NOT post — there is nothing to
//  post to. `submitPendingConsent()` flushes it after sign-up. Getting this wrong in the
//  obvious direction (post it here) would mean either losing the record or processing the
//  phone number first and asking permission afterwards, the inversion DPDP forbids.
//
//  ── WHY THE ROWS ARE NOT CHECKBOXES ──────────────────────────────────────────────
//  Every purpose in this version is REQUIRED (LegalDocuments.Purpose.required), so a checkbox
//  the user cannot uncheck is a lie about the choice available. The rows show the four things
//  being agreed to and each opens the real document; the single button is the consent. The
//  check marks are state — "this is included" — not controls.
//

import SwiftUI

struct WelcomeTermsScreen: View {

    /// The splash's logo namespace, so the mark flies in rather than cutting.
    var logoNS: Namespace.ID
    let onContinue: () -> Void
    /// Someone returning to a new device skips the funnel — they still consent, because the
    /// notice is shown either way, but they should not be walked through sign-up copy.
    var onExistingAccount: (() -> Void)? = nil

    /// Which legal document is open in a sheet, if any.
    @State private var reading: LegalDocument?
    @State private var appeared = false

    // The lime is a FILL on light and free on dark, but this screen is drawn on the brand's
    // near-black ground in BOTH themes — the glow and the horizon are the identity, and they
    // do not exist on white. See the note on `ground` below.
        var body: some View {
        ZStack {
            // COMMITTED TO DARK, deliberately, and the only screen in the app that is.
            // The mark's glow and the horizon arc are light bleeding onto black; on a white
            // ground there is nothing for them to bleed into and the whole composition
            // collapses. A first-run screen is also the one place a fixed look is safe —
            // the user has not chosen a theme yet.
            OnboardingBrand.ground.ignoresSafeArea()

            VStack(spacing: 0) {
                OnboardingBrandHeader(appeared: appeared)
                    .matchedGeometryEffect(id: "voiidLogo", in: logoNS)
                    .padding(.top, 52)

                titleBlock
                    .padding(.top, 4)

                consentCard
                    .padding(.horizontal, 20)
                    .padding(.top, 26)

                privacyNote
                    .padding(.horizontal, 24)
                    .padding(.top, 22)

                Spacer(minLength: 16)

                agreeButton
                    .padding(.horizontal, 20)

                if let onExistingAccount {
                    Button("I already have an account") {
                        Haptics.tap()
                        // Consent is still recorded: the notice was shown, and an existing
                        // user on a new device has the same DPDP footing as a new one.
                        recordConsent()
                        onExistingAccount()
                    }
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.top, 14)
                }

                Text(Self.buildString)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
                    .padding(.top, 10)
                    .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        // Matches how every other screen presents these (ConsentPromptView, AboutView):
        // wrapped in a NavigationStack so the document gets its own title bar and Done.
        .sheet(item: $reading) { doc in
            NavigationStack { LegalDocumentView(document: doc, showsDoneButton: true) }
        }
        .onAppear {
            // One settle on entry rather than per-element animation: the mark and its glow are
            // the subject, and staggering four rows behind them turns the first impression
            // into a queue.
            withAnimation(.easeOut(duration: 0.5)) { appeared = true }
        }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 6) {
            OnboardingTitle(leading: "Welcome to ", accented: "Voiid")
            Text("One app. Everything you need.")
                .font(VoiidFont.rounded(17, .regular))
                .foregroundColor(VoiidColor.textSecondary)
        }
    }

    // MARK: Consent card

    private var consentCard: some View {
        OnboardingCard {
          VStack(alignment: .leading, spacing: 0) {
            Text("Let's get you started.")
                .font(VoiidFont.rounded(20, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("Please review and accept the following to continue.")
                .font(VoiidFont.rounded(15, .regular))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.top, 6)

            VStack(spacing: 10) {
                ForEach(Self.rows) { row in
                    consentRow(row)
                }
            }
            .padding(.top, 18)
          }
        }
    }

    private func consentRow(_ row: ConsentRow) -> some View {
        Button {
            Haptics.tap()
            reading = row.document
        } label: {
            HStack(spacing: 14) {
                // Outlined glyph, not filled: a filled lime square at this size would out-shout
                // the button, and the accent's power here is entirely in its rarity.
                row.glyph

                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                    Text(row.subtitle)
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 8)

                // STATE, not a control — see the header note on why these are not checkboxes.
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24, weight: .medium))
                    .foregroundColor(VoiidColor.accent)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 13)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(OnboardingBrand.row)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(OnboardingBrand.hairline, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens \(row.title)")
    }

    // MARK: Privacy note

    private var privacyNote: some View {
        OnboardingPrivacyNote(
            system: "lock.fill",
            lines: ["Your privacy is our priority.",
                    "All communications are end-to-end encrypted."],
            accentPhrase: "end-to-end encrypted"
        )
    }

    // MARK: Agree

    private var agreeButton: some View {
        OnboardingPrimaryButton(title: "I Agree & Continue") {
            Haptics.success()
            recordConsent()
            onContinue()
        }
    }

    /// Local only — see the header. The post happens once an account exists.
    private func recordConsent() {
        ConsentService.shared.recordLocalConsent(
            purposes: Dictionary(uniqueKeysWithValues: LegalDocuments.purposes.map { ($0.id, true) })
        )
    }

    /// Version + build, read from the bundle rather than hardcoded: the old screen carried a
    /// literal "v1.0.0 (15)" that had to be remembered on every release.
    private static var buildString: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "v\(v) (\(b))"
    }

    // MARK: Rows

    fileprivate struct ConsentRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let glyph: AnyView
        let document: LegalDocument
    }

    /// The four things being agreed to. Order matches the reference and reads
    /// terms → privacy → data → age: what the deal is, then what happens to your data, then
    /// who you say you are.
    fileprivate static var rows: [ConsentRow] {
        [
            ConsentRow(
                id: "terms",
                title: "Terms of Service",
                subtitle: "Read our Terms of Service",
                glyph: AnyView(OnboardingGlyphTile(system: "checkmark.shield", size: 38)),
                document: LegalDocuments.terms
            ),
            ConsentRow(
                id: "privacy",
                title: "Privacy Policy",
                subtitle: "Read our Privacy Policy",
                glyph: AnyView(OnboardingGlyphTile(system: "lock", size: 38)),
                document: LegalDocuments.privacy
            ),
            ConsentRow(
                id: "data",
                title: "Data Protection",
                subtitle: "Read about how we protect your data",
                glyph: AnyView(OnboardingGlyphTile(system: "person.crop.shield", size: 38)),
                document: LegalDocuments.privacy
            ),
            ConsentRow(
                id: "age",
                title: "Age Confirmation",
                subtitle: "I confirm that I am 14 years or older",
                glyph: AnyView(AgeGlyph()),
                document: LegalDocuments.terms
            ),
        ]
    }
}

/// "14+" in a ring. No SF Symbol carries an age, and drawing it keeps the number honest — if
/// the threshold changes the label changes with it, rather than a symbol name quietly lying.
private struct AgeGlyph: View {
    var body: some View {
        Text("14+")
            .font(VoiidFont.rounded(12, .bold))
            .foregroundColor(VoiidColor.accent)
            .frame(width: 38, height: 38)
            .overlay(Circle().strokeBorder(VoiidColor.accent, lineWidth: 1.5))
    }
}
