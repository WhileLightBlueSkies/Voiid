//
//  AboutView.swift
//  Voiid
//
//  Terminal, informational, non-mutating — which is why it sits below everything
//  actionable in the root list.
//
//  Its one job is to answer "what am I running, where is it pointing, and who does this
//  device think I am?" precisely enough that a support conversation can start from an
//  answer instead of a guess.
//
//  Every value on this screen is read live. Nothing here is a literal:
//  `Onboarding/OnboardingFlow.swift:132` hardcodes "v1.0.0 (15)" in its footer, which was
//  wrong the moment the build number moved. That mistake is not repeated here — the
//  version row reads `CFBundleShortVersionString` and `CFBundleVersion` from
//  `Bundle.main` on every appearance.
//
//  There is no "Send Logs", no "Report a Problem" and no crash-report toggle, because the
//  app collects none of those: there is not one `os.Logger`, `OSLog` or log sink in the
//  codebase, and no support address to send anything to. A row offering to send logs that
//  do not exist would be the exact failure this rebuild removes. What the app *can*
//  honestly hand to support is the five values below, and Share Diagnostics hands over
//  those five and nothing else.
//

import SwiftUI

// MARK: - Legal destinations
//
// Voiid has no privacy policy URL, no terms URL and no support/help URL — not in
// Info.plist, not in the server's /config payload, not in docs/, not anywhere in the
// repo. Rather than ship a row that opens nothing, a row that opens a plausible-looking
// URL somebody invented, or a greyed "coming soon" label, the destinations are declared
// here as nils and the Legal section is rendered behind `if let`. Nothing renders, so
// nothing lies.
//
// ACTION REQUIRED FROM PRODUCT: supply the real Privacy Policy, Terms of Service and Help
// URLs. Filling in these three constants is the entire iOS change — the section, its rows,
// its glyphs and its footer are already written below and appear on their own.
//
// Whoever supplies them must, in the SAME change, fix `Onboarding/OnboardingFlow.swift`
// (~line 106), where "Terms & Conditions" and "Privacy Policy" are non-tappable `Text`
// inside the consent checkbox: users currently agree to documents they cannot open. That
// is a separate ticket and is deliberately not attempted from here.

private let privacyPolicyURL: URL? = nil
private let termsOfServiceURL: URL? = nil
private let helpURL: URL? = nil

// MARK: -

@MainActor
struct AboutView: View {
    /// `apiVersion` is negotiated with the server at launch and can change under us, so it
    /// is observed rather than snapshotted.
    @ObservedObject private var config = ConfigService.shared

    /// Read once per view construction rather than per `body` evaluation: `deviceId` falls
    /// back to a Keychain lookup, and it also guarantees the row and the diagnostics text
    /// can never disagree about what this device is called.
    private let userID: String = TokenStore.shared.userId ?? "—"
    private let deviceID: String = E2EManager.shared.deviceId ?? "—"

    var body: some View {
        List {
            SettingsSection("App") {
                LabeledContent {
                    value(appVersion)
                } label: {
                    title("Version")
                }
            }

            SettingsSection("Connection") {
                LabeledContent {
                    value(APIConfig.baseURL.host ?? "—")
                } label: {
                    title("Server")
                }
                LabeledContent {
                    value(config.apiVersion)
                } label: {
                    title("API version")
                }
            }

            SettingsSection("Identifiers",
                            footer: "Support may ask for these if something goes wrong. They identify your account and this device — nothing else.") {
                LabeledContent {
                    identifier(userID)
                } label: {
                    title("User ID")
                }
                LabeledContent {
                    identifier(deviceID)
                } label: {
                    title("Device ID")
                }
            }

            SettingsSection(footer: "Includes only the values shown above. No messages, contacts or keys.") {
                // Native ShareLink, deliberately in preference to the UIActivityViewController
                // bridge (`ShareSheet`) that NewChatView still uses: it gets the system
                // presentation, the correct accessibility traits and the item preview for free.
                ShareLink(item: diagnosticsText, subject: Text("Voiid diagnostics")) {
                    Label("Share Diagnostics", systemImage: "square.and.arrow.up")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                }
                .accessibilityHint("Shares the version, server and identifier values shown above")
            }

            legal
        }
        .voiidSettingsList()
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("About")
        // No .preferredColorScheme here: this screen is pushed inside SettingsSheet's own
        // NavigationStack and inherits the sheet's pinned light scheme. Re-declaring it on
        // a pushed screen is the mistake, not the safeguard.
    }

    // MARK: - Legal

    /// Renders only when at least one destination exists. In this build that is never, so
    /// the section does not exist at runtime.
    @ViewBuilder
    private var legal: some View {
        if privacyPolicyURL != nil || termsOfServiceURL != nil || helpURL != nil {
            SettingsSection("Legal", footer: "Opens in Safari.") {
                if let privacyPolicyURL { externalLink("Privacy Policy", to: privacyPolicyURL) }
                if let termsOfServiceURL { externalLink("Terms of Service", to: termsOfServiceURL) }
                if let helpURL { externalLink("Help", to: helpURL) }
            }
        }
    }

    /// The trailing glyph is `arrow.up.forward.app`, not a chevron: leaving the app is a
    /// different promise from pushing a screen, and that distinction is the contract rather
    /// than decoration. It is hidden from VoiceOver because the hint already says it.
    private func externalLink(_ title: String, to url: URL) -> some View {
        Link(destination: url) {
            LabeledContent {
                Image(systemName: "arrow.up.forward.app")
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.placeholder)
                    .accessibilityHidden(true)
            } label: {
                Text(title)
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
            }
        }
        .accessibilityHint("Opens in Safari")
    }

    // MARK: - Row parts
    //
    // Semantic styles only, so the whole screen scales with Dynamic Type; `.fontDesign(.rounded)`
    // comes from `voiidSettingsList()` via the environment. `LabeledContent` restacks the
    // value under the title on its own at accessibility sizes, which is why no row here has
    // a fixed height.

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.body)
            .foregroundStyle(VoiidColor.textPrimary)
    }

    private func value(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(VoiidColor.textSecondary)
    }

    /// Long opaque ids: truncated in the middle so both ends stay readable — the ends are
    /// what someone reads aloud to support — and selectable so they can be copied without
    /// sharing the whole diagnostics blob.
    private func identifier(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(VoiidColor.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }

    // MARK: - Data

    /// `CFBundleShortVersionString (CFBundleVersion)` — marketing version and build, read
    /// from the bundle. Never a literal.
    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }

    /// Exactly the five values rendered above — nothing collected behind the user's back.
    /// The footer over the button says so, and it has to stay true: if you add a line here,
    /// add the row too, or change the footer.
    private var diagnosticsText: String {
        """
        Voiid diagnostics
        Version: \(appVersion)
        Server: \(APIConfig.baseURL.host ?? "—")
        API version: \(config.apiVersion)
        User ID: \(userID)
        Device ID: \(deviceID)
        """
    }
}
