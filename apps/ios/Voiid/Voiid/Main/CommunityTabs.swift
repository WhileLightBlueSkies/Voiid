//
//  CommunityTabs.swift
//  Voiid
//
//  The four tabs inside a community: Spaces, Events, Members, About.
//  Ported from the reference's CommunityTabs.swift, wired to the live API.
//
//  ── WHAT EACH TAB READS ─────────────────────────────────────────────────────────
//  Spaces   GET /communities/:id/channels   (added alongside this file — channels could be
//                                            created and never listed)
//  Events   the existing CommunityEventsSection / CommunityTournamentsSection
//  Members  GET /communities/:id/members
//  About    the card already in hand — no request
//
//  ── MEMBERS ARE NOT TAPPABLE ────────────────────────────────────────────────────
//  The roster renders, and nothing in it navigates. Being in a community grants a private
//  line to the OWNER and to nobody else (030_communities.sql enforces this by ABSENCE —
//  community_host_threads has nowhere to put a second member), so a member you could tap
//  into would imply a reachability this product does not give you.
//
//  The server returns ids and states, not display names: resolving a name is the directory's
//  job. Rows therefore show a role and a join date, which is what the roster actually knows.
//

import SwiftUI

enum CommunityTab: String, CaseIterable, Identifiable {
    case spaces = "Spaces"
    case events = "Events"
    case members = "Members"
    case about = "About"

    var id: String { rawValue }
}

// MARK: - Spaces

struct CommunitySpacesTab: View {
    let communityId: String
    let isAdmin: Bool

    @State private var channels: [CommunityService.Channel] = []
    @State private var loading = true
    @State private var error: String?

    /// Announcements first, then the server's order. An announcement channel is the one a
    /// member most needs to find, and it is the one they post in least.
    private var sorted: [CommunityService.Channel] {
        channels.sorted { a, b in
            a.isAnnouncement == b.isAnnouncement
                ? (a.position ?? 0) < (b.position ?? 0)
                : a.isAnnouncement
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            if loading && channels.isEmpty {
                ProgressView().tint(VoiidColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.lg)
            } else if let error, channels.isEmpty {
                emptyish(icon: "exclamationmark.triangle", title: error,
                         detail: "Pull down to try again.")
            } else if channels.isEmpty {
                emptyish(icon: "bubble.left.and.bubble.right",
                         title: "No Spaces yet",
                         detail: isAdmin ? "Create one to give people somewhere to talk."
                                         : "The host hasn’t made any yet.")
            } else {
                ForEach(sorted) { channel in
                    SpaceRow(channel: channel)
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            channels = try await CommunityService.shared.channels(communityId: communityId)
            error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t load Spaces."
        }
    }
}

private struct SpaceRow: View {
    let channel: CommunityService.Channel

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            Image(systemName: channel.isAnnouncement ? "megaphone.fill" : "number")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(channel.isAnnouncement ? VoiidColor.textOnAccent
                                                        : VoiidColor.accentInk)
                .frame(width: 32, height: 32)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(channel.isAnnouncement ? VoiidColor.accent : VoiidColor.accentTint))

            VStack(alignment: .leading, spacing: 1) {
                Text(channel.name ?? "Space")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(channel.isAnnouncement ? "The host posts, everyone reads"
                                            : "Everyone can post")
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)

            // END-TO-END ENCRYPTED, and worth saying on the row: the container is
            // server-readable and the channel contents are not. Users deserve to know which
            // half of a feature is encrypted, on the screen where they choose to post in it.
            Image(systemName: "lock.fill")
                .font(.system(size: 10))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.sm + 4)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }
}

// MARK: - Members

struct CommunityMembersTab: View {
    let communityId: String
    let isAdmin: Bool

