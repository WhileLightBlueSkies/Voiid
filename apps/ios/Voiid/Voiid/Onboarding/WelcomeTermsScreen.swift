//
//  WelcomeTermsScreen.swift
//  Voiid
//
//  Terms & Conditions — the first thing a new user is asked to agree to.
//
//  Built to the design source (`Voiid Ui/Screens/TermsScreen.swift`) through `OnboardingKit`,
//  so the sizes, paddings and weights are the reference's own numbers rather than substitutions
//  from the app's other components. The header is the WORDMARK at 34pt — not the glowing V mark
//  on a horizon, which is a different composition (see OnboardingBrandChrome).
//
//  ── THIS SCREEN IS THE CONSENT MOMENT ────────────────────────────────────────────
//  DPDP s.5 wants notice "at or before" processing, so the affirmative action has to happen
//  HERE — before a phone number, before an OTP, before a JWT exists. There is no account to
//  attach consent to yet, which is exactly the sequencing problem ConsentService solves: the
//  tick is recorded LOCALLY the instant it happens and posted once an account exists.
//
//  So Continue calls `recordLocalConsent`. It does NOT post — there is nothing to post to.
//  `submitPendingConsent()` flushes it after sign-up. Getting this wrong in the obvious
//  direction (post it here) would mean either losing the record or processing the phone number
//  first and asking permission afterwards, the inversion DPDP forbids.
//
//  ── THE GATE IS REAL ─────────────────────────────────────────────────────────────
//  Continue is disabled until the box is ticked, and it LOOKS disabled. A button that appears
//  live and then refuses the tap teaches the user that the interface lies; one that is visibly
//  inert tells them what to do next. The checkbox is the only thing standing between them and
//  the app, so it is also the only thing on screen with an accent border.
//
//  The tick is not "which purposes do you accept" — every purpose is `Purpose.required`. It is
//  "I have READ these documents", a claim only the user can make, and exactly what DPDP s.6(1)
//  means by consent being informed.
//
//  ── SIX ROWS, TWO DOCUMENTS ──────────────────────────────────────────────────────
//  The design lists six documents; `LegalDocuments` has two written (privacy, terms). Rather
//  than show four rows that open nothing — worse than not listing them — each row maps to the
//  document that actually covers it. When the remaining four are written, point the rows at
//  them; nothing else changes.
//
//  Committed to dark, like the rest of onboarding: this precedes any theme choice the user
//  could have made.
//

import SwiftUI

@MainActor
struct WelcomeTermsScreen: View {

    /// The splash's logo namespace, so the mark flies in rather than cutting.
    var logoNS: Namespace.ID
    let onContinue: () -> Void
    /// Someone returning to a new device skips the funnel.
    ///
    /// CURRENTLY UNUSED — the control that called it was removed to match the design source
    /// (see `footer`). Kept on the type so `OnboardingFlow` compiles unchanged and so the path
    /// can be re-surfaced without re-plumbing the flow.
    var onExistingAccount: (() -> Void)? = nil

    /// Which legal document is open in a sheet, if any.
    @State private var reading: LegalDocument?
    @State private var accepted = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    // The namespace goes IN, so the effect lands on the wordmark alone rather
                    // than on this whole header — see OnboardingHeader.logoNS.
                    OnboardingHeader(
                        title: "Terms & ",
                        accent: "Conditions",
                        blurb: "Please read these important documents carefully.\nBy continuing, you agree to our policies.",
                        logoNS: logoNS
                    )
                    .padding(.top, VoiidSpacing.lg)

                    documentCard
                        .padding(.top, VoiidSpacing.lg)

