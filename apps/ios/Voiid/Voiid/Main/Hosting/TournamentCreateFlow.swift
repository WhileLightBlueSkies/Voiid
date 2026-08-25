//
//  TournamentCreateFlow.swift
//  Voiid
//
//  Creating a tournament — three steps, in the same one-sheet shape as `CommunityCreateFlow`
//  and `EventCreateFlow`.
//
//  ── A TOURNAMENT IS AN ORGANISING LAYER, NOT A SECOND GAMES STACK ────────────────
//  Every fixture it produces is an ordinary `game_matches` row with four extra columns. So
//  the game picker here is the ORDINARY CATALOG, filtered to the games that can seat exactly
//  two people — the route refuses anything else with a 400, because pairing is 1v1 all the
//  way down the bracket.
//
//  ── THE ID IS MINTED HERE ───────────────────────────────────────────────────────
//  `POST /communities/:id/tournaments` takes a client-supplied uuid as its RETRY KEY, and
//  this flow supplies one that survives a retry. A create whose response was lost then lands
//  on its own row instead of leaving a second, empty bracket on the community's list.
//
//  ── NOTHING STARTS ITSELF ───────────────────────────────────────────────────────
//  `starts_at` is ADVISORY: the server has no scheduler and says so. A bracket is seeded only
//  when a host presses Start, so this screen calls the field "Planned start" and the created
//  tournament opens for registration rather than counting down to anything.
//

import SwiftUI
import Combine

// MARK: - Draft

final class TournamentDraftModel: ObservableObject {
    enum Step: Int, CaseIterable, Identifiable {
        case game, format, when
        var id: Int { rawValue }

        var title: String {
            switch self {
            case .game:   "Game"
            case .format: "Format"
            case .when:   "Start"
            }
        }

        var heading: String {
            switch self {
            case .game:   "What are they playing?"
            case .format: "How does it run?"
            case .when:   "When does it start?"
            }
        }

        var subheading: String {
            switch self {
            case .game:   "One-against-one games only — every round of a bracket is a pair."
            case .format: "Both fill up in registration order. You seed it when you start it."
            case .when:   "A planned time is a note to your players. Nothing starts on its own."
            }
        }
    }

    /// Minted once, at construction, and reused across every retry of the create call.
    let id = UUID().uuidString.lowercased()

    @Published var name = ""
    @Published var gameSlug: String?
    @Published var format: TournamentService.Format = .single_elim {
        didSet {
            // The ceiling is format-dependent, so a switch from single-elim to round robin has
            // to pull a 32-player field down to 16 rather than let it be 400ed at create.
            if maxPlayers > format.maxPlayers { maxPlayers = format.maxPlayers }
        }
    }
    @Published var maxPlayers = TournamentService.Format.single_elim.defaultPlayers
    @Published var hasPlannedStart = false
    @Published var plannedStart: Date = Date().addingTimeInterval(7 * 24 * 3600)

    /// The route's own rule: 1–60 characters after trimming.
    var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    var nameValid: Bool { !trimmedName.isEmpty && trimmedName.count <= 60 }

    func canContinue(_ step: Step) -> Bool {
        switch step {
        case .game:   return nameValid && gameSlug != nil
        case .format: return maxPlayers >= 2 && maxPlayers <= format.maxPlayers
        case .when:   return true
        }
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    var startsAtISO: String? {
        hasPlannedStart ? Self.iso.string(from: plannedStart) : nil
    }
}

// MARK: - Flow

struct TournamentCreateFlow: View {
    let communityId: String
    var onCreate: (TournamentService.Tournament) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @StateObject private var draft = TournamentDraftModel()
    @State private var step: TournamentDraftModel.Step = .game
    @State private var creating = false
    @State private var createError: String?

    /// The catalog has its own three states, and they are kept apart: a failed fetch must not
    /// render as "no games", which would be a different and false statement.
    @State private var games: [GamesAPI.CatalogGame] = []
    @State private var catalogLoading = true
    @State private var catalogFailed = false

    private var stepIndex: Int { step.rawValue }
    private var isLast: Bool { step == .when }

