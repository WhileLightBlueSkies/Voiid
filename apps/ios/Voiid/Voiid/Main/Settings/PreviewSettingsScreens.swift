//
//  PreviewSettingsScreens.swift
//  Voiid
//
//  The settings destinations that exist as a DESIGN and not yet as a feature.
//
//  ── WHY THEY EXIST AT ALL ───────────────────────────────────────────────────────
//  These nine rows are in the reference's profile sheet and have no backend in Voiid. Two
//  options were available: leave the rows out until the backend lands, or ship the rows with
//  screens that say what they are. The rows are in, because the sheet's shape is part of what
//  is being reviewed — a settings screen missing a third of its rows cannot be judged.
//
//  ── EVERY ONE OF THEM ADMITS IT, ON SCREEN ──────────────────────────────────────
//  Each screen opens with an `UnwiredNotice` naming exactly what is missing. The row that
//  leads here carries an amber dot, so the state is legible BEFORE the tap. Controls below the
//  notice are rendered but inert: they show the intended shape without pretending to work.
//
//  ── WIRING ONE UP ───────────────────────────────────────────────────────────────
//  Delete its `UnwiredNotice`, flip the case in `SettingsRoute.isWired`, and replace the inert
//  controls. Nothing else in the sheet changes.
//

import SwiftUI

// MARK: - Shared scaffold

/// The frame every preview screen shares: the notice first, then the intended content.
private struct PreviewScaffold<Content: View>: View {
    let title: String
    let missing: String
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                UnwiredNotice(missing)
                content
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// A card of inert rows, drawn so the screen has its intended shape.
private struct PreviewCard: View {
    let rows: [(String, String)]

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                HStack(spacing: VoiidSpacing.md) {
                    Circle()
                        .stroke(VoiidColor.accent.opacity(0.5), lineWidth: 1)
                        .frame(width: 34, height: 34)
                        .overlay {
                            Image(systemName: row.1)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundColor(VoiidColor.accentInk)
                        }

                    Text(row.0)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.7))
                }
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 13)

                if index < rows.count - 1 {
                    Rectangle().fill(VoiidColor.divider)
                        .frame(height: 1).padding(.leading, 60)
                }
            }
        }
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
        // Inert, and said so to VoiceOver rather than only in colour.
        .allowsHitTesting(false)
        .opacity(0.55)
        .accessibilityHint("Preview only, not yet interactive")
    }
}

// MARK: - My QR code

/// The one screen here that could be built today — `session.profile.username` is enough to
/// encode. It is left as a preview because a QR code that scans to a link nothing handles is
/// worse than one that admits it is coming.
// MARK: - Account center

struct AccountCenterScreen: View {
    var body: some View {
        PreviewScaffold(title: "Account Center",
                        missing: "Voiid has one account per device and nothing to centre yet. "
                               + "The rows below are the shape this screen would take — see "
                               + "the note in source for what each one needs first.") {
            PreviewCard(rows: [
                ("Profiles", "person.2"),
                ("Password & security", "key"),
                ("Ad preferences", "megaphone"),
                ("Connected experiences", "app.connected.to.app.below.fill"),
            ])
        }
    }
}

// ── ACCOUNT CENTER: WHAT IT WOULD TAKE ──────────────────────────────────────────────
//
// Kept deliberately, unlike Voiid One and Payments which lost their rows entirely. Those
// two describe features that do not exist and have no path to existing; this one describes
// a REAL future shape — it is the roof over surfaces Voiid already half-owns — so the row
// stays and this note records the thinking rather than making it twice.
//
// Meta's Accounts Center, which the reference is quoting, exists to span MULTIPLE apps and
// MULTIPLE profiles under one login. Voiid has one account, on one device, in one app. Ported
// literally it would be a screen whose entire purpose is a relationship the product does not
// have — four rows deep and every one of them a lie.
//
// So the question is not "when do we build these four rows", it is "what does a single-app
// account centre legitimately hold". Three candidates, and what each needs first:
//
//   * PROFILES — the honest version of the reference's row. Voiid genuinely HAS two
//     identities today: the account (phone, username, photo — Edit Profile) and the creator
//     profile (handle, bio, clips — CreatorProfileView). They are separate on purpose and a
//     user has no single place that says so. This is the strongest candidate and needs
//     nothing new server-side: `CreatorEngine.me` already resolves the second one. It does
//     need `CreatorEngine` lifted from a per-view @StateObject in ClipsFeedView to something
//     Settings can reach, which is the one real blocker.
//
//   * SECURITY — "Password & security" cannot port: Voiid has no password. What it DOES have
//     is scattered — linked devices (Devices), the safety number (per-conversation), the
//     backup PIN (Backup & Recovery), the Contact PIN (Privacy & security). A screen that
//     shows those four states in one place, without duplicating their controls, is a genuine
//     improvement. Needs no backend; needs a decision about whether summarising security
//     state in one screen makes it easier to audit or easier to attack.
//
//   * DATA & PERMISSIONS — the DPDP surface. Consent state, data export, deletion. Two of
//     those already exist (Privacy & Legal withdraws consent; Edit Profile deletes the
//     account) and export does not. If export is ever built, this is where it belongs.
//
// NOT candidates, and why: "Ad preferences" — Voiid has no advertising and building the row
// would be an announcement that it will. "Connected experiences" — no cross-app surface
// exists to connect.
//
// WHEN TO BUILD IT: when a second one of those three has real content. One populated section
// under a heading called "Account Center" is a screen pretending to be a hub; two is a hub.
// Profiles alone would be better placed as a row on the settings root than as a lone
// inhabitant of a centre.

