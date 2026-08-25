//
//  LeaderboardView.swift
//  Voiid
//
//  Who has beaten whom, among people you actually play (docs/GAMES.md §3).
//
//  ONLY REFEREED MATCHES COUNT. Every row comes from `game_match_results`, written by the
//  games service when a real match ended — practice wins against the local bot are
//  deliberately excluded, because a client-reported score is an unverifiable claim and this
//  board is the one place in the feature where the number has to mean something.
//
//  Ranked by wins, then games played. Draws are shown separately rather than folded into
//  losses: Tic Tac Toe draws constantly, and calling a draw a loss would make almost
//  everyone look worse than they are.
//
//  Mirrors Android `LeaderboardScreen.kt`.
//

import SwiftUI

struct LeaderboardView: View {
    var onClose: (() -> Void)?

    @State private var rows: [GamesAPI.LeaderboardRow] = []
    @State private var loading = true
    @State private var failed = false

    private let api = GamesAPI()

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if loading {
                    ProgressView()
                } else if failed {
                    VStack(spacing: VoiidSpacing.sm) {
                        Text("Couldn't load the leaderboard")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Button("Try again") { Task { await load() } }
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                } else if rows.isEmpty {
                    Text("Play a friend to start a record. Practice games don't count here.")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoiidSpacing.lg)
                } else {
                    ScrollView {
                        LazyVStack(spacing: VoiidSpacing.sm) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                                LeaderRow(rank: i + 1, row: row)
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
        // This used to hide the navigation bar and draw its own chevron. That looked the
        // same and behaved worse: a `Button` with a bare `Image` has the glyph's hit area
        // rather than the platform's 44pt target, and hiding the bar takes the INTERACTIVE
        // SWIPE-BACK GESTURE with it — the way most people actually leave a pushed screen.
        //
        // The system's back button restores both, plus its label, its press feedback and
        // its VoiceOver announcement, none of which are written here.
        .navigationTitle("Leaderboard")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    /// EMPTY, deliberately. The title and the back button are the navigation bar's now —
    /// see the note on `body`. Kept as a zero-height view rather than deleted so the call
    /// site's layout arithmetic is untouched.
    private var header: some View { EmptyView() }

    private func load() async {
        loading = true
        failed = false
        do { rows = try await api.leaderboard() } catch { failed = true }
        loading = false
    }
}

private struct LeaderRow: View {
    let rank: Int
    let row: GamesAPI.LeaderboardRow

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            ZStack {
                Circle()
                    .fill(rank == 1 ? VoiidColor.primary : VoiidColor.primary.opacity(0.12))
                    .frame(width: 36, height: 36)
                Text("\(rank)")
                    .font(VoiidFont.rounded(14, .bold))
                    .foregroundStyle(rank == 1 ? VoiidColor.textOnPrimary : VoiidColor.primary)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(row.displayName)
                    .font(VoiidFont.rounded(16, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Text("\(row.played) played")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
            }

            Spacer()

            // W / D / L from the CALLER's point of view — "wins" is how many times you beat
            // this person, which is the number people actually argue about.
            HStack(spacing: VoiidSpacing.md) {
                tally("W", row.wins, VoiidColor.success)
                tally("D", row.draws, VoiidColor.textSecondary)
                tally("L", row.losses, VoiidColor.error)
            }
        }
        .padding(VoiidSpacing.md)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
        // First place swells slightly — reads as first without a trophy competing with the
        // numbers.
        .scaleEffect(rank == 1 ? 1.02 : 1)
    }

    private func tally(_ label: String, _ value: Int, _ color: Color) -> some View {
        VStack(spacing: 1) {
            Text("\(value)")
                .font(VoiidFont.rounded(16, .bold))
                .foregroundStyle(color)
            Text(label)
                .font(VoiidFont.rounded(10, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }
}
