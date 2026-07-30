//
//  GamesHomeView.swift
//  Voiid
//
//  The Games tab — a 2-per-row grid of large artwork cards.
//
//  WHY THE LIST IS SERVER-DRIVEN: the catalog lives in Postgres (`games`, seeded by
//  024_games.sql) and carries an `enabled` flag, so a broken game can be pulled without an
//  app update. A hardcoded client list would make that impossible.
//
//  ARTWORK: each row's `icon_key` maps to an asset name (`game_tictactoe`, `game_rps`).
//  Looked up by NAME at runtime rather than a compile-time reference, so adding a game is a
//  DB row plus a drop-in asset — no client change. A game whose art hasn't shipped yet
//  falls back to a tinted glyph rather than an empty card, which is what makes that work.
//
//  ONE ENTRY POINT PER GAME: tapping a card asks who you're playing (friend or bot) in
//  GameSetupSheet. Practice is not a separate row, because it is the same game against a
//  different opponent — not a different thing.
//
//  Mirrors Android `GamesHomeScreen.kt`.
//

import SwiftUI

struct GamesHomeView: View {
    @EnvironmentObject var session: AppSession
    /// The chat store, for the opponent list — games are played with people you already
    /// have a conversation with.
    @EnvironmentObject var chat: ChatStore

    @State private var games: [GamesAPI.CatalogGame] = []
    @State private var loading = true
    @State private var loadFailed = false

    /// The game whose setup sheet is open. A card is a GAME; nothing exists until an
    /// opponent is chosen.
    @State private var setupGame: GamesAPI.CatalogGame?
    /// The game awaiting a FRIEND — held between "play a friend" and picking who.
    @State private var pendingSlug: PendingGame?
    /// The offline practice board: which game, at what difficulty.
    @State private var botGame: BotSession?
    @State private var openMatchId: String?
    @State private var showLeaderboard = false

    private struct PendingGame: Identifiable { let id: String }
    private struct BotSession: Identifiable {
        let id = UUID()
        let slug: String
        let level: BotDifficulty
        let skill: Double
    }

    private let api = GamesAPI()
    private let columns = [GridItem(.flexible(), spacing: VoiidSpacing.sm),
                           GridItem(.flexible(), spacing: VoiidSpacing.sm)]

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if loadFailed {
                    // An empty list and a failed fetch look identical to a user; say which.
                    VStack(spacing: VoiidSpacing.sm) {
                        Text("Couldn't load games")
                            .font(VoiidFont.rounded(17, .semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Button("Try again") { Task { await load() } }
                            .font(VoiidFont.rounded(15, .semibold))
                            .foregroundStyle(VoiidColor.primary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: VoiidSpacing.sm) {
                            ForEach(games) { game in
                                GameCard(game: game) { setupGame = game }
                            }
                        }
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.sm)
                        // Clear the tab bar, painted over the page rather than inset into it.
                        .padding(.bottom, session.tabBarHeight + VoiidSpacing.lg)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Games")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    // Standings sit behind an icon: a reference you check occasionally,
                    // not a thing you launch.
                    Button { showLeaderboard = true } label: {
                        Image(systemName: "trophy").foregroundStyle(VoiidColor.primary)
                    }
                    .accessibilityLabel("Leaderboard")
                }
            }
            .navigationDestination(isPresented: $showLeaderboard) {
                LeaderboardView { showLeaderboard = false }
            }
            .navigationDestination(item: $openMatchId) { id in
                TicTacToeView(matchId: id) { openMatchId = nil }
                    .environmentObject(session)
            }
            .navigationDestination(item: $botGame) { s in
                // Which renderer runs is chosen by slug — the same key the server's rules
                // modules use.
                Group {
                    if s.slug == "rps" {
                        RpsBotView(level: s.level, skill: s.skill) { botGame = nil }
                    } else {
                        TicTacToeBotView(level: s.level, skill: s.skill) { botGame = nil }
                    }
                }
                .environmentObject(session)
            }
            .sheet(item: $setupGame) { game in
                GameSetupSheet(
                    gameName: game.name,
                    onPlayFriend: { pendingSlug = PendingGame(id: game.slug) },
                    onPlayBot: { level, skill in
                        botGame = BotSession(slug: game.slug, level: level, skill: skill)
                    })
            }
            .sheet(item: $pendingSlug) { pending in
                OpponentPickerSheet(conversations: chat.directConversations) { peerUserId in
                    Task { await startMatch(slug: pending.id, opponentId: peerUserId) }
                }
            }
        }
        .task { await load() }
        // A ROOT tab, so it claims the bar exactly like ChatsHomeView does.
        .onAppear { session.hideTabBar = false }
    }

    /// Create the match, then open the board on the id the server minted.
    private func startMatch(slug: String, opponentId: String) async {
        if let id = await GamesEngine.shared.create(slug: slug, opponentId: opponentId) {
            openMatchId = id
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        do { games = try await api.catalog() } catch { loadFailed = true }
        loading = false
    }
}

/// One artwork card. Dips under the finger and springs back — the same bouncy language as
/// the game boards.
private struct GameCard: View {
    let game: GamesAPI.CatalogGame
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 0) {
                ZStack {
                    Rectangle().fill(VoiidColor.primary.opacity(0.10))

                    if let key = game.icon_key, UIImage(named: key) != nil {
                        Image(key)
                            .resizable()
                            .scaledToFill()
                        // Keeps the title legible over arbitrary artwork — without it a
                        // light image and light text collide.
                        LinearGradient(
                            stops: [.init(color: .clear, location: 0.55),
                                    .init(color: .black.opacity(0.45), location: 1)],
                            startPoint: .top, endPoint: .bottom)
                    } else {
                        // Art hasn't shipped yet — a tinted glyph, never an empty card.
                        Image(systemName: game.slug == "rps" ? "hand.raised" : "number.square")
                            .font(.system(size: 40, weight: .regular))
                            .foregroundStyle(VoiidColor.primary)
                    }
                }
                // 4:3 — the aspect the shipped artwork is authored at.
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipped()

                VStack(alignment: .leading, spacing: 2) {
                    Text(game.name)
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .lineLimit(2)
                    Text("\(game.min_players)–\(game.max_players) players")
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VoiidSpacing.sm)
            }
            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.surfaceCard))
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg))
        }
        .buttonStyle(BouncyCardStyle())
    }
}

private struct BouncyCardStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.55), value: configuration.isPressed)
    }
}
