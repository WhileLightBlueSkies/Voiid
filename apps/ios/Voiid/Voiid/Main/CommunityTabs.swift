//
//  CommunityTabs.swift
//  Voiid
//
//  Spaces, Events, Members and About — four of the five tabs inside a community. Home is in
//  CommunityHomeTab.swift.
//
//  ── ONE SCREEN PER TAB, TWO AUDIENCES ───────────────────────────────────────────
//  Each tab renders for a member OR an admin from the same view, keyed off `isAdmin`. That is
//  deliberate: an admin is a member who can also do things, not a person using a different
//  product. Building parallel screens would let the two drift until the admin view showed a
//  Space the member view had already renamed.
//
//  So the pattern throughout is: the member's version is the whole screen, and the admin's
//  version is the same screen plus affordances — a create button, a moderation menu, a row of
//  numbers at the top. Nothing an admin sees is hidden from a member unless it genuinely
//  should be (open reports, join requests, who is new).
//
//  ── WHAT EACH TAB READS ─────────────────────────────────────────────────────────
//  Home     nothing — placeholder samples, see CommunityHomeModels.swift
//  Spaces   GET /communities/:id/channels, decorated with placeholder purpose/unread/activity
//  Events   the existing CommunityEventsSection / CommunityTournamentsSection (live)
//  Members  GET /communities/:id/members, decorated with placeholder names/handles
//  About    the card already in hand, plus placeholder rules and links
//
//  ── WHERE THE PLACEHOLDERS ARE, AND WHY ─────────────────────────────────────────
//  The server returns ids and states, not display names, purposes, unread counts or online
//  flags. The reference's rows are built around exactly those fields. Rather than drop the
//  chrome (which would make this not the reference UI) or invent a fake roster (which would
//  hide real members), each row renders REAL server data where it exists and placeholder
//  decoration where it does not — see `decorated(...)` on each tab. When the backend grows
//  those columns, the decoration goes and the views do not change.
//

import SwiftUI

enum CommunityTab: String, CaseIterable, Identifiable {
    case home = "Home"
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

    /// A real channel dressed in the reference's row. Name, announcement-vs-chat and order are
    /// the server's; purpose, member count, unread and last-activity are decoration the
    /// endpoint has no columns for.
    private func decorated(_ channel: CommunityService.Channel, index: Int) -> CommunitySpace {
        let sample = CommunitySpace.samples[index % CommunitySpace.samples.count]
        return CommunitySpace(
            id: channel.id,
            name: channel.name ?? "Space",
            purpose: channel.isAnnouncement ? "Official updates from the admin team."
                                            : sample.purpose,
            icon: channel.isAnnouncement ? "megaphone.fill" : sample.icon,
            members: sample.members,
            unread: sample.unread,
            posting: channel.isAnnouncement ? .adminsOnly : .everyone,
            isJoined: true,
            isPinned: channel.isAnnouncement,
            lastActivity: sample.lastActivity
        )
    }

