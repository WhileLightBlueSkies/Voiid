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
            VStack(alignment: .leading, spacing: 24) {
                VoiidSettingsHeader("Help & support",
                                    subtitle: "Find answers and get to know Voiid.")

                VoiidCardSection("Get started") {
                    VoiidSettingsRow(icon: "sparkles", title: "Replay app walkthrough",
                                     detail: "A quick tour of Voiid", action: {
                        NotificationCenter.default.post(name: .voiidReplayAppWalkthrough, object: nil)
                    }) {
                        VoiidChevron()
                    }
                    .accessibilityHint("Closes Help and starts the app walkthrough")
                }

                VoiidCardSection("Common questions") {
                    question("Are my conversations private?", icon: "lock.shield") {
                        answer("Messages, calls, media and shared locations are end-to-end encrypted. Voiid’s servers relay ciphertext and cannot read your messages or hear your calls.")
                    }
                    VoiidRowDivider()
                    question("What if I lose my phone?", icon: "arrow.clockwise.icloud") {
                        answer("Restore your chats from an encrypted backup using your PIN or 24-word recovery phrase. Keep your recovery phrase safe: Voiid can’t recover your backup without one of them.")
                        answer("Set up your backup before you need it. You can’t create one after your device is gone.")
                        NavigationLink("Open Backup & Recovery") {
                            BackupRecoveryView()
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                    }
                    VoiidRowDivider()
                    question("What can linked devices see?", icon: "laptopcomputer.and.iphone") {
                        answer("A linked device gets its own keys and can read messages from the moment it is linked. It can’t read earlier messages. You can unlink it at any time in Settings → Devices.")
                        NavigationLink("Manage devices") {
                            LinkedDevicesView()
                        }
                        .font(.subheadline.weight(.medium))
                        .padding(.top, 4)
                    }
                }

                if let supportAddress, let url = URL(string: "mailto:\(supportAddress)") {
                    VoiidCardSection("Get in touch") {
                        Link(destination: url) {
                            VoiidSettingsRow(icon: "envelope", title: "Contact support") {
                                Image(systemName: "arrow.up.right")
                                    .foregroundStyle(VoiidColor.textSecondary)
                            }
                        }
                        .buttonStyle(RowButtonStyle())
                    }
                }

                VoiidCardSection("Troubleshooting",
                                 footer: "Shares your app version, API version and iOS version. No message content.") {
                    ShareLink(item: diagnosticsText, subject: Text("Voiid diagnostics")) {
                        VoiidSettingsRow(icon: "doc.text", title: "Share diagnostics",
                                         detail: "App and device information") {
                            Image(systemName: "square.and.arrow.up")
                                .font(.subheadline)
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                    }
                    .buttonStyle(RowButtonStyle())
                    .accessibilityHint("Opens sharing options for app and operating system versions")
                }
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .font(.body)
        .fontDesign(.rounded)
        .foregroundStyle(VoiidColor.textPrimary)
        .tint(VoiidColor.primary)
        .voiidSettingsPage()
    }

    private func question<Content: View>(_ title: String, icon: String,
                                         @ViewBuilder content: @escaping () -> Content) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 12) {
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, VoiidSpacing.sm)
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                VoiidRowIcon(systemName: icon)
                Text(title)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 7)
    }

    private func answer(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(VoiidColor.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
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
