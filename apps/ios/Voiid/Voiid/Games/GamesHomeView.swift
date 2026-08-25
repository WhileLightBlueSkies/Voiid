//
//  GamesHomeView.swift
//  Voiid
//
//  The Games tab — a featured carousel over category-grouped grids of large artwork cards.
//
//  WHY SECTIONS AND NOT ONE GRID: the catalog already carries a `category` per row ('board',
//  'arcade', …), so grouping is free information the flat grid was throwing away. A player
//  looking for something to play with one other person scans "Board" and stops; the same
//  player facing one undifferentiated grid reads every tile. The featured strip on top is the
//  same catalog rows at a larger size — an editorial surface with NO editorial data behind it
//  would be a lie, so it is simply the first few games, big.
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
    /// Which featured card is showing. Purely presentational — the carousel is a bigger view of
    /// catalog rows that are ALSO in the grid below, so paging it changes nothing but the pixels.
    @State private var featuredPage = 0
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
    /// Past matches. Separate from the leaderboard because they answer different questions —
    /// a standing versus what actually happened last night — and folding one into the other
    /// would bury whichever lost.
    @State private var showHistory = false
    /// Today's seeded Snake arena. Pushed rather than sheeted: it has a board of its own and a
    /// match launches out of it, which is a place you go, not a thing you glance at.
    @State private var showDaily = false
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
    /// An online Snake match waiting on its bot count, for the same reason: the arena is
    /// populated when the match row is created, so it cannot be chosen afterwards.
    @State private var pendingDuel: PendingCricket?

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
    @State private var showLudoWalkthrough = false
    @State private var ludoWalkthroughCompletion: (() -> Void)?

    /// Which games can be practised against a local bot.
    ///
    /// AN ALLOWLIST, NOT A DENYLIST, and it must stay in step with the `botGame` switch below —
    /// that switch falls through to Tic Tac Toe, so a game listed here without a case opens the
    /// wrong game rather than failing visibly. Adding a bot is: write the view, add its case,
    /// add its slug here.
    private static func hasLocalBot(_ slug: String) -> Bool {
        ["tictactoe", "rps", "cricket", "snake", "seabattle", "ludo"].contains(slug)
    }

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
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 34, weight: .regular))
                            .foregroundStyle(VoiidColor.textSecondary)
                            .padding(.bottom, VoiidSpacing.xs)
                        Text("Couldn't load games")
                            .font(VoiidFont.rounded(17, .semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        Button { Task { await load() } } label: {
                            Text("Try again")
                                .font(VoiidFont.rounded(15, .semibold))
                                .foregroundStyle(VoiidColor.textOnAccent)
                                .padding(.horizontal, VoiidSpacing.lg)
                                .frame(height: 40)
                                .background(Capsule().fill(VoiidColor.accent))
                        }
                        .buttonStyle(PressableButtonStyle())
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

                        // BELOW invites, ABOVE the catalog — which is exactly its urgency.
                        // Someone waiting on an invite beats it; browsing does not, because
                        // the daily expires at midnight and browsing does not.
                        Button {
                            Haptics.tap()
                            showDaily = true
                        } label: {
                            HStack(spacing: VoiidSpacing.md) {
                                // The glyph gets a tinted tile of its own so the row reads as a
                                // destination rather than as a settings line.
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(VoiidColor.accentInk)
                                    .frame(width: 44, height: 44)
                                    .background(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                                 style: .continuous)
                                        .fill(VoiidColor.accentTint))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Daily challenge")
                                        .font(VoiidFont.rounded(16, .semibold))
                                        .foregroundStyle(VoiidColor.textPrimary)
                                    Text("One Snake arena. Same for everyone. Resets at midnight.")
                                        .font(VoiidFont.rounded(12, .regular))
                                        .foregroundStyle(VoiidColor.textSecondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(VoiidColor.textSecondary)
                            }
                            .padding(VoiidSpacing.md)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                         style: .continuous)
                                .fill(VoiidColor.surfaceCard))
                            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg,
                                                      style: .continuous)
                                .stroke(VoiidColor.accent.opacity(0.35), lineWidth: 1))
                        }
                        .buttonStyle(BouncyCardStyle())
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.top, VoiidSpacing.sm)

                        // The featured strip. The SAME catalog rows as the grid below, drawn
                        // large — there is no editorial "featured" flag on the games table, and
                        // inventing one in the client would be a promotion nobody authored.
                        // Suppressed below three games: a carousel of two is a worse grid.
                        if featured.count >= 3 {
                            VStack(spacing: VoiidSpacing.sm) {
                                TabView(selection: $featuredPage) {
                                    ForEach(Array(featured.enumerated()), id: \.element.id) { i, game in
                                        FeaturedGameCard(game: game) { setupGame = game }
                                            .padding(.horizontal, VoiidSpacing.md)
                                            .tag(i)
                                    }
                                }
                                .tabViewStyle(.page(indexDisplayMode: .never))
                                .frame(height: 190)

                                // Dots outside the TabView so they sit under the card's edge
                                // rather than floating inside its own padding.
                                HStack(spacing: 6) {
                                    ForEach(featured.indices, id: \.self) { i in
                                        Capsule()
                                            .fill(i == featuredPage
                                                  ? VoiidColor.accent
                                                  : VoiidColor.textSecondary.opacity(0.3))
                                            .frame(width: i == featuredPage ? 16 : 6, height: 6)
                                            .animation(.easeOut(duration: 0.2), value: featuredPage)
                                    }
                                }
                            }
                            .padding(.top, VoiidSpacing.lg)
                        }

                        // Category sections. Grouped on the catalog's own `category` column, in
                        // the order the categories first appear in the server's response — so the
                        // backend still decides what comes first, exactly as it did for the flat
                        // grid.
                        LazyVStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                            // THE THIRD STATE, kept distinct from the failed one above: the fetch
                            // worked and the server has nothing enabled. It renders INSIDE the
                            // scroll rather than replacing it, because the invites and the daily
                            // challenge above do not depend on the catalog and must survive an
                            // empty one.
                            if games.isEmpty {
                                VStack(spacing: VoiidSpacing.xs) {
                                    Text("No games yet")
                                        .font(VoiidFont.rounded(17, .semibold))
                                        .foregroundStyle(VoiidColor.textPrimary)
                                    Text("New games show up here as they ship.")
                                        .font(VoiidFont.rounded(13, .regular))
                                        .foregroundStyle(VoiidColor.textSecondary)
                                }
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, VoiidSpacing.xl)
                            }

                            ForEach(sections, id: \.title) { section in
                                VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                                    HStack(spacing: VoiidSpacing.sm) {
                                        Text(section.title)
                                            .font(VoiidFont.rounded(19, .bold))
                                            .foregroundStyle(VoiidColor.textPrimary)
                                        Spacer(minLength: 0)
                                        // The count, not a "View All" — everything in the
                                        // section is already on screen, so a link that scrolls
                                        // nowhere would be decoration.
                                        Text("\(section.games.count)")
                                            .font(VoiidFont.rounded(13, .semibold))
                                            .foregroundStyle(VoiidColor.textSecondary)
                                            .monospacedDigit()
                                    }
                                    .padding(.horizontal, VoiidSpacing.md)

                                    LazyVGrid(columns: columns, spacing: VoiidSpacing.sm) {
                                        ForEach(section.games) { game in
                                            GameCard(game: game) { setupGame = game }
                                        }
                                    }
                                    .padding(.horizontal, VoiidSpacing.md)
                                }
                            }
                        }
                        .padding(.top, VoiidSpacing.lg)
                        // Clear the tab bar, painted over the page rather than inset into it.
                        .padding(.bottom, session.tabBarHeight + VoiidSpacing.lg)
                    }
                    .scrollIndicators(.hidden)
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
                    // Alongside the trophy, at the same weight: history is the other
                    // occasionally-checked reference, not something you launch.
                    Button { showHistory = true } label: {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(VoiidColor.primary)
                    }
                    .accessibilityLabel("Match history")
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
            .navigationDestination(isPresented: $showHistory) {
                MatchHistoryView { showHistory = false }
            }
            .navigationDestination(isPresented: $showDaily) {
                DailyChallengeView(
                    onPlay: { id in
                        // Leave the daily screen behind: coming back from the arena should land
                        // on the games tab, not on a board showing a run that is now over.
                        showDaily = false
                        openMatch = OpenMatch(id: id, slug: "snake")
                    },
                    onClose: { showDaily = false })
            }
            .navigationDestination(item: $openMatch) { m in
                // Renderer per game, keyed by the same slug the server's rules modules use.
                // Holding only a match id is what made every online match draw a
                // tic-tac-toe grid, RPS included.
                Group {
                    switch m.slug {
                    // ONE HANDLER FOR EVERY REMATCH. The server has already minted the new
                    // match by the time this runs, so opening it is the same navigation as
                    // opening any other — replacing `openMatch` swaps the destination in place
                    // rather than pushing a second board onto the stack.
                    case "rps":
                        RpsMatchView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            onRematch: { openMatch = OpenMatch(id: $0, slug: "rps") })
                    case "cricket":
                        CricketMatchView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            onRematch: { openMatch = OpenMatch(id: $0, slug: "cricket") })
                    case "seabattle":
                        SeaBattleView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            onRematch: { openMatch = OpenMatch(id: $0, slug: "seabattle") })
                    case "ludo":
                        LudoGameView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            onRematch: { openMatch = OpenMatch(id: $0, slug: "ludo") })
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
                    default:
                        TicTacToeView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            onRematch: { openMatch = OpenMatch(id: $0, slug: "tictactoe") })
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
                    case "seabattle":
                        SeaBattleBotView(level: s.level, skill: s.skill) { botGame = nil }
                    case "ludo":
                        LudoServerBotSetupView(
                            level: s.level,
                            onOpen: { id in
                                botGame = nil
                                openMatch = OpenMatch(id: id, slug: "ludo")
                            },
                            onClose: { botGame = nil })
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
                    slug: game.slug,
                    onPlayFriend: { pendingGame = game },
                    // NIL FOR A GAME WITH NO BOT. The bot destination below switches on slug and
                    // falls through to Tic Tac Toe, so a game without a case does not merely
                    // show a dead button — it opens a DIFFERENT GAME. Sea Battle and Ludo are
                    // exactly that today: engines and renderers, no client-side bot yet.
                    onPlayBot: Self.hasLocalBot(game.slug) ? { level, skill in
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
                                let id: String?
                                if slug == "ludo" {
                                    let difficulty: String
                                    switch level {
                                    case .easy: difficulty = "relaxed"
                                    case .moderate: difficulty = "balanced"
                                    case .hard: difficulty = "sharp"
                                    }
                                    id = await GamesEngine.shared.createLudoBot(difficulty: difficulty)
                                } else {
                                    id = await GamesEngine.shared.createSolo(
                                        slug: slug,
                                        options: ["bots": bots].merging(
                                            SnakeChoiceStore.matchOptions) { a, _ in a },
                                        skin: SnakeChoiceStore.skinId)
                                }
                                if let id {
                                    openMatch = OpenMatch(id: id, slug: slug)
                                }
                            }
                        } else {
                            botGame = BotSession(slug: game.slug, level: level, skill: skill)
                        }
                    } : nil,
                    onCustomise: game.slug == "snake" ? { showSkinPicker = true } : nil)
            }
            .sheet(item: $pendingGame) { game in
                // MORE THAN TWO SEATS GETS THE MULTI-SELECT PICKER (README §2.4). Keyed on the
                // CATALOG ROW rather than on a list of slugs, exactly as the server keys durable
                // persistence on tickHz being absent: the row is already the authority on how
                // many seats a game takes, and hardcoding a second copy here is how the two
                // disagree after the next game ships.
                if game.max_players > 2 {
                    SeatPickerSheet(
                        conversations: chat.directConversations,
                        maxOpponents: game.max_players - 1,
                        minOpponents: max(1, game.min_players - 1)
                    ) { convos in
                        Task { await startMultiMatch(game: game, conversations: convos) }
                    }
                } else {
                OpponentPickerSheet(conversations: chat.directConversations) { convo in
                    // Hand cricket needs its match length before the row is minted (the server
                    // builds the innings from it), so it takes one more step. Every other game has
                    // nothing left to ask.
                    if game.slug == "cricket" {
                        pendingCricket = PendingCricket(game: game, conversation: convo)
                    } else if game.slug == "snake" {
                        // Snake needs its bot count before the row is minted, for the same
                        // reason cricket needs its overs: the server builds the arena from it.
                        pendingDuel = PendingCricket(game: game, conversation: convo)
                    } else {
                        Task { await startMatch(game: game, conversation: convo) }
                    }
                }
                }
            }
            // How busy the arena is, for an online Snake match. Zero bots is a duel, which is
            // what a friend match silently was before it was ever a choice.
            .sheet(item: $pendingDuel) { pending in
                DuelSheet { bots in
                    pendingDuel = nil
                    Task {
                        await startMatch(
                            game: pending.game,
                            conversation: pending.conversation,
                            options: ["bots": bots].merging(
                                SnakeChoiceStore.matchOptions) { a, _ in a },
                            skin: SnakeChoiceStore.skinId)
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
                  && !showLeaderboard && !showDaily && !showHistory) { _, atRoot in
            if atRoot { session.hideTabBar = false }
        }
        // Join tapped on an invite bubble. Joining is authorized server-side (the caller must
        // be in player_ids), so this only has to open the board — the opening `game_state`
        // frame populates it.
        .sheet(isPresented: $showLudoWalkthrough) {
            LudoWalkthroughView(mode: .firstRun, clockNote: false, onDismiss: {
                showLudoWalkthrough = false
                ludoWalkthroughCompletion?()
                ludoWalkthroughCompletion = nil
            })
            .presentationDetentsCompat(heightFraction: 0.3)
        }
                .onReceive(NotificationCenter.default.publisher(for: .voiidOpenGameMatch)) { note in
            guard let id = note.userInfo?["match_id"] as? String else { return }
            let slug = (note.userInfo?["slug"] as? String) ?? "tictactoe"
            openMatch = OpenMatch(id: id, slug: slug)
        }
    }

    /// Create the match — which SENDS THE INVITE into this conversation — then open the board
    /// on the id the server minted. The board only opens once the opponent has been told.
    /// Create a match with several opponents and wait in the lobby for them.
    ///
    /// Same shape as `startMatch`, and deliberately so: the difference between a 2-player and a
    /// 4-player match is the number of invites sent, not a different lifecycle. The lobby then
    /// shows seats filling one by one, which LUDO.md §12.4 calls the "who else is coming" moment
    /// and asks to be visible rather than hidden behind a spinner.
    /// §10: experienced players (seen version ≥ 1) proceed without a pause; everyone else sees
    /// the seven-step walkthrough ONCE before their first create.
    private static var ludoWalkthroughSeen: Bool {
        UserDefaults.standard.integer(forKey: "ludo.walkthrough.seen") >= 1
    }

    private func startMultiMatch(
        game: GamesAPI.CatalogGame,
        conversations: [VConversation],
        options: [String: Int] = [:]
    ) async {
        if game.slug == "ludo" && !Self.ludoWalkthroughSeen {
            showLudoWalkthrough = true
            ludoWalkthroughCompletion = {
                Task { await startMultiMatch(game: game, conversations: conversations, options: options) }
            }
            return
        }
        let opponents: [(userId: String, conversationId: String)] = conversations.compactMap {
            guard let peer = $0.peerUserId, !peer.isEmpty else { return nil }
            return (userId: peer, conversationId: $0.id)
        }
        guard !opponents.isEmpty else { return }

        if let id = await GamesEngine.shared.createMulti(
            slug: game.slug,
            opponents: opponents,
            gameName: game.name,
            options: options
        ) {
            lobby = LobbyArgs(
                id: id,
                slug: game.slug,
                gameName: game.name,
                // Every name, not just the first: in a 4-player lobby "waiting for Priya" when
                // three people were invited is actively misleading about who is missing.
                opponentName: conversations.map(\.title).joined(separator: ", "),
                detailLine: "\(opponents.count + 1) players",
                seatCount: opponents.count + 1)
        }
    }

    private func startMatch(
        game: GamesAPI.CatalogGame,
        conversation: VConversation,
        options: [String: Int] = [:],
        /// Snake only. Forwarded rather than read here so the games that have no skin do not
        /// have to know one exists.
        skin: String? = nil
    ) async {
        guard let peer = conversation.peerUserId, !peer.isEmpty else { return }
        if let id = await GamesEngine.shared.create(
            slug: game.slug,
            opponentId: peer,
            conversationId: conversation.id,
            gameName: game.name,
            options: options,
            skin: skin
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
                detailLine: {
                    if overs > 0 { return "\(overs) \(overs == 1 ? "over" : "overs")" }
                    if game.slug == "rps" { return "first to 3" }
                    // Names the choice back to the creator while they wait, so the lobby
                    // confirms what they picked rather than leaving them to find out when the
                    // arena opens.
                    if game.slug == "snake" {
                        let bots = options["bots"] ?? 0
                        return bots == 0 ? "duel — no bots" : "\(bots) bots"
                    }
                    return ""
                }())
        }
    }

    /// The first three catalog rows, at carousel size. PURELY a slice of `games` — no ranking, no
    /// promotion, nothing the server did not already order.
    private var featured: [GamesAPI.CatalogGame] { Array(games.prefix(3)) }

    private struct Section {
        let title: String
        let games: [GamesAPI.CatalogGame]
    }

    /// `games` grouped by the catalog's `category`, keeping the server's order for both the
    /// sections and the games inside them. A category the client has never heard of gets its
    /// raw value capitalised rather than being dropped — a new category should ship as a DB row,
    /// same as a new game.
    private var sections: [Section] {
        var order: [String] = []
        var buckets: [String: [GamesAPI.CatalogGame]] = [:]
        for game in games {
            if buckets[game.category] == nil { order.append(game.category) }
            buckets[game.category, default: []].append(game)
        }
        return order.map { Section(title: Self.categoryTitle($0), games: buckets[$0] ?? []) }
    }

    private static func categoryTitle(_ raw: String) -> String {
        switch raw {
        case "board":  return "Board games"
        case "arcade": return "Arcade"
        case "card":   return "Card games"
        default:       return raw.capitalized
        }
    }

    private func load() async {
        loading = true
        loadFailed = false
        do { games = try await api.catalog() } catch { loadFailed = true }
        loading = false
    }
}

