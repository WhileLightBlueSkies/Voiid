//
//  ShareProfileView.swift
//  Voiid
//
//  Settings → Share Profile. Three ways to hand someone your link.
//
//  ── THIS SCREEN BECAME POSSIBLE, IT WAS NOT ALWAYS ──────────────────────────────
//  Its preview version said, correctly at the time: "There is no public profile URL to share
//  — Voiid has no web profile route, and no universal link is registered." Both halves are
//  now false. `ProfileLink` defines `https://voiid.app/u/<username>`, and the app claims
//  `/u/*` in its associated-domains entitlement and AASA. So the rows do the thing they say.
//
//  ── ALL THREE SHARE THE SAME LINK, ON PURPOSE ───────────────────────────────────
//  Copy, share sheet and QR are three transports for one value, not three features. A link
//  copied to the clipboard, sent through iMessage, or read off a screen by a camera must all
//  resolve to the same person by the same route, or the flow that follows would depend on how
//  it was delivered — and that is exactly how one path quietly ends up with weaker checks.
//
//  ── WHAT THE LINK STILL DOES NOT DO ─────────────────────────────────────────────
//  It does not open a chat. It carries a username, never the Contact PIN, so whoever follows
//  it lands on the PIN step and then on a REQUEST you have to accept — the two gates
//  `ContactPinService` describes. The footer says so, because someone sharing their profile
//  should know what they are and are not handing out.
//
//  ── NO USERNAME, NO LINK ────────────────────────────────────────────────────────
//  Every row needs a URL that resolves to somebody. Without a username the screen says so and
//  points at Edit Profile rather than offering three controls that would share nothing.
//

import SwiftUI

@MainActor
struct ShareProfileView: View {
    @EnvironmentObject private var session: AppSession

    /// Set briefly after Copy, so the row confirms it did something. A toast would be more
    /// apparatus than a two-word state change needs.
    @State private var copied = false

    private var username: String? {
        let u = session.profile.username?.lowercased()
        return (u?.isEmpty == false) ? u : nil
    }

    private var link: URL? { username.flatMap { ProfileLink.url(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.md) {
                if let username, let link {
                    linkCard(username: username, link: link)
                    actionsCard(link: link)
                } else {
                    noUsernameCard
                }
            }
            .padding(VoiidSpacing.md)
        }
        .softTopEdgeEffect()
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Share Profile")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: The link itself

    /// Shown in full rather than summarised. A user about to send this to somebody should be
    /// able to read exactly what they are sending.
    private func linkCard(username: String, link: URL) -> some View {
        VoiidCardSection(
            "Your link",
            footer: "Anyone who opens this can ask to message you. They still need your "
                  + "Contact PIN, and you still choose whether to accept."
        ) {
            VStack(alignment: .leading, spacing: 4) {
                Text("@\(username)")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Text(link.absoluteString)
                    .font(VoiidFont.rounded(13))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.md)
        }
    }

    // MARK: The three actions

    private func actionsCard(link: URL) -> some View {
        VoiidCardSection {
            Button {
                UIPasteboard.general.url = link
                Haptics.success()
                withAnimation { copied = true }
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    withAnimation { copied = false }
                }
            } label: {
                row(icon: copied ? "checkmark" : "link",
                    title: copied ? "Copied" : "Copy link")
            }
            .buttonStyle(RowButtonStyle())

            VoiidRowDivider()

            // The system sheet, so every destination the user already has — Messages, Mail,
            // AirDrop, a notes app — works without Voiid knowing any of them exist.
            ShareLink(item: link) {
                row(icon: "square.and.arrow.up", title: "Share via…")
            }
            .buttonStyle(RowButtonStyle())

            VoiidRowDivider()

            // Pushes rather than duplicating: the QR screen owns the code, the PIN and the
            // explanation of why the two are separate. Drawing a second code here would mean
            // two places to keep in step.
            NavigationLink(value: SettingsRoute.qrCode) {
                row(icon: "qrcode", title: "Show QR code", showsChevron: true)
            }
            .buttonStyle(RowButtonStyle())
        }
    }

    private func row(icon: String, title: String, showsChevron: Bool = false) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VoiidRowIcon(systemName: icon)
            Text(title)
                .font(.body)
                .foregroundStyle(VoiidColor.textPrimary)
            Spacer(minLength: 0)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(VoiidColor.textSecondary.opacity(0.7))
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var noUsernameCard: some View {
        VoiidCardSection(
            footer: "A profile link needs a username to point at. Set one in Edit Profile "
                  + "and it will appear here."
        ) {
            Text("You haven’t set a username yet.")
                .font(.body)
                .foregroundStyle(VoiidColor.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, VoiidSpacing.md)
        }
    }
}
