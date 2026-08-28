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
//  Home     GET /communities/:id/posts + /announcements (live); the admin dashboard's
//           stats and task queue are still placeholder — they have no backend at all
//  Spaces   GET /communities/:id/channels, decorated with placeholder purpose/unread/activity
//  Events   the existing CommunityEventsSection / CommunityTournamentsSection (live)
//  Members  GET /communities/:id/members, decorated with placeholder names/handles
//  About    the card already in hand, plus GET /communities/:id/links (live) and
//           placeholder rules
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
    @State private var showNewSpace = false
    @State private var newSpaceName = ""
    @State private var creatingSpace = false
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
        .alert("New Space", isPresented: $showNewSpace) {
            TextField("Name", text: $newSpaceName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { Task { await createSpace() } }
                // A Space with no name is not a Space, and the server 400s on it — better to
                // refuse here than round-trip for the same answer.
                .disabled(newSpaceName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("Spaces are channels inside this community.")
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

    private func createSpace() async {
        let name = newSpaceName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !creatingSpace else { return }
        creatingSpace = true
        defer { creatingSpace = false }
        do {
            let channel = try await CommunityService.shared.createChannel(
                communityId: communityId, name: name)
            // Appended locally as well as persisted: the new Space appears immediately
            // rather than after a round trip the user has no reason to wait through.
            channels.append(channel)
            Haptics.success()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t create that Space."
        }
    }

    private func createRow(_ title: String, icon: String) -> some View {
        Button {
            Haptics.tap()
            // WAS AN EMPTY CLOSURE. The row rendered, fired a haptic, and returned — so an
            // admin got tactile confirmation and no sheet, no error and no Space. The
            // endpoint behind it has worked since 032; only the caller was missing.
            newSpaceName = ""
            showNewSpace = true
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
    /// The ids currently being written, NOT a single `busy` flag: a manager clearing a queue
    /// taps several rows in a row, and one shared flag would freeze the whole list on each.
    @State private var deciding: Set<String> = []
    /// Kept apart from `error`, which owns the ROSTER's failure. A refused approval must not
    /// replace a roster that loaded perfectly well with an error state.
    @State private var queueError: String?
    @State private var loading = true
    @State private var error: String?
    @State private var filter: MemberFilter = .all
    @State private var query = ""

    /// A roster row, entirely from the server.
    ///
    /// THIS USED TO SHOW SAMPLE NAMES. It indexed a bundled `samples` array by array
    /// position and used that person's name, handle and online dot — so every row displayed
    /// a fabricated identity for a real member, and the search below filtered those
    /// fabrications, meaning searching a member's actual name returned nothing.
    ///
    /// The real values were on the wire the whole time; `CommunityService.Member` simply did
    /// not decode them.
    private func decorated(_ member: CommunityService.Member) -> CommunityDirectoryMember {
        CommunityDirectoryMember(
            id: member.id,
            name: member.displayName,
            handle: member.username.map { "@\($0)" } ?? "",
            isManager: member.isAdmin,
            roleLabel: member.isOwner ? "Owner" : (member.isAdmin ? "Admin" : "Member"),
            joined: joinedText(member),
            // Presence is NOT part of the roster response, and inventing it was the worst
            // part of the old version — a green dot is a claim about someone being there
            // right now. Absent until the endpoint carries it.
            isOnline: false,
            isNew: false
        )
    }

    private var directory: [CommunityDirectoryMember] {
        members.map(decorated)
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
                ForEach(pending) { m in
                    MemberDirectoryRow(
                        member: decorated(m),
                        isAdmin: isAdmin,
                        pendingRequest: true,
                        onApprove: { Task { await decide(m, approve: true) } },
                        onDecline: { Task { await decide(m, approve: false) } },
                        busy: deciding.contains(m.id))
                }
                if let queueError {
                    Text(queueError)
                        .font(VoiidFont.rounded(12))
                        .foregroundColor(VoiidColor.error)
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

    /// Approve or decline one request.
    ///
    /// Both verbs already existed on the server and on `CommunityService`; only the buttons
    /// were missing. `remove` and NOT `ban` for a decline — the row lands on `left`, which
    /// means "may ask again", and there is deliberately no `declined` state in the schema to
    /// mark them with. See `CommunityMembership`.
    ///
    /// The row is dropped optimistically ONLY after the call returns, and the roster is
    /// reloaded on an approval because the new member now belongs in the list below — a local
    /// insert would have to invent their role and join date.
    private func decide(_ member: CommunityService.Member, approve: Bool) async {
        guard !deciding.contains(member.id) else { return }
        deciding.insert(member.id)
        defer { deciding.remove(member.id) }
        do {
            if approve {
                try await CommunityService.shared.approveMember(
                    communityId: communityId, userId: member.id)
            } else {
                try await CommunityService.shared.removeMember(
                    communityId: communityId, userId: member.id)
            }
            queueError = nil
            Haptics.success()
            await load()
        } catch {
            queueError = (error as? APIError)?.errorDescription
                ?? (approve ? "Couldn\u{2019}t approve that request."
                            : "Couldn\u{2019}t decline that request.")
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
    /// Nil for a row that is not an answerable request, which is what keeps the roster rows
    /// from growing two buttons they have no route for.
    var onApprove: (() -> Void)?
    var onDecline: (() -> Void)?
    /// Set while THIS community's queue is writing, so a double-tap cannot approve twice —
    /// the second call would 200 with `changed: false`, but the row would have lied in
    /// between about which state it was in.
    var busy: Bool = false

    /// Text-weight, not filled. Two filled pills in a roster row would out-shout the member's
    /// own name, and this row's metrics are signed off — the actions live in the space the
    /// overflow menu occupies on every other row.
    private func requestAction(_ title: String, tint: Color,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(VoiidFont.rounded(12, .semibold))
                .foregroundColor(tint)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(Capsule().fill(VoiidColor.fieldFill))
        }
        .buttonStyle(.plain)
    }

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
                // A REQUEST IS A THING TO ANSWER. This was a dead "Waiting" badge: the
                // Requests section named the queue and then gave the manager no way to
                // clear it, so the only route to approving anyone was the separate
                // moderation dashboard. Both endpoints already existed.
                //
                // Approve and Decline, never Ban. `remove` sets the row to `left`, which
                // means the applicant may ask again — the right default for someone whose
                // only act so far was knocking. Banning is a deliberate, harsher verb and
                // must not sit one tap from a queue.
                if isAdmin {
                    HStack(spacing: 6) {
                        requestAction("Decline", tint: VoiidColor.textSecondary) {
                            onDecline?()
                        }
                        requestAction("Approve", tint: VoiidColor.accentInk) {
                            onApprove?()
                        }
                    }
                    .disabled(busy)
                    .opacity(busy ? 0.5 : 1)
                } else {
                    Text("Waiting")
                        .font(VoiidFont.rounded(10, .bold))
                        .foregroundColor(VoiidColor.accentInk)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Capsule().fill(VoiidColor.accentTint))
                }
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

    /// The About tab's links, from GET /communities/:id/links (047). Server-readable by
    /// design — 047: "Shown on the public info card, to non-members, by definition".
    @State private var links: [CommunityService.AboutLink] = []
    @State private var linksLoading = true
    /// Non-nil ONLY on a real failure. A failed fetch must never render as an empty list: an
    /// empty Links section says the host added none, which is a different fact.
    @State private var linksError: String?

    /// The add-a-link sheet (CommunityAuthoring.swift). Manager only — `POST /:id/links` and
    /// `DELETE /:id/links/:linkId` are both `requireManager`, so a member has neither control.
    @State private var addingLink = false
    /// The link awaiting a delete confirmation. Non-nil IS the alert's presented state, so the
    /// confirmation can never act on a row that has since been reloaded away.
    @State private var pendingDelete: CommunityService.AboutLink?
    /// Deletes in flight, so a second tap cannot fire a duplicate.
    @State private var deleteBusy: Set<String> = []
    /// A failed WRITE, kept apart from `linksError` (a failed READ). "We couldn't load your
    /// links" and "your link was not added" are different sentences and must not share a slot.
    @State private var writeError: String?

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

            // The section is drawn only when there is something to say. A host who added no
            // links gets no empty card — which is why this is not an `emptyish` placeholder:
            // "no links" is the ordinary state of most communities, not a gap to apologise for.
            //
            // `|| isAdmin` is the one addition: a manager who has added no links still needs
            // somewhere to add the first one, and for them an empty section is a place to act
            // rather than a gap to apologise for. A member's view is unchanged.
            if linksLoading || linksError != nil || !links.isEmpty || isAdmin {
                section("Links") {
                    linksBody

                    if isAdmin {
                        addLinkRow
                    }

                    if let writeError {
                        Text(writeError)
                            .font(VoiidFont.rounded(12))
                            .foregroundColor(VoiidColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            encryptionNote

            if isAdmin { dangerZone }
        }
        .task(id: card.id) { await loadLinks() }
        .sheet(isPresented: $addingLink) {
            CommunityLinkComposer(communityId: card.id) { link in
                // Appended, not prepended: the server puts a new link at the END of the list
                // (`position` defaults to max + 1, precisely so adding one does not reshuffle
                // the ones already there), and the local order must match what a reload gives.
                links.append(link)
                linksError = nil
                writeError = nil
            }
        }
        .alert("Remove this link?", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }
        ), presenting: pendingDelete) { link in
            Button("Remove", role: .destructive) {
                Task { await deleteLink(link) }
            }
            Button("Cancel", role: .cancel) { pendingDelete = nil }
        } message: { link in
            // A HARD delete, unlike a post — 047 gives community_links no `removed_at` because
            // removing a dead URL is housekeeping, not a statement with an appeal. The copy
            // says so rather than implying a history that does not exist.
            Text("\u{201C}\(link.title)\u{201D} is removed from About. This cannot be undone.")
        }
    }

    /// Manager only. The same shape as `editRow` above it, because it does the same kind of
    /// thing to the section it sits under.
    private var addLinkRow: some View {
        Button {
            Haptics.tap()
            addingLink = true
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                Text("Add a link")
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

    /// Remove a link, optimistically, restoring it to its ORIGINAL index on failure — the
    /// list is ordered by the host's `position`, so putting a failed delete back at the end
    /// would silently reorder About as the cost of the failure.
    private func deleteLink(_ link: CommunityService.AboutLink) async {
        pendingDelete = nil
        guard !deleteBusy.contains(link.id) else { return }
        guard let index = links.firstIndex(where: { $0.id == link.id }) else { return }

        deleteBusy.insert(link.id)
        defer { deleteBusy.remove(link.id) }

        let removed = links.remove(at: index)
        writeError = nil

        do {
            try await CommunityService.shared.deleteLink(communityId: card.id, linkId: link.id)
            Haptics.success()
        } catch {
            Haptics.error()
            links.insert(removed, at: min(index, links.count))
            writeError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t remove that link."
        }
    }

    /// Loading / failed / list — three distinct states, never collapsed. The list itself is
    /// the reference's rows unchanged; only where the rows come from has moved.
    @ViewBuilder
    private var linksBody: some View {
        if linksLoading && links.isEmpty {
            ProgressView().tint(VoiidColor.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, VoiidSpacing.lg)
        } else if let linksError, links.isEmpty {
            emptyish(icon: "exclamationmark.triangle", title: linksError,
                     detail: "Pull down to try again.")
        } else if links.isEmpty {
            // Reached ONLY by a manager: the section is not drawn at all for a member with no
            // links (see the guard above). Explicit rather than falling through to an empty
            // card, so the Add row below has a sentence to sit under.
            Text("No links yet. Add a website, an email address, or anything else people "
                 + "should be pointed at.")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(spacing: 0) {
                ForEach(Array(links.enumerated()), id: \.element.id) { index, link in
                    Button {
                        Haptics.tap()
                    } label: {
                        HStack(spacing: VoiidSpacing.sm + 2) {
                            // The host picks an SF Symbol from a client-side set (047 leaves
                            // `icon` free text for exactly that reason), so nil is normal and
                            // the fallback is chosen here rather than invented by the server.
                            Image(systemName: link.icon ?? "link")
                                .font(.system(size: 14))
                                .foregroundColor(VoiidColor.accentInk)
                                .frame(width: 22)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(link.title)
                                    .font(VoiidFont.rounded(13.5, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Text(link.subtitle)
                                    .font(VoiidFont.rounded(12))
                                    .foregroundColor(VoiidColor.textSecondary)
                            }

                            Spacer(minLength: 0)

                            // A MANAGER'S ROW ENDS IN A MINUS, EVERYONE ELSE'S IN THE ARROW.
                            // The member's row is untouched — the branch adds a control where
                            // one can succeed rather than changing the one that was signed off.
                            //
                            // The rule is the route's: `DELETE /:id/links/:linkId` is
                            // `requireManager`. Client-side this is CONVENIENCE ONLY; the
                            // server refuses a non-manager whether or not the button was drawn.
                            if isAdmin {
                                Image(systemName: "minus.circle")
                                    .font(.system(size: 15))
                                    .foregroundColor(VoiidColor.error)
                                    // Its own hit target inside the row's button: the row
                                    // opens the link, this removes it, and they must not be
                                    // one tap apart in the same rectangle.
                                    .frame(width: 30, height: 44)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        Haptics.tap()
                                        pendingDelete = link
                                    }
                                    .accessibilityLabel("Remove \(link.title)")
                            } else {
                                Image(systemName: "arrow.up.right")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(VoiidColor.textSecondary)
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md - 2)
                        .frame(height: 54)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .opacity(deleteBusy.contains(link.id) ? 0.45 : 1)
                    .allowsHitTesting(!deleteBusy.contains(link.id))

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
    }

    private func loadLinks() async {
        linksLoading = true
        defer { linksLoading = false }
        do {
            links = try await CommunityService.shared.links(communityId: card.id)
            linksError = nil
        } catch {
            linksError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t load links."
        }
    }

    /// From `JoinPolicyOption`, the same list the host's settings picker is built from. This
    /// used to be its own switch, duplicating one in `CommunityDetailView.visibilityText` —
    /// two places for three strings, i.e. two chances to drift apart.
    private var policyText: String {
        JoinPolicyOption.shortLabel(for: card.policy)
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