    @State private var members: [CommunityService.Member] = []
    @State private var pending: [CommunityService.Member] = []
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            if loading && members.isEmpty {
                ProgressView().tint(VoiidColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.lg)
            } else if let error, members.isEmpty {
                emptyish(icon: "exclamationmark.triangle", title: error,
                         detail: "Pull down to try again.")
            } else {
                // Requests first, and only for a manager: they are the rows that need acting
                // on, and a plain member is not entitled to see who asked.
                if isAdmin && !pending.isEmpty {
                    sectionLabel("Requests", count: pending.count)
                    ForEach(pending) { m in MemberRow(member: m, pendingRequest: true) }
                }

                sectionLabel("Members", count: members.count)
                ForEach(members) { m in MemberRow(member: m, pendingRequest: false) }
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            members = try await CommunityService.shared.members(communityId: communityId)
            error = nil
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t load members."
        }
        // Managers only — the server refuses the pending list to anyone else, and a failure
        // here must not blank the roster that already loaded.
        if isAdmin {
            pending = (try? await CommunityService.shared.members(
                communityId: communityId, state: "pending")) ?? []
        }
    }

    private func sectionLabel(_ text: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(text)
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            Text("\(count)")
                .font(VoiidFont.rounded(11, .bold))
                .foregroundColor(VoiidColor.accentInk)
        }
        .padding(.top, VoiidSpacing.xs)
    }
}

private struct MemberRow: View {
    let member: CommunityService.Member
    let pendingRequest: Bool

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            // Initials from the id, because the roster endpoint returns ids and not names —
            // a placeholder that admits what it is beats a blank circle pretending to load.
            Circle()
                .fill(VoiidColor.accentTint)
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 14))
                        .foregroundColor(VoiidColor.accentInk)
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(member.isOwner ? "Host" : (member.isAdmin ? "Moderator" : "Member"))
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(joinedText)
                    .font(VoiidFont.rounded(12))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            Spacer(minLength: 0)

            if pendingRequest {
                Text("Waiting")
                    .font(VoiidFont.rounded(10, .bold))
                    .foregroundColor(VoiidColor.accentInk)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(VoiidColor.accentTint))
            } else if member.isOwner {
                Text("HOST")
                    .font(VoiidFont.rounded(9.5, .bold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(VoiidColor.accent))
            }
        }
        .padding(VoiidSpacing.sm + 4)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private var joinedText: String {
        guard let raw = member.joined_at,
              let date = ISO8601DateFormatter().date(from: raw) else { return "Joined" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return "Joined \(f.string(from: date))"
    }
}

// MARK: - About

struct CommunityAboutTab: View {
    let card: CommunityService.CommunityCard

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            if let d = card.description, !d.isEmpty {
                block("What it's for", body: d)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Details")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)

                detailRow("Handle", "@\(card.handle)")
                detailRow("Joining", policyText)
                detailRow("In search", (card.discoverable ?? false) ? "Yes" : "No")
                detailRow("Members", "\(card.members)")
                if card.isSuspended { detailRow("Status", "Suspended") }
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))

            encryptionNote
        }
    }

    private var policyText: String {
        switch card.policy {
        case "open":     return "Anyone can join"
        case "approval": return "Approval needed"
        default:         return "Invite only"
        }
    }

    private func block(_ title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(VoiidFont.rounded(12.5, .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            Text(body)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func detailRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
            Spacer(minLength: VoiidSpacing.md)
            Text(value)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
        }
    }

    /// Which half of the feature is encrypted, said plainly rather than buried.
    private var encryptionNote: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
            Image(systemName: "lock.fill")
                .font(.system(size: 12))
                .foregroundColor(VoiidColor.accentInk)
            Text("Messages inside a Space are end-to-end encrypted. The community itself — its "
                 + "name, members and invites — is not, so it can be searched and joined.")
                .font(VoiidFont.footnote)
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(VoiidColor.accentTint.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }
}

// MARK: - Shared

/// One empty/error treatment for every tab, so a failure and a genuine empty do not look
/// different from screen to screen.
@ViewBuilder
func emptyish(icon: String, title: String, detail: String) -> some View {
    VStack(spacing: VoiidSpacing.sm) {
        Image(systemName: icon)
            .font(.system(size: 28))
            .foregroundColor(VoiidColor.placeholder)
        Text(title)
            .font(VoiidFont.rounded(15, .semibold))
            .foregroundColor(VoiidColor.textPrimary)
            .multilineTextAlignment(.center)
        Text(detail)
            .font(VoiidFont.footnote)
            .foregroundColor(VoiidColor.textSecondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, VoiidSpacing.xl)
}