    /// Two seats exactly. The route checks the same thing against the `games` row and 400s a
    /// game that cannot be played one-against-one; filtering here means the picker never
    /// offers one.
    private var eligible: [GamesAPI.CatalogGame] {
        games.filter { $0.min_players <= 2 && $0.max_players >= 2 }
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    progressBar

                    ScrollView {
                        VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                            heading

                            switch step {
                            case .game:   gameStep
                            case .format: formatStep
                            case .when:   whenStep
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.md)
                        .padding(.bottom, VoiidSpacing.xl)
                    }
                    .scrollIndicators(.hidden)

                    if let createError {
                        Text(createError)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                            .multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, VoiidSpacing.md)
                            .padding(.bottom, VoiidSpacing.xs)
                    }

                    footer
                }
            }
            .navigationTitle("New Tournament")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { Haptics.tap(); dismiss() }
                        .tint(VoiidColor.textSecondary)
                }
            }
            .task { await loadCatalog() }
        }
    }

    // MARK: Chrome

    private var progressBar: some View {
        VStack(spacing: 6) {
            HStack(spacing: 5) {
                ForEach(TournamentDraftModel.Step.allCases) { s in
                    Capsule()
                        .fill(s.rawValue <= stepIndex ? VoiidColor.accent : VoiidColor.divider)
                        .frame(height: 3)
                }
            }

            HStack {
                Text("Step \(stepIndex + 1) of \(TournamentDraftModel.Step.allCases.count)")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer(minLength: 0)
                Text(step.title)
                    .font(VoiidFont.rounded(11.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
        .animation(.easeOut(duration: 0.22), value: stepIndex)
    }

    private var heading: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(step.heading)
                .font(VoiidFont.rounded(23, .bold))
                .foregroundColor(VoiidColor.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(step.subheading)
                .font(VoiidFont.rounded(14))
                .foregroundColor(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack(spacing: VoiidSpacing.sm) {
            if stepIndex > 0 {
                Button {
                    Haptics.tap()
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = TournamentDraftModel.Step(rawValue: stepIndex - 1) ?? .game
                    }
                } label: {
                    Text("Back")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: 46)
                        .background(Capsule().fill(VoiidColor.surfaceCard))
                        .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(creating)
            }

            Button {
                Haptics.tap()
                if isLast {
                    Task { await create() }
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        step = TournamentDraftModel.Step(rawValue: stepIndex + 1) ?? .when
                    }
                }
            } label: {
                HStack(spacing: 7) {
                    if creating { ProgressView().tint(VoiidColor.textOnAccent) }
                    Text(isLast ? "Open registration" : "Continue")
                        .font(VoiidFont.rounded(15, .semibold))
                }
                .foregroundColor(VoiidColor.textOnAccent)
                .frame(maxWidth: .infinity).frame(height: 46)
                .background(Capsule().fill(VoiidColor.accent))
            }
            .buttonStyle(.plain)
            .disabled(creating || !draft.canContinue(step))
            .opacity(draft.canContinue(step) ? 1 : 0.5)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
    }

    // MARK: Step 1 — name and game

    private var gameStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Tournament name")
                    .font(VoiidFont.rounded(12.5, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                TextField("Friday Night Chess", text: $draft.name)
                    .font(VoiidFont.rounded(15))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 12)
                    .background(VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                        .stroke(VoiidColor.divider, lineWidth: 1))
            }

            if draft.trimmedName.count > 50 {
                Text("\(draft.trimmedName.count)/60")
                    .font(VoiidFont.rounded(11.5))
                    .foregroundColor(draft.trimmedName.count > 60
                                     ? VoiidColor.error : VoiidColor.textSecondary)
            }

            // Three distinct states. A failed fetch is never rendered as an empty catalog.
            if catalogLoading {
                VoiidCardSection("Game") {
                    HStack(spacing: VoiidSpacing.md) {
                        ProgressView().tint(VoiidColor.accent)
                        Text("Loading games\u{2026}")
                            .font(.body)
                            .foregroundStyle(VoiidColor.textSecondary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)
                }
            } else if catalogFailed {
                VoiidCardSection("Game") {
                    VoiidSettingsRow(icon: "arrow.clockwise",
                                     title: "Couldn't load the games",
                                     detail: "Tap to try again.") {
                        Haptics.tap()
                        Task { await loadCatalog() }
                    }
                }
            } else if eligible.isEmpty {
                VoiidCardSection("Game",
                                 footer: "A bracket pairs two players in every round, so a "
                                       + "game has to seat exactly two.") {
                    VoiidSettingsRow(icon: "gamecontroller",
                                     title: "No one-against-one games available")
                }
            } else {
                VoiidCardSection("Game") {
                    ForEach(Array(eligible.enumerated()), id: \.element.id) { index, game in
                        if index > 0 { VoiidRowDivider() }
                        let selected = draft.gameSlug == game.slug
                        VoiidSettingsRow(icon: "gamecontroller", title: game.name) {
                            Haptics.selection()
                            draft.gameSlug = game.slug
                        } trailing: {
                            if selected {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundStyle(VoiidColor.accentInk)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Step 2 — format and size

    private var formatStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VoiidCardSection("Format") {
                ForEach(Array(TournamentService.Format.allCases.enumerated()), id: \.element.id) { index, f in
                    if index > 0 { VoiidRowDivider() }
                    VoiidSettingsRow(icon: f == .single_elim ? "flag.checkered" : "arrow.triangle.2.circlepath",
                                     title: f.title,
                                     detail: f.detail) {
                        Haptics.selection()
                        withAnimation(.easeOut(duration: 0.18)) { draft.format = f }
                    } trailing: {
                        if draft.format == f {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(VoiidColor.accentInk)
                        }
                    }
                }
            }

            VoiidCardSection("Size",
                             footer: "Registration closes when it's full, or when you start "
                                   + "it. Players are seeded in the order they registered.") {
                Stepper(value: $draft.maxPlayers, in: 2...draft.format.maxPlayers, step: 2) {
                    Text("Up to \(draft.maxPlayers) players")
                        .font(.body)
                        .foregroundStyle(VoiidColor.textPrimary)
                }
                .tint(VoiidColor.accent)
                .padding(.horizontal, VoiidSpacing.md)
                .padding(.vertical, 11)
            }
        }
    }

    // MARK: Step 3 — planned start

    private var whenStep: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            VoiidCardSection("Planned start",
                             footer: "Voiid has no scheduler, so this is a note to your "
                                   + "players and nothing more. The bracket is seeded the "
                                   + "moment you press Start, and not before.") {
                Toggle("Announce a start time",
                       isOn: $draft.hasPlannedStart.animation(.easeOut(duration: 0.18)))
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .tint(VoiidColor.accent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 11)

                if draft.hasPlannedStart {
                    VoiidRowDivider(inset: VoiidSpacing.md)
                    DatePicker("Planned start", selection: $draft.plannedStart)
                        .datePickerStyle(.compact)
                        .labelsHidden()
                        .tint(VoiidColor.accent)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, 11)
                }
            }

            VoiidCardSection("Summary") {
                VoiidSettingsRow(icon: "trophy",
                                 title: draft.trimmedName.isEmpty ? "Untitled" : draft.trimmedName,
                                 detail: summary)
            }
        }
    }

    private var summary: String {
        var parts: [String] = []
        if let slug = draft.gameSlug,
           let game = eligible.first(where: { $0.slug == slug }) {
            parts.append(game.name)
        }
        parts.append(draft.format.title)
        parts.append("up to \(draft.maxPlayers)")
        return parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Loading and create

    private func loadCatalog() async {
        catalogLoading = true
        catalogFailed = false
        defer { catalogLoading = false }
        do {
            games = try await GamesAPI().catalog()
            // Pre-select when there is only one real answer — a picker with one row is a
            // decision the user does not have to be asked to make.
            if draft.gameSlug == nil, eligible.count == 1 { draft.gameSlug = eligible[0].slug }
        } catch {
            catalogFailed = true
        }
    }

    private func create() async {
        guard let slug = draft.gameSlug else { return }
        creating = true
        createError = nil
        defer { creating = false }
        do {
            let t = try await TournamentService.shared.create(
                communityId: communityId,
                id: draft.id,
                gameSlug: slug,
                name: draft.trimmedName,
                format: draft.format,
                maxPlayers: draft.maxPlayers,
                startsAt: draft.startsAtISO)
            Haptics.success()
            if let t { onCreate(t) }
            dismiss()
        } catch {
            createError = error.localizedDescription
        }
    }
}
