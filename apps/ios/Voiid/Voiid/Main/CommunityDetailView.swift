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
    @State private var openConversation: VConversation?

    @EnvironmentObject private var chat: ChatStore

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
        ScrollView {
            if let card {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    header(card)
                    if let d = card.description, !d.isEmpty {
                        Text(d)
                            .font(VoiidFont.body)
                            .foregroundColor(VoiidColor.textPrimary)
                    }
                    joinRow(card)

                    // BOTH ENDS OF THE HOST LINE, which existed in the service layer and were
                    // reachable from nowhere: `all()` had no caller and `MessageHostButton`
                    // appeared only inside a comment. A member could not start a thread and a
                    // host could not read one.
                    if isOwner(card) {
                        Button {
                            Haptics.tap()
                            showInbox = true
                        } label: {
                            HStack(spacing: VoiidSpacing.sm) {
                                Image(systemName: "tray.full")
                                Text("Host inbox")
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(VoiidColor.textSecondary)
                            }
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .padding(VoiidSpacing.md)
                            .background(VoiidColor.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                        style: .continuous))
                        }
                        .buttonStyle(.plain)
                    } else if card.isMember {
                        // The button probes first, so it says "Message host" or "Open chat"
                        // correctly rather than guessing. Non-members never see it: the
                        // endpoint refuses them, and offering it would promise what it cannot do.
                        MessageHostButton(communityId: card.id) { conversationId in
                            openHostConversation(conversationId)
                        }
                    }

                    // Members only: the endpoint 403s everyone else, and an empty section
                    // would read as "no tournaments" rather than "not visible to you".
                    if card.isMember {
                        Divider().background(VoiidColor.divider)
                        CommunityTournamentsSection(communityId: card.id)
                        Divider().background(VoiidColor.divider)
                        CommunityEventsSection(communityId: card.id)
                    }
                    Divider().background(VoiidColor.divider)
                    notice
                }
                .padding(VoiidSpacing.md)
            } else if loading {
                ProgressView().tint(VoiidColor.primary).padding(.top, 80)
            } else {
                Text(error ?? "That community doesn't exist.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(VoiidSpacing.xl)
            }
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("@" + handle)
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .sheet(isPresented: $showInbox) { CommunityInboxView() }
        .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
    }

    private func header(_ c: CommunityService.CommunityCard) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            ClipThumbnail(url: c.avatar_url)
                .frame(width: 72, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(c.name ?? "@" + c.handle)
                    .font(VoiidFont.rounded(22, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("\(c.members) member\(c.members == 1 ? "" : "s") · \(c.policy)")
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.textSecondary)
            }
        }
    }

    @ViewBuilder private func joinRow(_ c: CommunityService.CommunityCard) -> some View {
        if c.isBanned {
            Text("You can\u{2019}t join this community.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
        } else if c.isMember {
            Text("You\u{2019}re a member.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
        } else if c.isPending {
            // An approval-gated community leaves you pending — saying "requested" rather than
            // "joined" is the difference between an honest state and a lie the next screen
            // would expose.
            Text("Your request is waiting for approval.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)
        } else {
            Button {
                Haptics.tap()
                Task { await join(c) }
            } label: {
                Text(c.policy == "approval" ? "Request to join" : "Join")
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(VoiidColor.primary)
                    .clipShape(Capsule())
            }
            .disabled(busy)
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