                    privacyNote
                        .padding(.top, VoiidSpacing.md)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                // Clears the pinned footer. Measured against the footer's actual height —
                // consent row (~44) + button (56) + its padding (~56) + home indicator — rather
                // than guessed, because too little clips the privacy note under the fade and
                // too much leaves dead space below it.
                .padding(.bottom, 190)
            }
            .scrollIndicators(.hidden)

            // The footer is PINNED, not scrolled. The agreement control is the point of the
            // screen; making the user scroll to find it is how consent gets skipped.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                footer
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        // Matches how every other screen presents these (ConsentPromptView, AboutView):
        // wrapped in a NavigationStack so the document gets its own title bar and Done.
        .sheet(item: $reading) { doc in
            NavigationStack { LegalDocumentView(document: doc, showsDoneButton: true) }
        }
    }

    // MARK: Documents

    /// The document list. Shape comes from OnboardingKit so Terms and Permissions cannot drift.
    private var documentCard: some View {
        OnboardingKitCard {
            ForEach(Array(Self.rows.enumerated()), id: \.element.id) { index, doc in
                OnboardingRow(
                    icon: doc.icon,
                    title: doc.title,
                    subtitle: doc.subtitle
                ) {
                    Haptics.tap()
                    reading = doc.document
                }

                if index < Self.rows.count - 1 {
                    OnboardingRowDivider()
                }
            }
        }
    }

    // MARK: Privacy note

    /// The one reassurance on the screen, and the only lime-tinted surface — it is a promise,
    /// not a control, so it gets colour but no affordance.
    private var privacyNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Image(systemName: "checkmark.shield.fill")
                .font(.system(size: 20))
                .foregroundColor(VoiidBrand.lime)

            VStack(alignment: .leading, spacing: 2) {
                Text("Your privacy and security are our top priority.")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("We never sell your personal data.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.md)
        .background(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(VoiidBrand.lime.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidBrand.lime.opacity(0.28), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
    }

    // MARK: Footer

    /// Consent tick + Continue. Nothing else.
    ///
    /// "I already have an account" USED TO SIT HERE and is deliberately gone: the design source
    /// has no such control, and a returning user reaches the same place through the ordinary
    /// funnel — the phone number they enter is what identifies them, not a separate door. The
    /// `onExistingAccount` closure is kept on the type so `OnboardingFlow` still compiles and so
    /// the path can be re-surfaced elsewhere without re-plumbing it.
    private var footer: some View {
        OnboardingFooter {
            consentRow
            continueButton
        }
    }

    private var continueButton: some View {
        OnboardingKitButton(title: "Continue", enabled: accepted) {
            recordConsent()
            onContinue()
        }
        .accessibilityHint(accepted ? "" : "Agree to the terms to continue")
    }

    /// The consent control. The whole row is the hit target — a 26pt checkbox alone is well
    /// under the 44pt minimum and is the single most important control on the screen.
    private var consentRow: some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { accepted.toggle() }
        } label: {
            HStack(alignment: .top, spacing: VoiidSpacing.md) {
                checkbox

                (
                    Text("I have read and agree to the ")
                        .foregroundColor(VoiidColor.textPrimary)
                    + Text("Terms of Service").foregroundColor(VoiidBrand.lime)
                    + Text(" and ").foregroundColor(VoiidColor.textPrimary)
                    + Text("Privacy Policy").foregroundColor(VoiidBrand.lime)
                    + Text(".").foregroundColor(VoiidColor.textPrimary)
                )
                .font(VoiidFont.subhead)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(accepted ? [.isSelected] : [])
        .accessibilityLabel("I have read and agree to the Terms of Service and Privacy Policy")
    }

    private var checkbox: some View {
        RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous)
            .strokeBorder(
                accepted ? VoiidBrand.lime : VoiidColor.fieldBorder,
                lineWidth: 2
            )
            .background(
                RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous)
                    .fill(accepted ? VoiidBrand.lime : .clear)
            )
            .frame(width: 26, height: 26)
            .overlay {
                // Scales in from 0.6 rather than 0: a tick that appears from nothing pops, and
                // this one is confirming a deliberate choice, so it should feel like it landed.
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(VoiidBrand.onLime)
                    .scaleEffect(accepted ? 1 : (reduceMotion ? 1 : 0.6))
                    .opacity(accepted ? 1 : 0)
            }
    }

    // MARK: Consent

    /// Local only — see the header. The post happens once an account exists.
    private func recordConsent() {
        ConsentService.shared.recordLocalConsent(
            purposes: Dictionary(uniqueKeysWithValues: LegalDocuments.purposes.map { ($0.id, true) })
        )
    }

    // MARK: Rows

    fileprivate struct DocumentRow: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        /// The document this row opens. Several rows share one until the rest are written —
        /// see the header.
        let document: LegalDocument
    }

    /// ALPHABETICAL BY TITLE, ascending.
    ///
    /// Six items is past the point where a reader scans the whole list, so a predictable order
    /// means they can find one by name instead of hunting. The trade: Terms of Service and
    /// Privacy Policy sit last and fifth while the checkbox names exactly those two — which is
    /// why both are also links in the consent line itself.
    fileprivate static var rows: [DocumentRow] {
        [
            .init(id: "additional",
                  title: "Additional Information",
                  subtitle: "Disclaimers and other legal information.",
                  icon: "info.circle",
                  document: LegalDocuments.terms),
            .init(id: "community",
                  title: "Community Guidelines",
                  subtitle: "Standards for a safe and respectful community.",
                  icon: "person.2",
                  document: LegalDocuments.terms),
            // `lock.shield` — a padlock inside a shield. Plain `lock` renders a SOLID body at
            // this weight, so next to five outlined neighbours it reads heavier and muddier and
            // the keyhole vanishes into the fill. It shares a shield silhouette with Privacy
            // Policy, which is why that row uses `hand.raised` — see the note there.
            .init(id: "data",
                  title: "Data Protection",
                  subtitle: "Your data rights and security information.",
                  icon: "lock.shield",
                  document: LegalDocuments.privacy),
            .init(id: "payments",
                  title: "Payments Terms",
                  subtitle: "Important information about payments.",
                  icon: "creditcard",
                  document: LegalDocuments.terms),
            // `hand.raised`, NOT a shield. A raised hand is the conventional privacy glyph — it
            // is what iOS itself uses for App Privacy — so this is not a compromise pick: it
            // frees the shield for Data Protection and reads more specifically as "privacy"
            // than a second checkmarked shield would.
            .init(id: "privacy",
                  title: "Privacy Policy",
                  subtitle: "How we collect, use and protect your data.",
                  icon: "hand.raised",
                  document: LegalDocuments.privacy),
            .init(id: "tos",
                  title: "Terms of Service",
                  subtitle: "Rules for using Voiid and our services.",
                  icon: "doc.text",
                  document: LegalDocuments.terms),
        ]
    }
}
