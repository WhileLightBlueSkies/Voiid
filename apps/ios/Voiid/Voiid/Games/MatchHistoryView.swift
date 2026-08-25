//
//  MatchHistoryView.swift
//  Voiid
//
//  What you played, who with, and how it went (docs/GAMES.md §3).
//
//  THE COMPANION TO LeaderboardView, not a replacement for it. The leaderboard answers "what
//  is my record against this person" — a standing, aggregated and permanent. This answers
//  "what happened last night", which is the question you actually have when you open the tab,
//  and the one the app could not answer at all: `GET /games/matches` had shipped on the server
//  with no client on this platform.
//
//  UNFINISHED MATCHES ARE SHOWN, and shown as themselves. The route returns every row the
//  caller appears in, waiting and abandoned included, and filtering those out would quietly
//  hide the invite you sent that nobody ever took — which is exactly the row a player goes
//  looking for. A match with no result reads as its status, never as a loss.
//
//  NAMES ARE RESOLVED, NEVER FABRICATED. The route sends `player_ids` and no display names, so
//  the opponent is looked up in `leaderboard()` (the one call that carries `full_name` /
//  `username`). A miss falls back to the word "Opponent" rather than a raw uuid: an id on
//  screen is not information, and inventing a name from nothing would be worse.
//

import SwiftUI

struct MatchHistoryView: View {
    var onClose: (() -> Void)?

    @State private var rows: [GamesAPI.MatchRow] = []
    /// user id -> display name, built from the leaderboard. Empty is a legitimate state: a
    /// player with no finished matches has no leaderboard, and every row then falls back.
    @State private var names: [String: String] = [:]
    @State private var loading = true
    @State private var failed = false

    private let api = GamesAPI()

    private var me: String? { TokenStore.shared.userId }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if loading {
                    ProgressView()
                } else if failed {
                    // A FAILED FETCH IS NOT AN EMPTY HISTORY. Rendering "no matches yet" over a
                    // dropped request tells the player their games were lost; the same
                    // distinction LeaderboardView draws, for the same reason.
                    VStack(spacing: VoiidSpacing.sm) {
                        Text("Couldn't load your matches")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Button("Try again") { Task { await load() } }
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                } else if rows.isEmpty {
                    Text("No matches yet. Challenge someone from the games tab and it'll show up here.")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoiidSpacing.lg)
                } else {
                    ScrollView {
                        LazyVStack(spacing: VoiidSpacing.sm) {
                            ForEach(rows) { row in
                                MatchHistoryRow(
                                    row: row,
                                    me: me,
                                    opponentName: opponentName(for: row))
                            }
                        }
                        .padding(.top, VoiidSpacing.sm)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        // ── THE NATIVE BAR, NOT A HAND-ROLLED ONE ───────────────────────────────────
        // Was a hidden bar plus its own chevron. That looked the same and behaved worse: the
        // hit target was the glyph rather than the platform's 44pt, and hiding the bar takes
        // the INTERACTIVE SWIPE-BACK GESTURE with it — the way most people actually leave a
        // pushed screen. Same change as LeaderboardView.
        .navigationTitle("Match history")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// EMPTY, deliberately — the title and back button belong to the navigation bar now.
    /// Kept as a zero-height view so the call site's layout arithmetic is untouched.
    private var header: some View { EmptyView() }

    private func opponentName(for row: GamesAPI.MatchRow) -> String? {
        row.opponentId(me: me).flatMap { names[$0] }
    }

    private func load() async {
        loading = true
        failed = false
        do {
            rows = try await api.matches()
        } catch {
            failed = true
            loading = false
            return
        }
        // THE NAME LOOKUP IS ALLOWED TO FAIL ON ITS OWN. It is a garnish on rows that have
        // already arrived, so a leaderboard error must not flip the screen into its failed
        // state and throw away a history we successfully fetched.
        if let board = try? await api.leaderboard() {
            names = Dictionary(
                board.map { ($0.opponent_id, $0.displayName) },
                uniquingKeysWith: { first, _ in first })
        }
        loading = false
    }
}

/// One match. Reads left to right as game, opponent, when — then the verdict, which is the
/// thing the eye is actually scanning for down the column.
private struct MatchHistoryRow: View {
    let row: GamesAPI.MatchRow
    let me: String?
    let opponentName: String?

    /// A match is only won or lost once it is FINISHED. Everything else — waiting, active,
    /// abandoned — is a state, not a result, and gets the neutral treatment: `winner_id` is
    /// null on an unfinished row for the same reason it is null on a draw, so status has to
    /// be consulted first or every abandoned game would read as a draw.
    private enum Verdict { case won, lost, draw, unfinished }

    private var verdict: Verdict {
        guard row.status == "finished" else { return .unfinished }
        guard let winner = row.winner_id else { return .draw }
        return winner == me ? .won : .lost
    }

    private var verdictLabel: String {
        switch verdict {
        case .won:  return "Won"
        case .lost: return "Lost"
        case .draw: return "Draw"
        case .unfinished:
            switch row.status {
            case "waiting":   return "Not started"
            case "active":    return "In progress"
            case "abandoned": return "Abandoned"
            default:          return "—"
            }
        }
    }

    private var verdictColor: Color {
        switch verdict {
        case .won:        return VoiidColor.success
        case .lost:       return VoiidColor.error
        case .draw:       return VoiidColor.textPrimary
        case .unfinished: return VoiidColor.textSecondary
        }
    }

    /// A GLYPH AS WELL AS A WORD, the rule MatchEndResult.Outcome follows: colour is never the
    /// only channel carrying the outcome.
    private var verdictSymbol: String {
        switch verdict {
        case .won:        return "trophy.fill"
        case .lost:       return "chevron.down.circle"
        case .draw:       return "equal.circle"
        case .unfinished: return "clock"
        }
    }

    /// Solo runs (Snake, the daily) have no second player — say so rather than leaving a gap
    /// that reads as a missing name.
    private var subtitle: String {
        let who: String
        if row.opponentId(me: me) == nil {
            who = "Solo run"
        } else {
            who = opponentName.map { "vs \($0)" } ?? "vs Opponent"
        }
        guard let when = relativeWhen else { return who }
        return "\(who) · \(when)"
    }

    /// Prefers `ended_at` — when a match FINISHED is what a player remembers, not when the
    /// invite was minted — and falls back to `created_at` for rows that never got that far.
    private var relativeWhen: String? {
        guard let date = Self.parse(row.ended_at) ?? Self.parse(row.created_at) else { return nil }
        return Self.relative.localizedString(for: date, relativeTo: Date())
    }

    /// Postgres emits fractional seconds here and `.withInternetDateTime` alone rejects them,
    /// so both shapes are tried rather than silently dropping every timestamp.
    private static func parse(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        return ISO8601DateFormatter().date(from: s)
    }

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            ZStack {
                Circle()
                    .fill(VoiidColor.primary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: verdictSymbol)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(verdictColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Text(subtitle)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            Text(verdictLabel)
                .font(VoiidFont.rounded(13, .bold))
                .foregroundStyle(verdictColor)
        }
        .padding(VoiidSpacing.md)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
        // One utterance per row, so VoiceOver does not read the game, the opponent and the
        // verdict as three unrelated fragments.
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(subtitle), \(verdictLabel)")
    }
}