    /// Announcements first, then the server's order. An announcement channel is the one a
    /// member most needs to find, and it is the one they post in least.
    private var spaces: [CommunitySpace] {
        channels
            .sorted { a, b in
                a.isAnnouncement == b.isAnnouncement
                    ? (a.position ?? 0) < (b.position ?? 0)
                    : a.isAnnouncement
            }
            .enumerated()
            .map { decorated($1, index: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            if isAdmin { createRow("Create a Space", icon: "plus.square.on.square") }

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
                ForEach(spaces) { space in
                    SpaceCard(space: space, isAdmin: isAdmin)
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

    private func createRow(_ title: String, icon: String) -> some View {
        Button {
            Haptics.tap()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(VoiidColor.accent))

                Text(title)
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                Spacer(minLength: 0)

                Text("Admin")
                    .font(VoiidFont.rounded(10, .bold))
                    .foregroundColor(VoiidColor.accentInk)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(VoiidColor.accentTint))
            }
            .padding(VoiidSpacing.sm + 4)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(VoiidColor.accent.opacity(0.4), lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

private struct SpaceCard: View {
    let space: CommunitySpace
    let isAdmin: Bool

    var body: some View {
        HStack(alignment: .top, spacing: VoiidSpacing.sm + 2) {
            Image(systemName: space.icon)
                .font(.system(size: 16))
                .foregroundColor(VoiidColor.accentInk)
                .frame(width: 42, height: 42)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(VoiidColor.accentTint))

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(space.name)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    if space.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 9))
                            .foregroundColor(VoiidColor.textSecondary)
                            .rotationEffect(.degrees(45))
                    }

                    // Only shown when it RESTRICTS. "Everyone can post" is the assumption, and
                    // labelling the default adds a chip to every row for no information.
                    if space.posting == .adminsOnly {
                        Text("Admins only")
                            .font(VoiidFont.rounded(9.5, .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(VoiidColor.surfaceRaised))
                    }

                    Spacer(minLength: 0)

                    if space.unread > 0 {
                        Text("\(space.unread)")
                            .font(VoiidFont.rounded(10.5, .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .frame(minWidth: 19, minHeight: 19)
                            .background(Circle().fill(VoiidColor.accent))
                    }
                }

                Text(space.purpose)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    metaLabel("person.2", space.membersText)
                    metaLabel("clock", space.lastActivity)

                    Spacer(minLength: 0)

                    if !space.isJoined {
                        Text("Join")
                            .font(VoiidFont.rounded(12, .semibold))
                            .foregroundColor(VoiidColor.accentInk)
                    }

                    // END-TO-END ENCRYPTED, and worth saying on the row: the container is
                    // server-readable and the channel contents are not. Users deserve to know
                    // which half of a feature is encrypted, on the screen where they choose to
                    // post in it.
                    Image(systemName: "lock.fill")
                        .font(.system(size: 10))
                        .foregroundColor(VoiidColor.textSecondary)

                    if isAdmin {
                        Menu {
                            Button("Edit Space", systemImage: "pencil") {}
                            Button(space.isPinned ? "Unpin" : "Pin to top",
                                   systemImage: "pin") {}
                            Button(space.posting == .adminsOnly
                                   ? "Allow everyone to post" : "Restrict to admins",
                                   systemImage: "lock") {}
                            Divider()
                            Button("Archive Space", systemImage: "archivebox",
                                   role: .destructive) {}
                        } label: {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(VoiidColor.textSecondary)
                                .frame(width: 26, height: 22)
                        }
                        .accessibilityLabel("Manage \(space.name)")
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(VoiidSpacing.sm + 4)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    private func metaLabel(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9.5))
            Text(text)
                .font(VoiidFont.rounded(11.5))
        }
        .foregroundColor(VoiidColor.textSecondary)
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
    @State private var filter: MemberFilter = .all
    @State private var query = ""

    /// A real roster row dressed in the reference's row. Role, join date and membership are the
    /// server's; the display name, handle and online dot are decoration — the endpoint returns
    /// ids, and resolving them is the directory's job.
    private func decorated(_ member: CommunityService.Member,
                           index: Int) -> CommunityDirectoryMember {
        let sample = CommunityDirectoryMember.samples[
            index % CommunityDirectoryMember.samples.count]
        return CommunityDirectoryMember(
            id: member.id,
            name: sample.name,
            handle: sample.handle,
            isManager: member.isAdmin,
            roleLabel: member.isOwner ? "Owner" : (member.isAdmin ? "Admin" : "Member"),
            joined: joinedText(member),
            isOnline: sample.isOnline,
            isNew: sample.isNew
        )
    }

    private var directory: [CommunityDirectoryMember] {
        members.enumerated().map { decorated($1, index: $0) }
    }

    private var visible: [CommunityDirectoryMember] {
        let byFilter = directory.filter { filter.matches($0) }
        guard !query.isEmpty else { return byFilter }
        return byFilter.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.handle.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            searchField

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(MemberFilter.allCases) { option in
                        // "New" is an admin's concern — spotting an account before it posts. A
                        // member has no use for it and it would read as a leaderboard.
                        if option != .newest || isAdmin {
                            filterChip(option)
                        }
                    }
                }
            }
            .scrollIndicators(.hidden)

            // Requests first, and only for a manager: they are the rows that need acting on,
            // and a plain member is not entitled to see who asked.
            if isAdmin && !pending.isEmpty {
                sectionLabel("Requests", count: pending.count)
                ForEach(Array(pending.enumerated()), id: \.element.id) { index, m in
                    MemberDirectoryRow(member: decorated(m, index: index),
                                       isAdmin: isAdmin, pendingRequest: true)
                }
            }

            if loading && members.isEmpty {
                ProgressView().tint(VoiidColor.accent)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.lg)
            } else if let error, members.isEmpty {
                emptyish(icon: "exclamationmark.triangle", title: error,
                         detail: "Pull down to try again.")
            } else if visible.isEmpty {
                Text("No members match.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
            } else {
                VStack(spacing: 8) {
                    ForEach(visible) { member in
                        MemberDirectoryRow(member: member, isAdmin: isAdmin,
                                           pendingRequest: false)
                    }
                }
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

    private func joinedText(_ member: CommunityService.Member) -> String {
        guard let raw = member.joined_at,
              let date = ISO8601DateFormatter().date(from: raw) else { return "—" }
        let f = DateFormatter()
        f.dateFormat = "d MMM yyyy"
        return f.string(from: date)
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

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(VoiidColor.textSecondary)

            TextField("Search members", text: $query)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textPrimary)
                .tint(VoiidColor.accent)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 42)
        .background(VoiidColor.fieldFill)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }

    private func filterChip(_ option: MemberFilter) -> some View {
        let selected = filter == option

        return Button {
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.18)) { filter = option }
        } label: {
            Text(option.rawValue)
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundColor(selected ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
                .padding(.horizontal, 14)
                .frame(height: 32)
                .background(Capsule().fill(selected ? VoiidColor.accent
                                                    : VoiidColor.surfaceCard))
                .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider, lineWidth: 1))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

private struct MemberDirectoryRow: View {
    let member: CommunityDirectoryMember
    let isAdmin: Bool
    let pendingRequest: Bool

    var body: some View {
        HStack(spacing: VoiidSpacing.sm + 2) {
            CommunityAvatar(name: member.name, size: 40)
                .overlay(alignment: .bottomTrailing) {
                    if member.isOnline {
                        Circle()
                            .fill(VoiidColor.success)
                            .frame(width: 11, height: 11)
                            .overlay(Circle().stroke(VoiidColor.surfaceCard, lineWidth: 2))
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(member.name)
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)

                    if member.isManager {
                        Text(member.roleLabel)
                            .font(VoiidFont.rounded(9.5, .bold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(VoiidColor.accent))
                    }

                    if member.isNew, isAdmin {
                        Text("New")
                            .font(VoiidFont.rounded(9.5, .bold))
                            .foregroundColor(VoiidColor.accentInk)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(VoiidColor.accentTint))
                    }
                }

                Text("@\(member.handle) · Joined \(member.joined)")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            if pendingRequest {
                Text("Waiting")
                    .font(VoiidFont.rounded(10, .bold))
                    .foregroundColor(VoiidColor.accentInk)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Capsule().fill(VoiidColor.accentTint))
            } else if isAdmin {
                Menu {
                    Button("View profile", systemImage: "person.crop.circle") {}
                    Button("Message", systemImage: "message") {}
                    Divider()
                    Button("Make admin", systemImage: "star") {}
                    Button("Mute member", systemImage: "bell.slash") {}
                    Button("Remove from community", systemImage: "person.badge.minus",
                           role: .destructive) {}
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(VoiidColor.textSecondary)
                        .frame(width: 30, height: 30)
                }
                .accessibilityLabel("Manage \(member.name)")
            }
            // NO PER-MEMBER MESSAGE BUTTON for a plain member, deliberately — the reference has
            // one, and this product cannot honour it. Being in a community grants a private
            // line to the OWNER and to nobody else (030_communities.sql enforces this by
            // ABSENCE: community_host_threads has nowhere to put a second member), so a button
            // here would promise a reachability the server refuses. The Message Community bar
            // on the detail screen is the route that actually exists.
        }
        .padding(.horizontal, VoiidSpacing.sm + 4)
        .frame(height: 62)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }
}

// MARK: - About

struct CommunityAboutTab: View {
    let card: CommunityService.CommunityCard
    var isAdmin: Bool = false

