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
    /// The game awaiting a FRIEND — held between "play a friend" and picking who. Carries the
    /// whole catalog row: the invite message names the game ("Let's play Tic Tac Toe"), which
    /// needs the display name, not just the slug.
    @State private var pendingGame: GamesAPI.CatalogGame?
    /// The offline practice board: which game, at what difficulty.
    @State private var botGame: BotSession?
    /// The open online match, as id + slug. The SLUG chooses the renderer.
    @State private var openMatch: OpenMatch?
    @State private var showLeaderboard = false
    /// The snake appearance picker. Snake-only, so it lives here rather than in the shared
    /// setup sheet every game uses.
    @State private var showSkinPicker = false
    /// Sound + haptics (docs/games/CROSS_CUTTING.md §12).
    @State private var showSettings = false

    private struct OpenMatch: Identifiable, Hashable {
        let id: String
        let slug: String
    }

    /// An online cricket match waiting on its over count. Held because the length must be chosen
    /// BEFORE the match row exists — the server builds the innings from it.
    @State private var pendingCricket: PendingCricket?

    /// Incoming invites. Polled rather than pushed: an invite arrives as a chat message, and the
    /// games surface has no socket subscription of its own — a 20s poll while this tab is open is
    /// cheaper than inventing a second delivery path for a banner.
    @State private var invites: [GamesAPI.PendingInvite] = []
    /// Match ids already acknowledged this session. A MISSED invite is information you need once;
    /// without this, dismissing one would bring it straight back on the next poll.
    @State private var dismissed: Set<String> = []

    /// The lobby the CREATOR waits in after sending an invite, until the opponent joins or the
    /// invite expires.
    @State private var lobby: LobbyArgs?

    private struct PendingCricket: Identifiable {
        let id = UUID()
        let game: GamesAPI.CatalogGame
        let conversation: VConversation
    }
    private struct BotSession: Identifiable, Hashable {
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
                        // Invites sit ABOVE the catalog: an invitation is time-bound and someone is
                        // waiting on it, which makes it more urgent than browsing.
                        let visible = invites.filter { !dismissed.contains($0.match_id) }
                        if !visible.isEmpty {
                            VStack(spacing: VoiidSpacing.sm) {
                                ForEach(visible) { inv in
                                    InviteBanner(
                                        invite: inv,
                                        onAccept: {
                                            openMatch = OpenMatch(id: inv.match_id, slug: inv.slug)
                                        },
                                        onDismiss: {
                                            // Acknowledge locally at once so the banner goes
                                            // immediately, then tell the server. A failed decline is
                                            // harmless — it expires anyway.
                                            dismissed.insert(inv.match_id)
                                            Task { try? await api.decline(matchId: inv.match_id) }
                                        })
                                }
                            }
                            .padding(.horizontal, VoiidSpacing.md)
                            .padding(.top, VoiidSpacing.sm)
                        }

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
                ToolbarItem(placement: .topBarTrailing) {
                    // Sound and haptics. On the TAB rather than inside each match: it is a
                    // preference about the games, not a control for the one you happen to be
                    // in, and a player who wants silence wants it before the crowd starts.
                    Button { showSettings = true } label: {
                        Image(systemName: "slider.horizontal.3")
                            .foregroundStyle(VoiidColor.textSecondary)
                    }
                    .accessibilityLabel("Game settings")
                }
            }
            .navigationDestination(isPresented: $showLeaderboard) {
                LeaderboardView { showLeaderboard = false }
            }
            .navigationDestination(item: $openMatch) { m in
                // Renderer per game, keyed by the same slug the server's rules modules use.
                // Holding only a match id is what made every online match draw a
                // tic-tac-toe grid, RPS included.
                Group {
                    switch m.slug {
                    case "rps":     RpsMatchView(matchId: m.id) { openMatch = nil }
                    case "cricket": CricketMatchView(matchId: m.id) { openMatch = nil }
                    case "snake":
                        SnakeArenaView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            // A fresh match rather than reusing the finished one: the server
                            // drops a match's state when it ends, so there is nothing to
                            // rejoin.
                            onRestart: {
                                Task {
                                    if let id = await GamesEngine.shared.createSolo(
                                        slug: "snake",
                                        options: ["bots": 5].merging(
                                            SnakeChoiceStore.matchOptions) { a, _ in a },
                                        skin: SnakeChoiceStore.skinId) {
                                        openMatch = OpenMatch(id: id, slug: "snake")
                                    }
                                }
                            })
                    default:        TicTacToeView(matchId: m.id) { openMatch = nil }
                    }
                }
                .environmentObject(session)
            }
            .navigationDestination(item: $botGame) { s in
                // Which renderer runs is chosen by slug — the same key the server's rules
                // modules use.
                Group {
                    switch s.slug {
                    case "rps":     RpsBotView(level: s.level, skill: s.skill) { botGame = nil }
                    case "cricket": CricketBotView(level: s.level, skill: s.skill) { botGame = nil }
                    default:        TicTacToeBotView(level: s.level, skill: s.skill) { botGame = nil }
                    }
                }
                .environmentObject(session)
            }
            .sheet(isPresented: $showSettings) {
                GameSettingsSheet { showSettings = false }
                    .presentationDetents([.medium])
            }
            .sheet(isPresented: $showSkinPicker) {
                SnakeSkinPicker { showSkinPicker = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(item: $setupGame) { game in
                GameSetupSheet(
                    gameName: game.name,
                    onPlayFriend: { pendingGame = game },
                    onPlayBot: { level, skill in
                        // Snake's bots live on the SERVER, so "play a bot" mints a real
                        // one-seat match rather than opening a local simulation. Every other
                        // game here is turn-based and simulates its opponent on-device.
                        if game.slug == "snake" {
                            let slug = game.slug
                            setupGame = nil
                            Task {
                                // WAIT FOR THE SHEET TO FINISH DISMISSING before pushing.
                                //
                                // SwiftUI silently DROPS a navigation push that lands while a
                                // sheet is still animating away, and the REST round-trip below
                                // usually finishes inside that window — so the first taps did
                                // nothing at all and only the fourth or fifth appeared to
                                // work. Half a beat is enough to clear the transition.
                                try? await Task.sleep(nanoseconds: 350_000_000)
                                // Difficulty maps to how many bots share the arena. Bots all
                                // use identical physics to the player — no speed or turning
                                // advantage — so a busier arena IS the difficulty: less open
                                // space, more bodies to cut across.
                                let bots: Int
                                switch level {
                                case .easy:     bots = 3
                                case .moderate: bots = 5
                                case .hard:     bots = 8
                                }
                                if let id = await GamesEngine.shared.createSolo(
                                    slug: slug,
                                    options: ["bots": bots].merging(
                                        SnakeChoiceStore.matchOptions) { a, _ in a },
                                    skin: SnakeChoiceStore.skinId) {
                                    openMatch = OpenMatch(id: id, slug: slug)
                                }
                            }
                        } else {
                            botGame = BotSession(slug: game.slug, level: level, skill: skill)
                        }
                    },
                    onCustomise: game.slug == "snake" ? { showSkinPicker = true } : nil)
            }
            .sheet(item: $pendingGame) { game in
                OpponentPickerSheet(conversations: chat.directConversations) { convo in
                    // Hand cricket needs its match length before the row is minted (the server
                    // builds the innings from it), so it takes one more step. Every other game has
                    // nothing left to ask.
                    if game.slug == "cricket" {
                        pendingCricket = PendingCricket(game: game, conversation: convo)
                    } else {
                        Task { await startMatch(game: game, conversation: convo) }
                    }
                }
            }
            // Match length for an online hand cricket game. Chosen by the CREATOR and then fixed
            // for both players, because it is a property of the match, not of a player.
            .sheet(item: $pendingCricket) { pending in
                OversSheet { overs in
                    pendingCricket = nil
                    Task {
                        await startMatch(
                            game: pending.game,
                            conversation: pending.conversation,
                            options: ["overs": overs])
                    }
                }
            }
        }
        .navigationDestination(item: $lobby) { args in
            GameLobbyView(
                args: args,
                onStart: {
                    openMatch = OpenMatch(id: args.id, slug: args.slug)
                    lobby = nil
                },
                onClose: { lobby = nil })
                .environmentObject(session)
        }
        .task { await load() }
        .task {
            while !Task.isCancelled {
                if let fresh = try? await api.invites() { invites = fresh }
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        // A ROOT tab, so it claims the bar exactly like ChatsHomeView does.
        .onAppear { session.hideTabBar = false }
        // AND claims it again whenever a pushed screen pops back.
        //
        // `onAppear` does NOT re-fire when a NavigationStack pops to this view, and RootTabView's
        // self-heal only runs on a TAB change — so coming out of a game back onto this same tab
        // left the bar hidden with nothing to put it back. Watching the pushed-state bindings
        // covers every exit path (back button, Exit, give up, lobby cancel) without each screen
        // having to remember to restore it.
        .onChange(of: openMatch == nil && botGame == nil && lobby == nil
                  && !showLeaderboard) { _, atRoot in
            if atRoot { session.hideTabBar = false }
        }
        // Join tapped on an invite bubble. Joining is authorized server-side (the caller must
        // be in player_ids), so this only has to open the board — the opening `game_state`
        // frame populates it.
        .onReceive(NotificationCenter.default.publisher(for: .voiidOpenGameMatch)) { note in
            guard let id = note.userInfo?["match_id"] as? String else { return }
            let slug = (note.userInfo?["slug"] as? String) ?? "tictactoe"
            openMatch = OpenMatch(id: id, slug: slug)
        }
    }

    /// Create the match — which SENDS THE INVITE into this conversation — then open the board
    /// on the id the server minted. The board only opens once the opponent has been told.
    private func startMatch(
        game: GamesAPI.CatalogGame,
        conversation: VConversation,
        options: [String: Int] = [:]
    ) async {
        guard let peer = conversation.peerUserId, !peer.isEmpty else { return }
        if let id = await GamesEngine.shared.create(
            slug: game.slug,
            opponentId: peer,
            conversationId: conversation.id,
            gameName: game.name,
            options: options
        ) {
            // The creator WAITS IN THE LOBBY. Opening the board here is what made it look like
            // nothing happened: no opponent means no opening frame, so the board sat on
            // "Setting up…" forever.
            let overs = options["overs"] ?? 0
            lobby = LobbyArgs(
                id: id,
                slug: game.slug,
                gameName: game.name,
                opponentName: conversation.title,
                detailLine: overs > 0
                    ? "\(overs) \(overs == 1 ? "over" : "overs")"
                    : (game.slug == "rps" ? "first to 3" : ""))
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
                        // The artwork IS the title: the shipped art carries the game's name
                        // as a lettering treatment, so the card shows no text of its own. A
                        // name label under it read the title twice, and the scrim that used
                        // to sit here existed only to keep that label legible — both are
                        // gone with it.
                        Image(key)
                            .resizable()
                            .scaledToFill()
                            .accessibilityLabel(game.name)
                    } else {
                        // Art hasn't shipped yet — a tinted glyph over its NAME, since
                        // without artwork there is nothing else identifying the card.
                        VStack(spacing: VoiidSpacing.sm) {
                            Image(systemName: game.slug == "rps" ? "hand.raised" : "number.square")
                                .font(.system(size: 40, weight: .regular))
                                .foregroundStyle(VoiidColor.primary)
                            Text(game.name)
                                .font(VoiidFont.rounded(15, .semibold))
                                .foregroundStyle(VoiidColor.textPrimary)
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, VoiidSpacing.sm)
                        }
                    }
                }
                // 4:3 — the aspect the shipped artwork is authored at.
                .aspectRatio(4.0 / 3.0, contentMode: .fit)
                .clipped()
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
