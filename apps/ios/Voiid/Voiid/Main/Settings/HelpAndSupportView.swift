//
//  HelpAndSupportView.swift
//  Voiid
//
//  Settings → Help & support.
//
//  ── WHY THIS IS NOT A LIST OF LINKS ─────────────────────────────────────────────
//  The preview version of this screen listed FAQ, Contact us, Report a problem and
//  Terms & privacy policy as four inert rows, above a notice admitting none of them
//  worked. Three of the four had nowhere to go: there is still no support site, no FAQ
//  and no support address anywhere in this repo (`AboutView.helpURL` is nil for exactly
//  that reason, and says so).
//
//  A help screen that cannot be reached for help is worse than no help screen, so this
//  one is built from what the app CAN actually do today:
//
//    * Answer the questions the app itself can answer, in plain text. Every line here is
//      a claim this build genuinely implements — encryption, what the server can see,
//      how backup recovery works, what a linked device gets.
//    * Hand the user their diagnostics, which is the one thing that makes a support
//      conversation useful whenever a channel does exist. Same payload AboutView shares.
//    * Point at the two real destinations that DO exist in the app: the bundled legal
//      documents, and Backup & Recovery.
//
//  ── WHEN A SUPPORT CHANNEL EXISTS ───────────────────────────────────────────────
//  Set `supportAddress` (or a URL) and add the row. Nothing else here changes. Until
//  then this screen does not pretend: no "Contact us" that opens nothing, no "FAQ" that
//  is a dead row. Same rule the settings root states at the top — absent features get no
//  pixels.
//

import SwiftUI

/// The support channel, when product provides one. Nil until then, and the contact row
/// is behind `if let` so it appears on its own the moment this is set.
private let supportAddress: String? = nil

@MainActor
struct HelpAndSupportView: View {
    @ObservedObject private var config = ConfigService.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {

                VoiidCardSection(
                    "Learn Voiid",
                    footer: "A short guide to the features available in this version."
                ) {
                    Button {
                        NotificationCenter.default.post(name: .voiidReplayAppWalkthrough, object: nil)
                    } label: {
                        HStack(spacing: VoiidSpacing.md) {
                            VoiidRowIcon(systemName: "sparkles")
                            Text("Replay app walkthrough")
                                .font(.body)
                                .foregroundStyle(VoiidColor.textPrimary)
                            Spacer(minLength: 0)
                            VoiidChevron()
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityHint("Closes Help and starts the app walkthrough")
                }

                VoiidCardSection(
                    "Your messages",
                    footer: "Voiid's servers relay ciphertext. They cannot read a message, "
                          + "hear a call, or see a location you share."
                ) {
                    answer("Messages, calls, media and shared locations are end-to-end "
                         + "encrypted. Keys are generated on your device and never leave it.")
                }

                VoiidCardSection(
                    "If you lose your phone",
                    footer: "Set this up before you need it — a backup cannot be created "
                          + "after the device is gone."
                ) {
                    answer("Your chats can be restored on a new device from an encrypted "
                         + "backup, using either your PIN or your 24-word recovery phrase.\n\n"
                         + "The recovery phrase is the stronger of the two and the one to "
                         + "keep safe: nobody — including Voiid — can recover your backup "
                         + "without one of them.")
                }

                VoiidCardSection(
                    "Linked devices",
                    footer: "Unlink a device from Settings → Devices at any time."
                ) {
                    answer("A linked device gets its own keys and can read messages from "
                         + "the moment it is linked. It cannot read anything sent before.")
                }

                if let supportAddress, let url = URL(string: "mailto:\(supportAddress)") {
                    VoiidCardSection("Still stuck?") {
                        Link(destination: url) {
                            HStack(spacing: VoiidSpacing.md) {
                                VoiidRowIcon(systemName: "envelope")
                                Text("Contact support")
                                    .font(.body)
                                    .foregroundStyle(VoiidColor.textPrimary)
                                Spacer(minLength: 0)
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(VoiidColor.textSecondary)
                            }
                            .padding(.horizontal, VoiidSpacing.md)
                            .padding(.vertical, 11)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }

                // The one genuinely useful thing to hand a support channel, and it works
                // whether or not one exists yet: version, server and identifiers, already
                // assembled by AboutView.
                VoiidCardSection(
                    "Diagnostics",
                    footer: "Includes your app version, server and device identifiers. "
                          + "No message content."
                ) {
                    ShareLink(item: diagnosticsText, subject: Text("Voiid diagnostics")) {
                        HStack(spacing: VoiidSpacing.md) {
                            VoiidRowIcon(systemName: "square.and.arrow.up")
                            Text("Share diagnostics")
                                .font(.body)
                                .foregroundStyle(VoiidColor.textPrimary)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 11)
                        .contentShape(Rectangle())
                    }
                    .accessibilityHint("Shares your app version and device identifiers")
                }
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Help & support")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func answer(_ text: String) -> some View {
        Text(text)
            .font(VoiidFont.subhead)
            .foregroundStyle(VoiidColor.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
    }

    /// Mirrors `AboutView.diagnosticsText` — same fields, so a user can send this from
    /// either screen and support sees one shape.
    private var diagnosticsText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return """
        Voiid diagnostics
        Version: \(v) (\(b))
        API version: \(config.apiVersion)
        Device: \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)
        """
    }
}
