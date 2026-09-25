//
//  CommunityDetailView.swift
//  Voiid
//
//  One community: what it is, how many people are in it, and how to join.
//
//  DELIBERATELY NOT HERE: a member list with tap targets. Being in a community grants a
//  private line to the OWNER and to nobody else (030_communities.sql enforces this by
//  ABSENCE — community_host_threads has nowhere to put a second member), so a roster you
//  could tap into would imply a reachability this product does not give you.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

struct CommunityDetailView: View {
    let handle: String

    @State private var card: CommunityService.CommunityCard?
    @State private var loading = true
    @State private var error: String?
    /// A failure from a TAP, kept apart from `error` (a failure to LOAD). The empty state
    /// renders the latter; only this one is worth interrupting a drawn card for.
    @State private var actionError: String?
    @State private var busy = false
    @State private var showInvite = false
    @State private var showReport = false
    @State private var confirmLeave = false
    @State private var showInbox = false
    @State private var adminCard: CommunityService.CommunityCard?
    /// Settings opened straight from the setup card's "rules" task, skipping the admin panel.
    @State private var settingsCard: CommunityService.CommunityCard?
    /// Set when a join was refused for want of a college email (088).
    @State private var collegeEmailCard: CommunityService.CommunityCard?
    @State private var tab: CommunityTab = .home
    @State private var openConversation: VConversation?
    @State private var notificationMode: String?
    @State private var savingNotificationMode = false

    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var chat: ChatStore
    @EnvironmentObject private var session: AppSession

    /// The card carries `owner_id`, so this needs no extra request.
    private func isOwner(_ card: CommunityService.CommunityCard) -> Bool {
        guard let me = TokenStore.shared.userId, let owner = card.owner_id else { return false }
        return me == owner
    }

    /// Resolve the host thread's conversation and push the real chat. Same lookup ChatsHome
    /// uses for a notification deep-link: it may not be in memory yet, so load before failing.
    private func openHostConversation(_ convId: String) {
        Task { @MainActor in
            if chat.conversation(id: convId) == nil {
                await chat.loadConversations()
            }
            if let conv = chat.conversation(id: convId) {
                openConversation = conv
            } else {
                error = "That conversation isn’t available on this device yet."
            }
        }
    }