/// A catalog row at carousel size. Same tap target as the grid card — it opens the same setup
/// sheet — so this is one game shown large, not a second kind of thing.
///
/// The artwork fills the card and the copy sits over a LEFT-WEIGHTED scrim: a full-width scrim
/// would flatten the illustration the card exists to show. The name is drawn here even though
/// the grid card deliberately omits it (the art letters its own title at that size) — at 190pt
/// the art is cropped wide and its lettering often falls outside the frame.
private struct FeaturedGameCard: View {
    let game: GamesAPI.CatalogGame
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                if let key = game.icon_key, UIImage(named: key) != nil {
                    Image(key)
                        .resizable()
                        .scaledToFill()
                } else {
                    // Art hasn't shipped — the same tinted fallback the grid card uses, so a
                    // new game looks unfinished rather than broken.
                    VoiidColor.accentTint
                        .overlay {
                            Image(systemName: "gamecontroller.fill")
                                .font(.system(size: 56))
                                .foregroundStyle(VoiidColor.accent.opacity(0.35))
                        }
                }

                LinearGradient(
                    colors: [VoiidColor.background.opacity(0.94),
                             VoiidColor.background.opacity(0.6),
                             .clear],
                    startPoint: .leading, endPoint: .trailing)

                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name)
                        .font(VoiidFont.rounded(24, .bold))
                        .foregroundStyle(VoiidColor.textPrimary)
                        .lineLimit(2)
                    // The seat count, straight off the catalog row — the one fact about a game
                    // that changes what you have to arrange before you can play it.
                    Text(game.max_players > 2
                         ? "Up to \(game.max_players) players"
                         : "2 players")
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)

                    HStack(spacing: 6) {
                        Text("Play")
                            .font(VoiidFont.rounded(15, .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 12, weight: .bold))
                    }
                    .foregroundStyle(VoiidColor.textOnAccent)
                    .padding(.horizontal, VoiidSpacing.md)
                    .frame(height: 38)
                    .background(Capsule().fill(VoiidColor.accent))
                    .padding(.top, VoiidSpacing.sm)
                }
                .padding(VoiidSpacing.md)
                .frame(maxWidth: 230, alignment: .leading)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 190)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(game.name)
        }
        .buttonStyle(BouncyCardStyle())
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
