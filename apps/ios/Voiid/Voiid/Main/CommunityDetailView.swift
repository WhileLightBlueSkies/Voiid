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