    var rules: [CommunityRule] = CommunityRule.samples
    var links: [CommunityAboutLink] = CommunityAboutLink.samples

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
            section("About") {
                if let d = card.description, !d.isEmpty {
                    Text(d)
                        .font(VoiidFont.rounded(14))
                        .foregroundColor(VoiidColor.textPrimary.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: VoiidSpacing.lg) {
                    aboutStat("\(card.members)", "Members")
                    aboutStat("@\(card.handle)", "Handle")
                    aboutStat(policyText, "Joining")
                }
                .padding(.top, VoiidSpacing.sm)
            }

            section("Details") {
                VStack(alignment: .leading, spacing: 8) {
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
            }

            section("Rules") {
                VStack(spacing: 8) {
                    ForEach(Array(rules.enumerated()), id: \.element.id) { index, rule in
                        HStack(alignment: .top, spacing: VoiidSpacing.sm + 2) {
                            Text("\(index + 1)")
                                .font(VoiidFont.rounded(12.5, .bold))
                                .foregroundColor(VoiidColor.accentInk)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(VoiidColor.accentTint))

                            VStack(alignment: .leading, spacing: 2) {
                                Text(rule.title)
                                    .font(VoiidFont.rounded(14, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Text(rule.detail)
                                    .font(VoiidFont.rounded(12.5))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Spacer(minLength: 0)
                        }
                        .padding(VoiidSpacing.sm + 2)
                        .background(VoiidColor.surfaceCard)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                    style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                  style: .continuous)
                            .stroke(VoiidColor.divider, lineWidth: 1))
                    }
                }

                if isAdmin { editRow("Edit rules") }
            }

            section("Links") {
                VStack(spacing: 0) {
                    ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                        Button {
                            Haptics.tap()
                        } label: {
                            HStack(spacing: VoiidSpacing.sm + 2) {
                                Image(systemName: link.icon)
                                    .font(.system(size: 14))
                                    .foregroundColor(VoiidColor.accentInk)
                                    .frame(width: 22)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(link.label)
                                        .font(VoiidFont.rounded(13.5, .semibold))
                                        .foregroundColor(VoiidColor.textPrimary)
                                    Text(link.value)
                                        .font(VoiidFont.rounded(12))
                                        .foregroundColor(VoiidColor.textSecondary)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(VoiidColor.textSecondary)
                            }
                            .padding(.horizontal, VoiidSpacing.md - 2)
                            .frame(height: 54)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        if index < links.count - 1 {
                            Divider().overlay(VoiidColor.divider)
                                .padding(.leading, VoiidSpacing.xl)
                        }
                    }
                }
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1))
            }

