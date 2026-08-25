//
//  CommunityTournamentsSection.swift
//  Voiid
//
//  Tournaments inside a community (plan item 3.22).
//
//  The backend for this shipped complete — brackets, seeding, registration, standings — and
//  neither app referenced it, so no user could tell a tournament existed. This section is
//  what makes it reachable, and it is deliberately small: list, status, register/withdraw.
//  Creating and running a bracket is an ADMIN flow with its own screens; this section now
//  REACHES those screens for a manager.
//
//  ── THE HOST HALF IS ADDITIVE, AND IT IS NOT THE AUTHORISATION ───────────────────
//  `isHost` adds a Create button. It is presentation only: `create`, `start` and `cancel` are
//  gated on the server by `communityAccess(..., needsAdmin: true)`, so a member who reached
//  those controls would see 403s. The member's row and its Register button are unchanged.
//
//  ── EVERY ROW OPENS THE BRACKET, FOR EVERYONE ───────────────────────────────────
//  Standings and fixtures need only membership, and the fixture list is THE WAY A PLAYER
//  LEARNS THEY HAVE A MATCH — there is no bracket invite, because two strangers drawn against
//  each other have no right to open a session with one another. So tapping a row opens
//  `TournamentDetailView` for a member too; the host merely also sees Start and Cancel there.
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
    /// Whether to draw the host affordances. Defaults to false so every existing caller
    /// renders exactly the member's view it rendered before.
    var isHost: Bool = false

    @State private var tournaments: [TournamentService.Tournament] = []
    @State private var loading = true
    @State private var failed = false
    @State private var busyId: String?
    @State private var creating = false
    @State private var opened: TournamentService.Tournament?

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                Text("Tournaments")
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer(minLength: 0)
                if isHost { createButton }
            }

            if loading {
                ProgressView().tint(VoiidColor.primary)
            } else if failed {
                // A FAILED FETCH IS NOT AN EMPTY LIST. "No tournaments yet" is a claim about
                // this community that the app has no evidence for.
                retry("Couldn't load tournaments.")
            } else if tournaments.isEmpty {
                Text(isHost ? "No tournaments yet. Create the first one."
                            : "No tournaments yet.")
                    .font(VoiidFont.footnote)
                    .foregroundColor(VoiidColor.textSecondary)
            } else {
                ForEach(tournaments) { t in
                    row(t)
                }
            }
        }
        .task(id: communityId) { await load() }
        .sheet(isPresented: $creating) {
            TournamentCreateFlow(communityId: communityId) { _ in
                Task { await load() }
            }
        }
        // A SHEET, not a push: this section is rendered inside the community detail scroll
        // view and does not own a navigation stack of its own.
        .sheet(item: $opened) { t in
            NavigationStack {
                TournamentDetailView(tournament: t, isHost: isHost) {
                    Task { await load() }
                }
            }
        }
    }

    /// Host only. The server gates the create route on adminship; this button is convenience.
    private var createButton: some View {
        Button {
            Haptics.tap()
            creating = true
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                Text("Create").font(VoiidFont.rounded(13, .semibold))
            }
            .foregroundColor(VoiidColor.textOnAccent)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 6)
            .background(Capsule().fill(VoiidColor.accent))
        }
        .buttonStyle(.plain)
    }

    private func retry(_ message: String) -> some View {
        Button {
            Haptics.tap()
            Task { await load() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold))
                Text(message).font(VoiidFont.footnote)
                Text("Tap to retry.").font(VoiidFont.footnote).foregroundColor(VoiidColor.accentInk)
            }
            .foregroundColor(VoiidColor.textSecondary)
        }
        .buttonStyle(.plain)
    }

    /// The card is unchanged; it gains a tap target that opens the bracket. The Register
    /// button inside it keeps its own tap, because a nested Button wins over the row's.
    private func row(_ t: TournamentService.Tournament) -> some View {
        Button {
            Haptics.tap()
            opened = t
        } label: {
            rowBody(t)
        }
        .buttonStyle(.plain)
    }

    private func rowBody(_ t: TournamentService.Tournament) -> some View {
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
    ///
    /// CORRECTED AGAINST THE SCHEMA. This switch used to read draft/registering/running,
    /// which `tournaments_status_check` in 031_tournaments.sql has never allowed — the real
    /// vocabulary is open | active | finished | cancelled. Every branch was therefore dead:
    /// a live tournament fell through to `default` and rendered the raw string "open", and
    /// the Register button below — which tested for "registering" — could never appear.
    private func label(for status: String) -> String {
        switch status {
        case "open":      return "Open for entries"
        case "active":    return "In progress"
        case "finished":  return "Finished"
        case "cancelled": return "Cancelled"
        default:          return status
        }
    }

    @ViewBuilder private func action(_ t: TournamentService.Tournament) -> some View {
        // Registration is only offered while the server would actually accept it. Every other
        // state gets no button rather than a button that 409s — an affordance that always
        // fails is worse than no affordance.
        if t.status == "open" {
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
        failed = false
        defer { loading = false }
        // A 403 here means "not a member", which the parent already knows — it only renders
        // this section for members. Any other failure keeps the last good list if there is
        // one, and otherwise says it failed rather than claiming the community has none.
        do {
            tournaments = try await TournamentService.shared.list(communityId: communityId)
        } catch {
            failed = tournaments.isEmpty
        }
    }
}