    var body: some View {
        ZStack(alignment: .bottom) {
            VoiidColor.background.ignoresSafeArea()

            if let card {
                ScrollView {
                    VStack(spacing: 0) {
                        hero
                        identity(card)
                        actions(card)
                        Divider().overlay(VoiidColor.divider)
                            .padding(.top, VoiidSpacing.md)
                        sections(card)
                    }
                }
                .scrollIndicators(.hidden)
                .ignoresSafeArea(edges: .top)
                // Clears the tab bar AND the host bar that floats above it.
                .contentMargins(.bottom, session.bottomInset + 96, for: .scrollContent)

                hostBar(card)
            } else if loading {
                ProgressView().tint(VoiidColor.accent)
            } else {
                VStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundColor(VoiidColor.textSecondary)
                    Text(error ?? "Couldn\u{2019}t load that community.")
                        .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await load() } }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.accentInk)
                }
                .padding(VoiidSpacing.xl)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .task(id: scenePhase) {
            guard scenePhase == .active else { return }
            await load()
            while !Task.isCancelled {
                await GroupEngine.shared.syncGroupEvents()
                do { try await Task.sleep(for: .seconds(10)) } catch { break }
                await load()
            }
        }
        .sheet(isPresented: $showInvite) { if let card { CommunityInviteView(card: card) } }
        .sheet(isPresented: $showReport) { if let card { ReportSheet(target: .community(communityId: card.id)) { showReport = false } } }
        .alert("Leave this community?", isPresented: $confirmLeave) {
            Button("Cancel", role: .cancel) {}
            Button("Leave", role: .destructive) {
                Task {
                    busy = true
                    defer { busy = false }
                    do { if let card { _ = try await CommunityService.shared.leave(communityId: card.id); await load() } }
                    catch { actionError = error.localizedDescription }
                }
            }
        }
        .refreshable { await load() }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("communityMembershipChanged"))) { note in
            if note.userInfo?["community_id"] as? String == card?.id { Task { await load() } }
        }
        .sheet(isPresented: $showInbox) { CommunityRequestInbox(communityId: card?.id ?? "") }
        // Bound to the card rather than a bool: the console needs a community id, and the
        // only proof we have one is the card that produced the menu the host just tapped.
        .sheet(item: $adminCard) { c in
            CommunityAdminPanel(communityId: c.id, communityName: c.name, isOwner: isOwner(c), communityCard: c, onSettingsSaved: { card = $0; Task { await load() } })
        }
        .sheet(item: $collegeEmailCard) { c in
            CollegeEmailSheet(card: c) { Task { await join(c) } }
        }
        .sheet(item: $settingsCard) { c in
            CommunitySettingsView(card: c, onSaved: { card = $0 })
        }
        .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
        // A FAILED ACTION HAD NOWHERE TO GO. `error` is rendered only in the no-card branch,
        // so a refused join or cancel set a string that nothing on screen ever drew — the tap
        // simply did nothing. An alert rather than an inline banner: the card layout is
        // signed off, and a failure that pushes the hero down is a layout change.
        //
        // Bound to `actionError` and NOT to `error`, because `error` doubles as the load
        // failure and alerting over the empty state would show the same sentence twice.
        .alert("Couldn\u{2019}t do that", isPresented: Binding(
            get: { actionError != nil },
            set: { if !$0 { actionError = nil } }
        ), presenting: actionError) { _ in
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text($0) }
    }

    // MARK: Hero

    /// A soft accent wash rather than a photo. The community's identity here is its mark and
    /// its name, and a stock image behind them would only compete.
    private var hero: some View {
        LinearGradient(
            colors: [
                VoiidColor.accent.opacity(0.22),
                VoiidColor.accent.opacity(0.05),
                VoiidColor.background,
            ],
            startPoint: .topTrailing, endPoint: .bottomLeading
        )
        .frame(height: 132)
        .frame(maxWidth: .infinity)
        .background(VoiidColor.background)
        .overlay(alignment: .topTrailing) {
            Circle()
                .fill(VoiidColor.accent.opacity(0.14))
                .frame(width: 200, height: 200)
                .blur(radius: 46)
                .offset(x: 54, y: -84)
        }
    }

    // MARK: Identity

    private func identity(_ c: CommunityService.CommunityCard) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            // The mark overlaps the banner, which is what ties the two together.
            mark(c)
                .frame(width: 68, height: 68)
                .background(Circle().fill(VoiidColor.surfaceCard))
                .overlay(Circle().stroke(VoiidColor.background, lineWidth: 4))
                .offset(y: -34)
                .padding(.bottom, -34)

            HStack(spacing: 6) {
                Text(c.name ?? "@\(c.handle)")
                    .font(VoiidFont.rounded(24, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                if c.official == true { Image(systemName: "checkmark.seal.fill").foregroundColor(VoiidColor.accentInk).accessibilityLabel("Official Voiid community") }
                if isOwner(c) {
                    Text("HOST")
                        .font(VoiidFont.rounded(9.5, .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(VoiidColor.accent))
                }
            }

            InstitutionMark(name: c.institution_name)

            HStack(spacing: 6) {
                Image(systemName: "person.2.fill").font(.system(size: 11))
                Text("\(c.members) member\(c.members == 1 ? "" : "s")")
                Text("\u{2022}")
                // Shared with the list row and the settings picker — an `approval` community
                // is not an open globe and is not a padlock either, and drawing it as one of
                // those two was how the middle policy kept being read as the wrong extreme.
                Image(systemName: JoinPolicyOption.icon(for: c.policy))
                    .font(.system(size: 10))
                Text(visibilityText(c))
            }
            .font(VoiidFont.rounded(12.5))
            .foregroundColor(VoiidColor.textSecondary)

            if let d = c.description, !d.isEmpty {
                Text(d)
                    .font(VoiidFont.rounded(14))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("@\(c.handle)")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.placeholder)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    /// NO FACE PILE, deliberately — see the note at the top of this file. Membership grants a
    /// line to the OWNER and to nobody else, so a row of member avatars would imply a
    /// reachability this product does not give you. The count says the same thing honestly.
    @ViewBuilder
    private func mark(_ c: CommunityService.CommunityCard) -> some View {
        if c.avatar_url != nil {
            ClipThumbnail(url: c.avatar_url)
                .frame(width: 68, height: 68)
                .clipShape(Circle())
        } else {
            Circle()
                .fill(VoiidColor.accentTint)
                .overlay(
                    Text(initials(c))
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundColor(VoiidColor.accentInk)
                )
        }
    }

    private func initials(_ c: CommunityService.CommunityCard) -> String {
        let source = c.name ?? c.handle
        let parts = source.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? String(source.prefix(1)).uppercased() : letters.uppercased()
    }

    /// Reads from `JoinPolicyOption`, which is where the picker a host chooses from also
    /// reads. There used to be a switch here, a second one in `CommunityAboutTab.policyText`
    /// and a third ternary in `CommunitiesHomeView` that did not know about `approval` at all
    /// — three chances for a host's choice and a visitor's reading to disagree. Now one.
    private func visibilityText(_ c: CommunityService.CommunityCard) -> String {
        JoinPolicyOption.shortLabel(for: c.policy)
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ c: CommunityService.CommunityCard) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            joinButton(c)

            if isOwner(c) || c.isManager {
                Button {
                    Haptics.tap()
                    showInbox = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.full").font(.system(size: 13, weight: .semibold))
                        Text("Inbox").font(VoiidFont.rounded(15, .semibold))
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Capsule().fill(VoiidColor.surfaceCard))
                    .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
            } else if c.canInvite {
                // INVITE, not Share. Only a member can hand out a way in, and only for a
                // community whose policy allows one — see POST /communities/:id/invites.
                Button {
                    Haptics.tap()
                    showInvite = true
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Invite").font(VoiidFont.rounded(15, .semibold))
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 40)
                    .background(Capsule().fill(VoiidColor.surfaceCard))
                    .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }

            overflowMenu(c)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.md)
    }

    /// The reference's chevron menu. "Leave" is absent for the owner: an owner leaving would
    /// orphan the community, and DELETE /communities/:id/members is the route that refuses it.
    @ViewBuilder
    private func overflowMenu(_ c: CommunityService.CommunityCard) -> some View {
        Menu {
            if c.isMember {
                Menu("Notifications", systemImage: "bell") {
                    ForEach(["all", "important", "none"], id: \.self) { mode in
                        Button {
                            savingNotificationMode = true
                            Task {
                                defer { savingNotificationMode = false }
                                do {
                                    try await CommunityService.shared.setNotificationPreference(communityId: c.id, mode: mode)
                                    notificationMode = mode
                                } catch { actionError = "Couldn’t save notification settings. Please try again." }
                            }
                        } label: {
                            Label(mode.capitalized, systemImage: notificationMode == mode ? "checkmark.circle.fill" : "circle")
                        }
                        .disabled(savingNotificationMode)
                    }
                    Text("Important: announcements, events and public post mentions")
                }
            }
            // HOST ONLY, and gated on the SAME `isOwner` signal the Inbox action uses — that
            // is deliberate reuse rather than a second guess at manager-ness.
            //
            // THE CLIENT GATE IS CONVENIENCE, NOT ENFORCEMENT. Every route the settings screen
            // touches is `requireManager` server-side (an ACTIVE owner or an ACTIVE admin of a
            // live community, checked against communities.owner_id AND the roster row). This
            // test only stops a member being shown a door that would refuse them; a build that
            // got it wrong would produce a 403, not an unauthorised write.
            //
            // It sits in the overflow rather than the button row on purpose: the row is a
            // signed-off layout, and settings is a rare, deliberate act rather than something
            // a host reaches for on every visit.
            if isOwner(c) || c.isManager {
                // The console goes above settings because it is the thing a host opens to
                // ACT — approve, moderate, promote — while settings is where they go to
                // change what the community IS. Frequency, not importance, sets the order.
                Button("Admin panel", systemImage: "shield.lefthalf.filled") {
                    Haptics.tap()
                    adminCard = c
                }
                Divider()
            }
            Button("Invite / QR code", systemImage: "qrcode") { showInvite = true }
                .disabled(!c.canInvite && !c.isDiscoverable)
            Button("Report", systemImage: "exclamationmark.triangle") { showReport = true }
            if c.isMember && !isOwner(c) {
                Divider()
                Button("Leave community",
                       systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) { confirmLeave = true }
            }
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoiidColor.textPrimary)
                .frame(width: 46, height: 40)
                .background(Capsule().fill(VoiidColor.surfaceCard))
                .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
        }
        .accessibilityLabel("More community options")
    }

    /// Every membership state the server can put you in, said plainly — ONE switch over
    /// `CommunityMembership`, so this screen cannot disagree with the list row or the join
    /// sheet about what the caller's relationship is.
    ///
    /// A banned account is TOLD it cannot join rather than shown a button that will 403. An
    /// approval-gated request says "Requested" rather than "Joined", because the lie would be
    /// discovered on the next screen when no channels appeared.
    ///
    /// `left` is not a case here. It arrives as `.none` and is offered the join button again,
    /// which is also how a DECLINED request arrives: rejecting an applicant sets their row to
    /// `left` (there is no `declined` state in the schema), so "you may ask again" is both
    /// what the server means and what this draws.
    @ViewBuilder
    private func joinButton(_ c: CommunityService.CommunityCard) -> some View {
        switch c.membership {
        case .banned:
            pill("You can\u{2019}t join", filled: false, disabled: true)
        case .suspended:
            pill("Suspended", filled: false, disabled: true)
        case .joined:
            pill("Joined", icon: "checkmark", filled: true, disabled: true)
        case .requested:
            // A LIVE control, not a dead badge — and only because the route supports it:
            // POST /:id/leave moves `state in ('active','pending')`, so withdrawing an
            // unapproved request is the same call that leaves a community. If it did not,
            // this would be the disabled "Requested" pill and nothing more.
            Button {
                Haptics.tap()
                Task { await cancelRequest(c) }
            } label: {
                pillLabel("Cancel request", icon: "xmark", filled: false)
            }
            .buttonStyle(.plain)
            .disabled(busy)
            .accessibilityHint("Withdraws your request to join. You can ask again later.")
        case .none:
            Button {
                Haptics.tap()
                Task { await join(c) }
            } label: {
                pillLabel(c.policy == "approval" ? "Request to join" : "Join",
                          icon: "plus", filled: true)
            }
            .buttonStyle(.plain)
            .disabled(busy)
        }
    }

    private func pill(_ text: String, icon: String? = nil,
                      filled: Bool, disabled: Bool) -> some View {
        pillLabel(text, icon: icon, filled: filled).opacity(disabled ? 0.75 : 1)
    }

    private func pillLabel(_ text: String, icon: String? = nil, filled: Bool) -> some View {
        HStack(spacing: 6) {
            if let icon {
                Image(systemName: icon).font(.system(size: 13, weight: .bold))
            }
            Text(text).font(VoiidFont.rounded(15, .semibold))
        }
        .foregroundColor(filled ? VoiidColor.textOnAccent : VoiidColor.textPrimary)
        .frame(maxWidth: .infinity).frame(height: 40)
        .background(Capsule().fill(filled ? VoiidColor.accent : VoiidColor.surfaceCard))
        .overlay(Capsule().stroke(filled ? .clear : VoiidColor.divider, lineWidth: 1))
    }

    // MARK: Sections

    /// Members only, because the endpoints 403 everyone else and an empty section would read
    /// as "no events" rather than "not visible to you".
    @ViewBuilder
    private func sections(_ c: CommunityService.CommunityCard) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // Members only. The Spaces and Members endpoints refuse everyone else, and an
            // empty tab reads as "nothing here" rather than "not visible to you" — so a
            // non-member gets About, which is the tab whose content they are entitled to.
            if c.isMember {
                tabBar(managing: isOwner(c) || c.isManager)
                Group {
                    // A selection that is no longer visible — restored state, or a demotion
                    // while the screen is open — falls back to Home rather than rendering a
                    // tab the bar above no longer offers a way back from.
                    switch (CommunityTab.visible(isManager: isOwner(c) || c.isManager).contains(tab) ? tab : .home) {
                    case .home:
                        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                            // What the two-step create flow left for later. Owner only: these
                            // are decisions about what the community IS.
                            if isOwner(c) {
                                CommunitySetupCard(
                                    card: c,
                                    onUpdated: { card = $0 },
                                    onAddSpaces: { withAnimation(.easeOut(duration: 0.2)) { tab = .spaces } },
                                    onSetRules: { settingsCard = c },
                                    onInvite: { showInvite = true })
                            }
                            CommunityHomeTab(communityId: c.id, isAdmin: isOwner(c) || c.isManager, canPost: c.can_post == true)
                        }
                    case .spaces:
                        CommunitySpacesTab(communityId: c.id, isAdmin: isOwner(c) || c.isManager,
                                           openConversation: $openConversation)
                    case .events:
                        // `isOwner` is the manager signal this screen already uses for every
                        // other tab — reused rather than re-derived, so there is one answer to
                        // "does this person run this community" on this screen.
                        //
                        // IT IS NOT THE AUTHORISATION. Every hosting endpoint is gated on the
                        // server by `communityAccess(..., needsAdmin: true)`; this flag only
                        // decides whether the buttons are drawn.
                        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                            CommunityEventsSection(communityId: c.id, isHost: isOwner(c) || c.isManager, isOwner: isOwner(c))
                            // Tournaments hidden until an explicit post-launch enablement.
                        }
                    case .members:
                        CommunityMembersTab(communityId: c.id, isAdmin: isOwner(c) || c.isManager, isOwner: isOwner(c))
                    case .about:
                        CommunityAboutTab(card: c, isAdmin: isOwner(c) || c.isManager)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
            } else {
                CommunityAboutTab(card: c, isAdmin: false)
                    .padding(.horizontal, VoiidSpacing.md)
            }
        }
        .padding(.top, VoiidSpacing.md)
    }

    /// Underlined, not filled. A filled pill here would compete with the Join button directly
    /// above it, and the tab row is navigation rather than an action.
    private func tabBar(managing: Bool) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(CommunityTab.visible(isManager: managing)) { option in
                    let selected = tab == option
                    Button {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.18)) { tab = option }
                    } label: {
                        VStack(spacing: 6) {
                            Text(option.rawValue)
                                .font(VoiidFont.rounded(14.5, selected ? .semibold : .regular))
                                .foregroundColor(selected ? VoiidColor.textPrimary
                                                          : VoiidColor.textSecondary)
                            Capsule()
                                .fill(selected ? VoiidColor.accent : .clear)
                                .frame(height: 2)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Host bar

    /// Floats above the tab bar, the way the reference's message bar does. Members only: a
    /// non-member has no line to the host, and offering one would promise what the endpoint
    /// refuses. The owner sees the Inbox action instead, up in `actions`.
    @ViewBuilder
    private func hostBar(_ c: CommunityService.CommunityCard) -> some View {
        if c.isMember && !isOwner(c) {
            MessageHostButton(communityId: c.id) { conversationId in
                openHostConversation(conversationId)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, session.bottomInset + VoiidSpacing.sm)
        }
    }

    /// Stated on the screen rather than buried: the container is server-readable and the
    /// channels are not. Users deserve to know which half of a feature is encrypted.
    private var notice: some View {
        Text("Home and Space posts are not end-to-end encrypted. Existing chats are encrypted. The community "
             + "itself \u{2014} its name, members and invites \u{2014} is not, so it can be searched and joined.")
            .font(VoiidFont.footnote)
            .foregroundColor(VoiidColor.textSecondary)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do {
            card = try await CommunityService.shared.resolve(CommunityLink(handle: handle, inviteToken: nil))
            if let card, card.isMember, !savingNotificationMode {
                notificationMode = try? await CommunityService.shared.notificationPreference(communityId: card.id)
            }
        }
        catch { self.error = (error as? APIError)?.errorDescription }
    }

    /// Withdraw a pending request. Reloads rather than assuming the outcome: the manager may
    /// have approved it in the seconds before this tap, in which case the same route LEFT the
    /// community instead of cancelling a request — and the card must say which happened.
    private func cancelRequest(_ c: CommunityService.CommunityCard) async {
        busy = true; defer { busy = false }
        do {
            _ = try await CommunityService.shared.leave(communityId: c.id)
            await load()
        } catch {
            self.actionError = (error as? APIError)?.errorDescription
                ?? "Couldn\u{2019}t cancel that request."
        }
    }

    private func join(_ c: CommunityService.CommunityCard) async {
        busy = true; defer { busy = false }
        do {
            _ = try await CommunityService.shared.join(communityId: c.id, inviteToken: nil)
            await load()
        } catch {
            // A college community: prove the email, then the sheet retries this join.
            if case APIError.http(403, _, "institution_email_required") = error {
                collegeEmailCard = c
                return
            }
            self.actionError = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t join."
        }
    }
}


struct CommunityInviteView: View {
    let card: CommunityService.CommunityCard
    @Environment(\.dismiss) private var dismiss
    @State private var url: URL?
    @State private var error: String?
    @State private var invites: [CommunityService.Invite] = []
    @State private var working = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    Text(card.name).font(VoiidFont.rounded(24, .bold))
                    if let url {
                        if let image = qr(url.absoluteString) {
                            Image(uiImage: image).interpolation(.none).resizable().scaledToFit()
                                .frame(width: 240, height: 240).padding(16).background(.white)
                                .clipShape(RoundedRectangle(cornerRadius: 20))
                                .accessibilityLabel("Community invite QR code")
                        }
                        Text("Scanning opens a preview. Joining never grants an admin role.")
                            .font(VoiidFont.subhead).foregroundStyle(VoiidColor.textSecondary)
                        ShareLink(item: url) { Label("Share invite", systemImage: "square.and.arrow.up") }
                        if card.canInvite { Text("This link expires in 7 days or after 100 joins.").font(.footnote) }
                    } else if error == nil { ProgressView() }
                    if let error { Text(error).foregroundStyle(VoiidColor.error) }
                    if card.canInvite {
                        Button("Create a new link") { Task { await create() } }.disabled(working)
                    }
                    if card.isManager {
                        ForEach(invites) { invite in
                            HStack {
                                Text(invite.expires_at.map { "Expires \($0.prefix(10))" } ?? "No expiry").font(.footnote)
                                Spacer()
                                Button("Revoke", role: .destructive) {
                                    Task {
                                        working = true
                                        defer { working = false }
                                        do {
                                            try await CommunityService.shared.revokeInvite(communityId: card.id, token: invite.token)
                                            invites.removeAll { $0.token == invite.token }
                                            if url?.query?.contains(invite.token) == true { url = nil }
                                        } catch { self.error = error.localizedDescription }
                                    }
                                }.disabled(working)
                            }
                        }
                    }
                }.padding(24)
            }
            .background(VoiidColor.background)
            .navigationTitle("Community QR")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
            .task { await create() }
        }
    }
    private func create() async {
        guard !working else { return }
        working = true; error = nil
        defer { working = false }
        do {
            let token = card.canInvite ? try await CommunityService.shared.createInvite(communityId: card.id).token : nil
            url = URL(string: CommunityLink.format(handle: card.handle, inviteToken: token))
            if card.isManager { invites = try await CommunityService.shared.invites(communityId: card.id) }
        } catch { self.error = error.localizedDescription }
    }
    private func qr(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}
