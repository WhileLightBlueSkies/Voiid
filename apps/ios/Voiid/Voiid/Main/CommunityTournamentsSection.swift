//
//  CommunityTournamentsSection.swift
//  Voiid
//
//  Tournaments inside a community (plan item 3.22).
//
//  The backend for this shipped complete — brackets, seeding, registration, standings — and
//  neither app referenced it, so no user could tell a tournament existed. This section is
//  what makes it reachable, and it is deliberately small: list, status, register/withdraw.
//  Creating and running a bracket is an ADMIN flow with its own screens; this is the member's
//  view of one.
//
//  ── WHY IT ONLY RENDERS FOR MEMBERS ──────────────────────────────────────────────
//  The endpoint 403s a non-member rather than returning an empty list — a roster is visible
//  to the space it belongs to and not outside it. Rendering a permanently-empty section to a
//  non-member would read as "this community has no tournaments", which is a different and
//  false statement.
//

import SwiftUI

struct CommunityTournamentsSection: View {
    let communityId: String

    @State private var tournaments: [TournamentService.Tournament] = []
    @State private var loading = true
    @State private var busyId: String?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Tournaments")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            if loading {
                ProgressView().tint(VoiidColor.primary)
            } else if tournaments.isEmpty {
                Text("No tournaments yet.")
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.textSecondary)
            } else {
                ForEach(tournaments) { t in
                    row(t)
                }
            }
        }
        .task(id: communityId) { await load() }
    }

    private func row(_ t: TournamentService.Tournament) -> some View {
        HStack(spacing: VoiidSpacing.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t.name)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)
                Text(subtitle(t))
                    .font(VoiidFont.rounded(11, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
            action(t)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    private func subtitle(_ t: TournamentService.Tournament) -> String {
        var parts: [String] = []
        if let g = t.game_name { parts.append(g) }
        if let n = t.player_count {
            parts.append(t.max_players.map { "\(n)/\($0) players" } ?? "\(n) players")
        }
        if let s = t.status { parts.append(label(for: s)) }
        return parts.joined(separator: " · ")
    }

    /// The server's status vocabulary is a state machine, not display copy. Translating it
    /// here keeps the API free to name states for what they ARE rather than how they read.
    private func label(for status: String) -> String {
        switch status {
        case "draft":       return "Not open yet"
        case "registering": return "Open for entries"
        case "running":     return "In progress"
        case "finished":    return "Finished"
        case "cancelled":   return "Cancelled"
        default:            return status
        }
    }

    @ViewBuilder private func action(_ t: TournamentService.Tournament) -> some View {
        // Registration is only offered while the server would actually accept it. Every other
        // state gets no button rather than a button that 409s — an affordance that always
        // fails is worse than no affordance.
        if t.status == "registering" {
            let joined = t.registered ?? false
            Button {
                Haptics.tap()
                Task { await toggle(t, joined: joined) }
            } label: {
                Text(joined ? "Withdraw" : "Register")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(joined ? VoiidColor.textSecondary : VoiidColor.textOnPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(joined ? Color.clear : VoiidColor.primary)
                    .overlay(
                        Capsule().stroke(VoiidColor.textSecondary.opacity(joined ? 0.4 : 0),
                                         lineWidth: 1)
                    )
                    .clipShape(Capsule())
            }
            .buttonStyle(.plain)
            .disabled(busyId == t.id)
        }
    }

    private func toggle(_ t: TournamentService.Tournament, joined: Bool) async {
        busyId = t.id
        defer { busyId = nil }
        // Capacity and the registration window belong to the server — several people may be
        // racing for the last slot — so the result is re-read rather than assumed. A refusal
        // simply leaves the list showing what is actually true.
        do {
            if joined {
                try await TournamentService.shared.withdraw(id: t.id)
            } else {
                try await TournamentService.shared.register(id: t.id)
            }
        } catch {
            // Fall through to the reload: it will show the real state either way.
        }
        await load()
    }

    private func load() async {
        loading = tournaments.isEmpty
        defer { loading = false }
        // A 403 here means "not a member", which the parent already knows — it only renders
        // this section for members. Any other failure leaves the last good list in place.
        tournaments = (try? await TournamentService.shared.list(communityId: communityId))
            ?? tournaments
    }
}
