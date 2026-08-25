//
//  TournamentDetailView.swift
//  Voiid
//
//  One tournament, in full: the field, the standings, the fixtures, and — for a host — Start
//  and Cancel.
//
//  ── STANDINGS AND FIXTURES ARE FOR EVERYONE ─────────────────────────────────────
//  `GET /tournaments/:id/standings` and `/matches` need only membership, and the fixture list
//  is THE WAY A PLAYER LEARNS THEY HAVE A MATCH: there is deliberately no bracket invite,
//  because two strangers drawn against each other in round 2 have no Double Ratchet session
//  and no right to open one. So this screen is not a host screen with a member's view bolted
//  on — it is the member's screen, and the host's two buttons appear inside it.
//
//  ── THE HOST CONTROLS ARE A CONVENIENCE, NOT THE GATE ───────────────────────────
//  `start` and `cancel` are gated on the server by `communityAccess(..., needsAdmin: true)`.
//  `isHost` here only decides whether the buttons are drawn. A member who called the endpoint
//  anyway gets a 403; nothing in this file is load-bearing for authorisation.
//
//  ── THE LIFECYCLE, EXACTLY AS 031 CONSTRAINS IT ─────────────────────────────────
//      open ──start──▶ active ──(the referee finishes it)──▶ finished
//       └──────────cancel───────┴──cancel──▶ cancelled
//  A tournament is never "finished" by this client: the referee in backend/games writes that,
//  along with `winner_user_id`. Start refuses a field of fewer than two, and cancel refuses
//  anything already finished or cancelled — both with a 409, both re-read rather than
//  predicted here.
//

import SwiftUI

struct TournamentDetailView: View {
    let tournament: TournamentService.Tournament
    /// Whether to draw the host controls. See the header: this is presentation, not
    /// authorisation.
    let isHost: Bool
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss

    private enum Pane: String, CaseIterable, Identifiable {
        case standings = "Standings"
        case fixtures = "Fixtures"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .standings
    @State private var current: TournamentService.Tournament

    @State private var standings: [TournamentService.Standing] = []
    @State private var winnerId: String?
    @State private var matches: [TournamentService.Match] = []
    /// Loading and failure are tracked separately from emptiness: a failed fetch must never
    /// render as an empty table, which would say the tournament has no players.
    @State private var loading = true
    @State private var failed = false

    @State private var busy = false
    @State private var actionError: String?
    @State private var confirmCancel = false
    @State private var confirmStart = false

    init(tournament: TournamentService.Tournament,
         isHost: Bool,
         onChange: @escaping () -> Void = {}) {
        self.tournament = tournament
        self.isHost = isHost
        self.onChange = onChange
        _current = State(initialValue: tournament)
    }