            encryptionNote

            if isAdmin { dangerZone }
        }
    }

    private var policyText: String {
        switch card.policy {
        case "open":     return "Anyone can join"
        case "approval": return "Approval needed"
        default:         return "Invite only"
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            Text(title)
                .font(VoiidFont.rounded(17, .bold))
                .foregroundColor(VoiidColor.textPrimary)
            content()
        }
    }

    private func aboutStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(VoiidFont.rounded(16, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .lineLimit(1)
            Text(label)
                .font(VoiidFont.rounded(11.5))
                .foregroundColor(VoiidColor.textSecondary)
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

    private func editRow(_ title: String) -> some View {
        Button {
            Haptics.tap()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .semibold))
                Text(title)
                    .font(VoiidFont.rounded(13.5, .semibold))
            }
            .foregroundColor(VoiidColor.accentInk)
            .frame(maxWidth: .infinity)
            .frame(height: 42)
            .background(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .fill(VoiidColor.accentTint))
        }
        .buttonStyle(PressableButtonStyle())
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

    /// Admin-only, and last. Destructive settings go at the bottom of a screen so they are
    /// never the thing a thumb lands on by accident.
    private var dangerZone: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm + 2) {
            Text("Admin")
                .font(VoiidFont.rounded(17, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            VStack(spacing: 0) {
                adminRow("Community settings", "gearshape")
                Divider().overlay(VoiidColor.divider).padding(.leading, VoiidSpacing.xl)
                adminRow("Manage admins", "person.2.badge.gearshape")
                Divider().overlay(VoiidColor.divider).padding(.leading, VoiidSpacing.xl)
                adminRow("Archive community", "archivebox", destructive: true)
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
        }
    }

    private func adminRow(_ title: String, _ icon: String,
                          destructive: Bool = false) -> some View {
        Button {
            Haptics.tap()
        } label: {
            HStack(spacing: VoiidSpacing.sm + 2) {
                Image(systemName: icon)
                    .font(.system(size: 14))
                    .foregroundColor(destructive ? VoiidColor.error : VoiidColor.textSecondary)
                    .frame(width: 22)

                Text(title)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(destructive ? VoiidColor.error : VoiidColor.textPrimary)

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .padding(.horizontal, VoiidSpacing.md - 2)
            .frame(height: 50)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