// MARK: - Encryption status

/// Reached from the banner at the top of the sheet. The CLAIM the banner makes is true — MLS
/// for groups, Double Ratchet for direct messages — but there is no endpoint that reports
/// per-conversation key state, so the detail this screen would show does not exist yet.
struct EncryptionStatusScreen: View {
    var body: some View {
        PreviewScaffold(title: "Encryption",
                        missing: "No endpoint reports per-conversation key state, so the "
                               + "per-chat detail below cannot be filled in yet. The "
                               + "protocols named are real and already in use.") {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                // TRUE TODAY, and worth stating even on a preview screen: these are the
                // protocols the app actually runs, not an aspiration.
                infoBlock("Messages", "End-to-end encrypted with MLS for group conversations "
                                    + "and the Double Ratchet for direct messages.")
                infoBlock("Calls", "End-to-end encrypted media, keyed per call.")
                infoBlock("Backups", "Encrypted with a key derived from your recovery phrase. "
                                   + "Voiid cannot read them.")

                PreviewCard(rows: [
                    ("Verify safety numbers", "checkmark.shield"),
                    ("Encryption details per chat", "list.bullet.rectangle"),
                ])
            }
        }
    }

    private func infoBlock(_ title: String, _ body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text(body)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }
}

// MARK: - Account

/// The reference's "Phone, email, username" screen. Every one of those fields is already
/// editable in Voiid — on Edit Profile — so this row is a second door to settings that have a
/// home. It stays for layout parity and points at the screen that works.
struct AccountScreen: View {
    var body: some View {
        PreviewScaffold(title: "Account",
                        missing: "Your name, username and photo are edited on Edit Profile, "
                               + "which is wired. Changing your phone number and adding an "
                               + "email have no endpoint yet.") {
            PreviewCard(rows: [
                ("Change phone number", "phone"),
                ("Add email address", "envelope"),
                ("Request account info", "square.and.arrow.down"),
            ])
        }
    }
}

// MARK: - Chats

/// Reference name for chat appearance settings. Voiid's two chat-appearance controls — chat
/// list layout and app theme — are on the settings root under Display, where they are inline
/// and take effect instantly. What is missing is everything else this screen implies.
// MARK: - Voiid One

struct VoiidOneScreen: View {
    var body: some View {
        PreviewScaffold(title: "Voiid One",
                        missing: "Voiid One is not a product yet. Encrypted backup and restore "
                               + "already exist and are wired — see Backup & Recovery on the "
                               + "settings root.") {
            PreviewCard(rows: [
                ("Subscription", "star"),
                ("Extra storage", "externaldrive"),
                ("Priority support", "bolt"),
            ])
        }
    }
}

// MARK: - Payments

struct PaymentsScreen: View {
    var body: some View {
        PreviewScaffold(title: "Payments",
                        missing: "No payment provider is wired up. The events API answers 501 "
                               + "for paid tickets for the same reason — money needs a "
                               + "processor, webhooks, refunds and tax records.") {
            PreviewCard(rows: [
                ("Payment methods", "creditcard"),
                ("Transaction history", "list.bullet.rectangle.portrait"),
                ("UPI", "indianrupeesign.circle"),
            ])
        }
    }
}

