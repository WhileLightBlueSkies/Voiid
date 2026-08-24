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

struct CommunityDetailView: View {
    let handle: String

    @State private var card: CommunityService.CommunityCard?
    @State private var loading = true
    @State private var error: String?
    @State private var busy = false
    @State private var showInbox = false
    @State private var tab: CommunityTab = .home
    @State private var openConversation: VConversation?

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
            if !chat.directConversations.contains(where: { $0.id == convId }) {
                await chat.loadConversations()
            }
            if let conv = chat.directConversations.first(where: { $0.id == convId }) {
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
        .task { await load() }
        .sheet(isPresented: $showInbox) { CommunityInboxView() }
        .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
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
                if isOwner(c) {
                    Text("HOST")
                        .font(VoiidFont.rounded(9.5, .bold))
                        .foregroundColor(VoiidColor.textOnAccent)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(VoiidColor.accent))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "person.2.fill").font(.system(size: 11))
                Text("\(c.members) member\(c.members == 1 ? "" : "s")")
                Text("\u{2022}")
                Image(systemName: c.policy == "open" ? "globe" : "lock.fill")
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

    private func visibilityText(_ c: CommunityService.CommunityCard) -> String {
        switch c.policy {
        case "open":     return "Anyone can join"
        case "approval": return "Approval needed"
        default:         return "Invite only"
        }
    }

    // MARK: Actions

    @ViewBuilder
    private func actions(_ c: CommunityService.CommunityCard) -> some View {
        HStack(spacing: VoiidSpacing.sm) {
            joinButton(c)

            if isOwner(c) {
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
            } else if c.isMember {
                // INVITE, not Share. Only a member can hand out a way in, and only for a
                // community whose policy allows one — see POST /communities/:id/invites.
                Button {
                    Haptics.tap()
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
            Button("Share community", systemImage: "square.and.arrow.up") {}
            Button("Notifications", systemImage: "bell") {}
            Button("Report", systemImage: "exclamationmark.triangle") {}
            if c.isMember && !isOwner(c) {
                Divider()
                Button("Leave community",
                       systemImage: "rectangle.portrait.and.arrow.right",
                       role: .destructive) {}
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

    /// Every membership state the server can put you in, said plainly. A banned account is
    /// told it cannot join rather than being shown a button that will fail, and an
    /// approval-gated community says "requested" rather than "joined" — the difference between
    /// an honest state and a lie the next screen would expose.
    @ViewBuilder
    private func joinButton(_ c: CommunityService.CommunityCard) -> some View {
        if c.isBanned {
            pill("You can\u{2019}t join", filled: false, disabled: true)
        } else if c.isMember {
            pill("Joined", icon: "checkmark", filled: true, disabled: true)
        } else if c.isPending {
            pill("Requested", filled: false, disabled: true)
        } else if c.isSuspended {
            pill("Suspended", filled: false, disabled: true)
        } else {
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
                tabBar
                Group {
                    switch tab {
                    case .home:
                        CommunityHomeTab(isAdmin: isOwner(c))
                    case .spaces:
                        CommunitySpacesTab(communityId: c.id, isAdmin: isOwner(c))
                    case .events:
                        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                            CommunityEventsSection(communityId: c.id)
                            CommunityTournamentsSection(communityId: c.id)
                        }
                    case .members:
                        CommunityMembersTab(communityId: c.id, isAdmin: isOwner(c))
                    case .about:
                        CommunityAboutTab(card: c, isAdmin: isOwner(c))
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
    private var tabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 22) {
                ForEach(CommunityTab.allCases) { option in
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
        Text("Channel messages inside a community are end-to-end encrypted. The community "
             + "itself \u{2014} its name, members and invites \u{2014} is not, so it can be searched and joined.")
            .font(VoiidFont.footnote)
            .foregroundColor(VoiidColor.textSecondary)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { card = try await CommunityService.shared.resolve(CommunityLink(handle: handle, inviteToken: nil)) }
        catch { self.error = (error as? APIError)?.errorDescription }
    }

    private func join(_ c: CommunityService.CommunityCard) async {
        busy = true; defer { busy = false }
        do {
            _ = try await CommunityService.shared.join(communityId: c.id, inviteToken: nil)
            await load()
        } catch {
            self.error = (error as? APIError)?.errorDescription ?? "Couldn\u{2019}t join."
        }
    }
}
