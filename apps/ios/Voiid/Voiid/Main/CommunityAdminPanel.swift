//  CommunityAdminPanel.swift
//  Voiid
//
//  The host's console. Everything a manager can do to a community lives behind one door
//  instead of being scattered across the tabs a member also sees.
//
//  Three of the writes here — ban, unban, and role assignment — have existed in the API since
//  030 with no caller anywhere in the app. That is why a community has, until now, looked like
//  it had exactly two kinds of people in it: the middle tier was unreachable, not unused.
//
//  EVERY GATE ON THIS SCREEN IS CONVENIENCE, NOT ENFORCEMENT. Each route is `requireManager`
//  server-side, checked against communities.owner_id AND the live roster row. A client that got
//  the gate wrong would draw a door that returns 403 — it could not perform an unauthorised
//  write.

import SwiftUI

struct CommunityAdminPanel: View {
    let communityId: String
    let communityName: String

    @Environment(\.dismiss) private var dismiss

    @State private var stats: CommunityService.Stats?
    @State private var queue: [CommunityService.QueueItem] = []
    @State private var members: [CommunityService.Member] = []
    @State private var pending: [CommunityService.Member] = []
    @State private var banned: [CommunityService.Member] = []

    @State private var loading = true
    /// Kept per-section rather than as one flag. A stats call that failed and a roster that
    /// merely came back empty are different facts, and a console that showed "0 members"
    /// for a network error would be lying to the one person who acts on the number.
    @State private var statsError: String?
    @State private var queueError: String?
    @State private var rosterError: String?
    /// A failed WRITE, distinct from the read errors above: one means "we couldn't show you
    /// this", the other "your action did not happen".
    @State private var writeError: String?
    /// Rows with a write in flight, so a second tap cannot fire a duplicate ban.
    @State private var busy: Set<String> = []

    @State private var section: Section = .overview
    @State private var confirmingBan: CommunityService.Member?

