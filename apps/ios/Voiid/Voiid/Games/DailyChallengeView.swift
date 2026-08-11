//
//  DailyChallengeView.swift
//  Voiid
//
//  One seeded Snake arena a day, the same for everyone (docs/games/CROSS_CUTTING.md §5,
//  SNAKE_COMPETITIVE_PARITY.md §4 P3.8).
//
//  THE COMPETITOR'S VERSION IS A LUCKY WHEEL AND A COIN BALANCE. Ours is neither. Their
//  `LuckyWheel`/`ChallengeMetric` cluster exists to make a player open an ad-funded app once a
//  day; the reward is currency, and the currency exists to be bought. Voiid is a messenger, and
//  a free-to-play economy bolted onto a chat app would change what the product is.
//
//  What survives that cut is the part that was never about money: everyone plays the SAME arena
//  today, so a score is finally comparable. That is one seed and one query.
//
//  THE BOARD IS GLOBAL, unlike `LeaderboardView`, and that is not an inconsistency. The ordinary
//  board is scoped to people you have actually played, because a global ranking of a two-player
//  game is a list of strangers you cannot challenge. The daily is the opposite: the comparison
//  is meaningful precisely BECAUSE everyone faced the same food layout and the same bots.
//
//  ONE ATTEMPT A DAY, enforced by a unique index rather than by this screen. Unlimited retries
//  would make the board a ranking of who replayed most, and let anyone behind simply grind until
//  the RNG cooperated.
//
//  Mirrors Android `DailyChallengeScreen.kt`.
//

import SwiftUI

struct DailyChallengeView: View {
    /// Opens the arena once today's run has been minted.
    var onPlay: (String) -> Void
    var onClose: (() -> Void)?

    @State private var data: GamesAPI.DailyResponse?
    @State private var loading = true
    @State private var failed = false
    @State private var starting = false

    private let api = GamesAPI()

    /// True once they have a run today, finished or not. The rule is one ATTEMPT, so a run they
    /// walked out of still counts — otherwise quitting a bad start would be a free reroll.
    private var alreadyPlayed: Bool { data?.mine != nil }

    var body: some View {
        VStack(spacing: 0) {
            header

            Group {
                if loading {
                    ProgressView()
                } else if failed {
                    VStack(spacing: VoiidSpacing.sm) {
                        Text("Couldn't load today's challenge")
                            .font(VoiidFont.rounded(16, .semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Button("Try again") { Task { await load() } }
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .task { await load() }
    }

    private var content: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.md) {
                callToAction

                if let rows = data?.leaderboard, !rows.isEmpty {
                    LazyVStack(spacing: VoiidSpacing.sm) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { i, row in
                            DailyRowView(rank: i + 1, row: row)
                        }
                    }
                } else {
                    // Says the board is empty AND why that is an opportunity. "No scores yet"
                    // alone reads as a broken screen.
                    Text("Nobody has finished today's arena yet. First score sets the mark.")
                        .font(VoiidFont.rounded(14, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoiidSpacing.lg)
                        .padding(.top, VoiidSpacing.md)
                }
            }
            .padding(.vertical, VoiidSpacing.sm)
        }
    }

    @ViewBuilder
    private var callToAction: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Everyone plays the same arena today — same food, same bots. One run each.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let mine = data?.mine {
                // Their own result, stated plainly. A player who already played needs their
                // number more than they need a disabled button explaining itself.
                HStack {
                    Image(systemName: mine.score != nil ? "checkmark.seal.fill" : "hourglass")
                        .foregroundStyle(VoiidColor.primary)
                    Text(mine.score.map { "You scored \($0). Back tomorrow." }
                         ?? "Your run is still going.")
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                }
            } else {
                Button {
                    Haptics.tap()
                    Task { await start() }
                } label: {
                    Group {
                        if starting {
                            ProgressView().tint(VoiidColor.textOnPrimary)
                        } else {
                            Text("Play today's arena")
                                .font(VoiidFont.rounded(16, .bold))
                        }
                    }
                    .foregroundStyle(VoiidColor.textOnPrimary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, VoiidSpacing.md)
                    .background(Capsule().fill(VoiidColor.primary))
                }
                .buttonStyle(.plain)
                .disabled(starting)
            }
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
    }

    private var header: some View {
        HStack {
            Button { onClose?() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
            }
            Spacer()
            Text("Daily challenge")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Spacer()
            Image(systemName: "chevron.left").opacity(0)
        }
        .padding(.vertical, VoiidSpacing.md)
    }

    private func load() async {
        loading = true
        failed = false
        do { data = try await api.daily() } catch { failed = true }
        loading = false
    }

    private func start() async {
        guard !starting, !alreadyPlayed else { return }
        starting = true
        do {
            let res = try await api.startDaily(skin: SnakeChoiceStore.skinId)
            starting = false
            onPlay(res.match_id)
        } catch {
            starting = false
            // A 409 means they already played — which is the rule, not a failure. Reloading
            // turns the button into their result rather than showing an error for working
            // correctly. Any other failure lands in the same place and the reload reports it.
            await load()
        }
    }
}

private struct DailyRowView: View {
    let rank: Int
    let row: GamesAPI.DailyRow

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

            // USERNAME FIRST on this board, where the ordinary leaderboard prefers a full name.
            // That board only ever lists people you have played; this one is global, so it puts
            // strangers' names in front of each other and a handle is the identity a player
            // chose to be public.
            Text(row.username ?? row.full_name ?? "Someone")
                .font(VoiidFont.rounded(16, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)

            Spacer()

            Text("\(row.score)")
                .font(VoiidFont.rounded(17, .bold))
                .foregroundStyle(VoiidColor.textPrimary)
        }
        .padding(VoiidSpacing.md)
        .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
        .scaleEffect(rank == 1 ? 1.02 : 1)
    }
}