    private var status: String { current.status ?? "open" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader(current.name,
                                    subtitle: headerSubtitle,
                                    badge: statusBadge)

                if isHost { hostControls }

                panePicker

                switch pane {
                case .standings: standingsCard
                case .fixtures:  fixturesCard
                }

                if let actionError {
                    Text(actionError)
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.error)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.sm)
            .padding(.bottom, VoiidSpacing.xl)
        }
        .voiidSettingsPage()
        .task(id: current.id) { await load() }
        .confirmationDialog("Start this tournament?",
                            isPresented: $confirmStart,
                            titleVisibility: .visible) {
            Button("Start and seed the bracket") {
                Haptics.rigid()
                Task { await start() }
            }
            Button("Not yet", role: .cancel) {}
        } message: {
            Text("Registration closes and the bracket is seeded in the order people "
               + "registered. Nobody can join after this, and it can't be undone.")
        }
        .confirmationDialog("Cancel this tournament?",
                            isPresented: $confirmCancel,
                            titleVisibility: .visible) {
            Button("Cancel tournament", role: .destructive) {
                Haptics.rigid()
                Task { await cancel() }
            }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text("Matches that have already been played stay on everyone's record \u{2014} "
               + "they happened. This can't be reversed.")
        }
    }

    // MARK: Header

    private var headerSubtitle: String {
        var parts: [String] = []
        if let g = current.game_name { parts.append(g) }
        if let f = current.format {
            parts.append(TournamentService.Format(rawValue: f)?.title ?? f)
        }
        if let n = current.player_count {
            parts.append(current.max_players.map { "\(n)/\($0) players" } ?? "\(n) players")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    private var statusBadge: (icon: String, text: String)? {
        switch status {
        case "open":      return ("person.badge.plus", "Open for entries")
        case "active":    return ("flag.checkered", "In progress")
        case "finished":  return ("trophy", "Finished")
        case "cancelled": return ("xmark.circle", "Cancelled")
        default:          return nil
        }
    }

    // MARK: Host controls

    @ViewBuilder private var hostControls: some View {
        VoiidCardSection("Hosting", footer: controlsFooter) {
            if status == "open" {
                VoiidSettingsRow(icon: "play.circle",
                                 title: "Start tournament",
                                 detail: "Close entries and seed the bracket.") {
                    Haptics.tap()
                    confirmStart = true
                } trailing: {
                    if busy { ProgressView().tint(VoiidColor.accent) } else { VoiidChevron() }
                }
                VoiidRowDivider()
            }

            if status == "open" || status == "active" {
                VoiidSettingsRow(icon: "xmark.circle",
                                 title: "Cancel tournament",
                                 destructive: true) {
                    Haptics.tap()
                    confirmCancel = true
                }
            } else {
                VoiidSettingsRow(icon: "checkmark.seal",
                                 title: status == "finished" ? "This tournament is finished"
                                                             : "This tournament was cancelled")
            }
        }
        .disabled(busy)
    }

    private var controlsFooter: String {
        switch status {
        case "open":
            return "Seeds are assigned in registration order, so you can always explain why "
                 + "somebody drew who they drew. A bracket needs at least two players."
        case "active":
            return "Voiid finishes a tournament on its own when the last match is played."
        default:
            return "Nothing left to run. Create a new tournament to play again."
        }
    }

    // MARK: Panes

    private var panePicker: some View {
        Picker("View", selection: $pane) {
            ForEach(Pane.allCases) { p in Text(p.rawValue).tag(p) }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder private var standingsCard: some View {
        if loading {
            loadingCard("Standings")
        } else if failed {
            failureCard("Standings")
        } else if standings.isEmpty {
            VoiidCardSection("Standings",
                             footer: status == "open"
                                   ? "Everyone who registers appears here, on zero points."
                                   : nil) {
                VoiidSettingsRow(icon: "person.badge.clock", title: "Nobody has registered yet")
            }
        } else {
            VoiidCardSection("Standings",
                             footer: "Points, then score, then wins. Everyone in the field is "
                                   + "listed \u{2014} a player with no result yet sits on zero.") {
                ForEach(Array(standings.enumerated()), id: \.element.id) { index, s in
                    if index > 0 { VoiidRowDivider() }
                    VoiidSettingsRow(icon: rowIcon(for: s, at: index),
                                     title: s.display,
                                     detail: standingDetail(s)) {
                        Text("\(s.points ?? 0)")
                            .font(.subheadline.weight(.semibold).monospacedDigit())
                            .foregroundStyle(VoiidColor.accentInk)
                    }
                }
            }
        }
    }

    private func rowIcon(for s: TournamentService.Standing, at index: Int) -> String {
        if let w = winnerId, w == s.user_id { return "trophy" }
        if s.state == "withdrawn" { return "person.slash" }
        return index == 0 ? "crown" : "person"
    }

    private func standingDetail(_ s: TournamentService.Standing) -> String {
        var parts: [String] = []
        if s.state == "withdrawn" { parts.append("Withdrawn") }
        if let r = s.eliminated_in_round { parts.append("Out in round \(r)") }
        let played = s.played ?? 0
        if played > 0 {
            parts.append("\(s.wins ?? 0)W \(s.draws ?? 0)D \(s.losses ?? 0)L")
        } else if let seed = s.seed {
            parts.append("Seed \(seed)")
        } else {
            parts.append("No matches yet")
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder private var fixturesCard: some View {
        if loading {
            loadingCard("Fixtures")
        } else if failed {
            failureCard("Fixtures")
        } else if matches.isEmpty {
            VoiidCardSection("Fixtures",
                             footer: status == "open"
                                   ? "The bracket is drawn when the host starts it."
                                   : nil) {
                VoiidSettingsRow(icon: "square.grid.3x3", title: "No fixtures yet")
            }
        } else {
            // Grouped by round rather than one flat list: a bracket IS rounds, and reading it
            // as a stream loses the only structure it has.
            ForEach(rounds, id: \.self) { round in
                let inRound = matches.filter { ($0.round ?? 0) == round }
                VoiidCardSection("Round \(round)") {
                    ForEach(Array(inRound.enumerated()), id: \.element.id) { index, m in
                        if index > 0 { VoiidRowDivider() }
                        VoiidSettingsRow(icon: fixtureIcon(m),
                                         title: fixtureTitle(m),
                                         detail: fixtureDetail(m))
                    }
                }
            }
        }
    }

    private var rounds: [Int] {
        Array(Set(matches.map { $0.round ?? 0 })).sorted()
    }

    private func fixtureIcon(_ m: TournamentService.Match) -> String {
        if m.isBye { return "arrow.forward.circle" }
        if m.status == "finished" { return "checkmark.circle" }
        if m.mine == true { return "person.crop.circle.badge.exclamationmark" }
        return "gamecontroller"
    }

    private func fixtureTitle(_ m: TournamentService.Match) -> String {
        // A one-player row is a bye or the remains of a walkover. The server marks it and the
        // client renders it as a free pass — never as a game somebody could join.
        if m.isBye { return "Bye" }
        return m.mine == true ? "Your match" : "Match \((m.slot ?? 0) + 1)"
    }

    private func fixtureDetail(_ m: TournamentService.Match) -> String {
        var parts: [String] = []
        switch m.status {
        case "pending":   parts.append("Not started")
        case "active":    parts.append("Being played")
        case "finished":  parts.append("Finished")
        case "abandoned": parts.append("Abandoned")
        case .some(let s): parts.append(s)
        case .none: break
        }
        if let w = m.winner_id, let name = name(for: w) { parts.append("\(name) won") }
        if let when = m.ended_at.flatMap(VoiidEventDate.display) { parts.append(when) }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// Names come off the standings, which is the one place this screen has any — the matches
    /// endpoint returns ids only, and there is no fabricating a name that was never sent.
    private func name(for userId: String) -> String? {
        standings.first(where: { $0.user_id == userId })?.display
    }

    private func loadingCard(_ header: String) -> some View {
        VoiidCardSection(header) {
            HStack(spacing: VoiidSpacing.md) {
                ProgressView().tint(VoiidColor.accent)
                Text("Loading\u{2026}")
                    .font(.body)
                    .foregroundStyle(VoiidColor.textSecondary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, 11)
        }
    }

    private func failureCard(_ header: String) -> some View {
        VoiidCardSection(header) {
            VoiidSettingsRow(icon: "arrow.clockwise",
                             title: "Couldn't load this",
                             detail: "Tap to try again.") {
                Haptics.tap()
                Task { await load() }
            }
        }
    }

    // MARK: Loading and actions

    private func load() async {
        loading = standings.isEmpty && matches.isEmpty
        failed = false
        defer { loading = false }
        do {
            // Both, together: the fixtures name people by id and the standings are the only
            // place their names arrive, so half a load is a fixture list of raw uuids.
            async let table = TournamentService.shared.standings(id: current.id)
            async let fixtures = TournamentService.shared.matches(id: current.id)
            let (t, f) = try await (table, fixtures)
            standings = t.standings ?? []
            winnerId = t.winner_user_id
            matches = f
            // Refresh the card too, so a status changed by somebody else shows up here.
            if let fresh = try? await TournamentService.shared.detail(id: current.id).tournament {
                current = fresh
            }
        } catch {
            failed = true
        }
    }

    private func start() async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await TournamentService.shared.start(id: current.id)
            Haptics.success()
            onChange()
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func cancel() async {
        busy = true
        actionError = nil
        defer { busy = false }
        do {
            try await TournamentService.shared.cancel(id: current.id)
            Haptics.success()
            onChange()
            await load()
        } catch {
            actionError = error.localizedDescription
        }
    }
}