    private enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case queue = "Queue"
        case people = "People"
        var id: String { rawValue }
    }

    private var myUserId: String? { TokenStore.shared.userId }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(spacing: VoiidSpacing.md) {
                        picker
                        switch section {
                        case .overview: overview
                        case .queue:    queueSection
                        case .people:   peopleSection
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.bottom, VoiidSpacing.xl)
                }
                .scrollDismissesKeyboard(.interactively)

                if loading && stats == nil {
                    ProgressView().tint(VoiidColor.accent)
                }
            }
            .navigationTitle("Manage")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }
                        .foregroundColor(VoiidColor.accent)
                }
            }
            .refreshable { await load() }
            .task { await load() }
            // A write failure interrupts, because the host believes it happened.
            .alert("Couldn't complete that",
                   isPresented: .init(get: { writeError != nil },
                                      set: { if !$0 { writeError = nil } })) {
                Button("OK", role: .cancel) { writeError = nil }
            } message: { Text(writeError ?? "") }
            .confirmationDialog(
                confirmingBan.map { "Ban \($0.displayName)?" } ?? "",
                isPresented: .init(get: { confirmingBan != nil },
                                   set: { if !$0 { confirmingBan = nil } }),
                titleVisibility: .visible
            ) {
                if let m = confirmingBan {
                    Button("Ban", role: .destructive) { Task { await ban(m) } }
                }
                Button("Cancel", role: .cancel) { confirmingBan = nil }
            } message: {
                // Banning and removing are different acts and the difference is worth one
                // sentence at the moment of choosing, not a doc nobody reads.
                Text("They'll be removed and can't rejoin until you lift it.")
            }
        }
    }

    // ── Chrome ───────────────────────────────────────────────────────────────────

    private var picker: some View {
        Picker("", selection: $section) {
            ForEach(Section.allCases) { s in Text(s.rawValue).tag(s) }
        }
        .pickerStyle(.segmented)
        .padding(.top, VoiidSpacing.sm)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm, content: content)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(VoiidSpacing.md)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 12, weight: .semibold))
            .tracking(0.6)
            .foregroundColor(VoiidColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func errorNote(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13))
            .foregroundColor(VoiidColor.error)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func emptyNote(_ message: String) -> some View {
        Text(message)
            .font(.system(size: 14))
            .foregroundColor(VoiidColor.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // ── Overview ─────────────────────────────────────────────────────────────────

    private var overview: some View {
        VStack(spacing: VoiidSpacing.md) {
            card {
                Text(communityName)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("You're a host here.")
                    .font(.system(size: 13))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            if let e = statsError {
                card { errorNote(e) }
            } else if let s = stats {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: VoiidSpacing.md),
                                    GridItem(.flexible(), spacing: VoiidSpacing.md)],
                          spacing: VoiidSpacing.md) {
                    statTile("Members", s.memberCount, "person.2.fill")
                    statTile("Posts", s.postCount, "text.bubble.fill")
                    statTile("Requests", s.pending_members ?? 0, "hand.raised.fill",
                             alert: (s.pending_members ?? 0) > 0)
                    statTile("Reports", s.open_reports ?? 0, "flag.fill",
                             alert: (s.open_reports ?? 0) > 0)
                }
            }
        }
    }

    private func statTile(_ label: String, _ value: Int, _ icon: String,
                          alert: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Image(systemName: icon)
                .font(.system(size: 15, weight: .semibold))
                // Colour carries meaning only when there is something waiting: a count of
                // zero reports should not wear the same badge as a count of nine.
                .foregroundColor(alert ? VoiidColor.warning : VoiidColor.accent)
            Text("\(value)")
                .font(.system(size: 28, weight: .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .monospacedDigit()
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }

    // ── Queue ────────────────────────────────────────────────────────────────────

    private var queueSection: some View {
        VStack(spacing: VoiidSpacing.md) {
            if let e = queueError {
                card { errorNote(e) }
            } else if queue.isEmpty && !loading {
                card { emptyNote("Nothing needs you right now.") }
            } else {
                ForEach(queue) { item in
                    card {
                        HStack(spacing: VoiidSpacing.sm) {
                            Text(item.name)
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundColor(VoiidColor.textPrimary)
                            Spacer(minLength: 0)
                            if let n = item.reporter_count, n > 1 {
                                Text("\(n) reports")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(VoiidColor.warning)
                            }
                        }
                        if let d = item.detail ?? item.reason, !d.isEmpty {
                            Text(d)
                                .font(.system(size: 14))
                                .foregroundColor(VoiidColor.textSecondary)
                        }
                        HStack(spacing: VoiidSpacing.sm) {
                            if item.resolvedKind == .joinRequest, let uid = item.user_id {
                                actionButton("Approve", prominent: true,
                                             busy: busy.contains(item.id)) {
                                    await approve(uid, queueId: item.id)
                                }
                                actionButton("Decline", destructive: true,
                                             busy: busy.contains(item.id)) {
                                    await remove(uid, queueId: item.id)
                                }
                            }
                        }
                        .padding(.top, VoiidSpacing.xs)
                    }
                }
            }
        }
    }

    // ── People ───────────────────────────────────────────────────────────────────

    private var peopleSection: some View {
        VStack(spacing: VoiidSpacing.md) {
            if let e = rosterError { card { errorNote(e) } }

            if !pending.isEmpty {
                sectionTitle("Requests")
                ForEach(pending) { m in memberRow(m, state: .pending) }
            }

            sectionTitle("Members")
            if members.isEmpty && !loading {
                card { emptyNote("No members yet.") }
            } else {
                ForEach(members) { m in memberRow(m, state: .active) }
            }

            if !banned.isEmpty {
                sectionTitle("Banned")
                ForEach(banned) { m in memberRow(m, state: .banned) }
            }
        }
    }

    private enum RowState { case active, pending, banned }

    private func memberRow(_ m: CommunityService.Member, state: RowState) -> some View {
        card {
            HStack(spacing: VoiidSpacing.sm) {
                CommunityAvatar(name: m.displayName, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.displayName)
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)
                    if let role = m.role, role != "member" {
                        Text(role.capitalized)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(VoiidColor.accent)
                    }
                }
                Spacer(minLength: 0)

                if busy.contains(m.user_id) {
                    ProgressView().tint(VoiidColor.accent)
                } else if m.user_id == myUserId {
                    // The one row with no actions. A host who could demote or ban themselves
                    // could leave a community with nobody able to manage it.
                    Text("You")
                        .font(.system(size: 13))
                        .foregroundColor(VoiidColor.textSecondary)
                } else {
                    rowMenu(m, state: state)
                }
            }
        }
    }

    @ViewBuilder
    private func rowMenu(_ m: CommunityService.Member, state: RowState) -> some View {
        Menu {
            switch state {
            case .pending:
                Button("Approve", systemImage: "checkmark") {
                    Task { await approve(m.user_id, queueId: nil) }
                }
                Button("Decline", systemImage: "xmark", role: .destructive) {
                    Task { await remove(m.user_id, queueId: nil) }
                }
            case .banned:
                Button("Lift ban", systemImage: "arrow.uturn.backward") {
                    Task { await unban(m) }
                }
            case .active:
                // The owner is not ours to demote or remove — that route is owner-only
                // server-side and the row would only produce a 403.
                if !m.isOwner {
                    if m.role == "admin" {
                        Button("Remove as admin", systemImage: "person.badge.minus") {
                            Task { await setRole(m, to: "member") }
                        }
                    } else {
                        Button("Make admin", systemImage: "person.badge.shield.checkmark") {
                            Task { await setRole(m, to: "admin") }
                        }
                    }
                    Divider()
                    Button("Remove", systemImage: "person.fill.xmark", role: .destructive) {
                        Task { await remove(m.user_id, queueId: nil) }
                    }
                    Button("Ban", systemImage: "nosign", role: .destructive) {
                        confirmingBan = m
                    }
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(VoiidColor.textSecondary)
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
    }

    private func actionButton(_ title: String, prominent: Bool = false,
                              destructive: Bool = false, busy isBusy: Bool,
                              action: @escaping () async -> Void) -> some View {
        Button {
            Haptics.tap()
            Task { await action() }
        } label: {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(prominent ? VoiidColor.textOnAccent
                                 : (destructive ? VoiidColor.error : VoiidColor.textPrimary))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(prominent ? VoiidColor.accent : VoiidColor.surfaceRaised)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        }
        .disabled(isBusy)
        .opacity(isBusy ? 0.5 : 1)
    }

    // ── Data ─────────────────────────────────────────────────────────────────────

    private func load() async {
        loading = true
        defer { loading = false }
        let svc = CommunityService.shared

        // Each read owns its own error. One failure must not blank the sections that
        // succeeded — a host with a broken stats endpoint can still work the queue.
        do { stats = try await svc.stats(communityId: communityId); statsError = nil }
        catch { statsError = "Couldn't load the numbers." }

        do { queue = try await svc.moderationQueue(communityId: communityId); queueError = nil }
        catch { queueError = "Couldn't load the queue." }

        do {
            async let a = svc.members(communityId: communityId, state: "active")
            async let p = svc.members(communityId: communityId, state: "pending")
            async let b = svc.members(communityId: communityId, state: "banned")
            let (active, pend, ban) = try await (a, p, b)
            // Hosts and admins first: the people who can act on this screen are the people
            // a host most often looks for on it.
            members = active.sorted {
                if $0.isAdmin != $1.isAdmin { return $0.isAdmin }
                return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
            pending = pend
            banned = ban
            rosterError = nil
        } catch {
            rosterError = "Couldn't load the roster."
        }
    }

    private func approve(_ userId: String, queueId: String?) async {
        await write(key: queueId ?? userId) {
            try await CommunityService.shared.approveMember(
                communityId: communityId, userId: userId)
        }
    }

    private func remove(_ userId: String, queueId: String?) async {
        await write(key: queueId ?? userId) {
            try await CommunityService.shared.removeMember(
                communityId: communityId, userId: userId)
        }
    }

    private func ban(_ m: CommunityService.Member) async {
        confirmingBan = nil
        await write(key: m.user_id) {
            try await CommunityService.shared.banMember(
                communityId: communityId, userId: m.user_id)
        }
    }

    private func unban(_ m: CommunityService.Member) async {
        await write(key: m.user_id) {
            try await CommunityService.shared.unbanMember(
                communityId: communityId, userId: m.user_id)
        }
    }

    private func setRole(_ m: CommunityService.Member, to role: String) async {
        await write(key: m.user_id) {
            try await CommunityService.shared.setRole(
                communityId: communityId, userId: m.user_id, role: role)
        }
    }

    /// Every write goes through here so busy-tracking, error surfacing, and the reload are
    /// one behaviour rather than five copies that drift.
    private func write(key: String, _ body: @escaping () async throws -> Void) async {
        guard !busy.contains(key) else { return }
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await body()
            Haptics.success()
            // Reload rather than mutate locally: a ban moves a row between three lists and
            // changes two counts, and the server is the only thing that knows the result.
            await load()
        } catch {
            writeError = error.localizedDescription
        }
    }
}
