//
//  GamesScreen.swift
//  Voiid
//
//  Games — the arcade tab's home.
//
//  ── THE ORDER OF THE SECTIONS IS THE ARGUMENT ───────────────────────────────────
//  Featured, then Categories, then the catalog, then invites, then Tournaments. That is
//  descending by how likely a returning player is to want it — with one exception the
//  reference did not have: a LIVE INVITE outranks browsing, because someone is waiting on it.
//
//  ── WHAT WAS WIRED, AND WHAT WAS CUT ────────────────────────────────────────────
//  The reference's sample data is gone. `store` is now a live adapter over GamesAPI /
//  TournamentService (see ReferenceGamesModels).
//
//  REMOVED — the V Coin pill. Voiid has no currency: no wallet, no balance route, no ledger.
//  A pill reading "2,450" beside a coin glyph is read as a fact about the user's account, so
//  it was fiction shown as truth rather than placeholder art. Removed here and in the store.
//  DO NOT RE-ADD IT FROM THE REFERENCE.
//
//  HIDDEN — "Continue Playing" and "Friends Online". Neither has a backend (no session-resume
//  state; NO PRESENCE-FOR-GAMES ENDPOINT — nothing anywhere can answer "who is online and in a
//  lobby right now") and neither can ever be populated today. Hidden rather than shown with an
//  empty state, because a permanently-empty section is clutter that teaches the user to scroll
//  past that part of the screen forever. Both section bodies are KEPT below, behind their
//  `has…` gates, so the day a backend lands they light up unchanged. FRIENDS ONLINE STAYS
//  HIDDEN — do not populate it with last-seen timestamps or conversation activity; that is
//  presence invented from adjacent data, which is worse than an absent section.
//
//  TOURNAMENTS now render an empty STATE rather than vanishing — see `emptyTournaments`. They
//  are community-scoped by design, so a user in no community has none by definition, and one
//  line saying where they live beats a section that silently does not exist.
//
//  ── ONE SHEET FROM CARD TO BOARD ────────────────────────────────────────────────
//  Tapping a game opens `GameEntryFlow` — a SINGLE sheet with a NavigationStack inside it. It
//  replaced a chain of four modal presentations (setup → opponent/seats → overs/duel), which
//  had no back, no sense of place, and a separate dismiss animation per layer. See that file's
//  header for the shape and the reasoning; `handle(_:for:)` below turns its one answer into
//  the right piece of match plumbing.
//
//  ── TWO LOBBIES, AND BOTH ARE NOW REACHABLE ─────────────────────────────────────
//  `GameLobbyView` is the 1:1 invite-and-wait: an invite was sent, we are waiting, here is how
//  long they have. `GameLobbyScreen` (via `PartyLobbyHost`) is the PARTY lobby — real
//  ready-states, a real join code, real chat, all over a live WS channel. The party lobby was
//  fully wired to `game_lobbies` / `game_lobby_members` / `game_lobby_messages` and had NO
//  ENTRY POINT ANYWHERE IN THE APP until "Open a lobby" became a first-class choice in the
//  entry flow, alongside "a friend" and "the bot".
//
//  ── ARTWORK ─────────────────────────────────────────────────────────────────────
//  Real art now, where it exists: each catalog row's `icon_key` is an asset name, looked up by
//  NAME at runtime so adding a game is a DB row plus a drop-in asset. A game whose art hasn't
//  shipped falls back to the reference's id-keyed gradient rather than an empty card.
//

import SwiftUI

struct GamesScreen: View {

    // ── THE ONLY ADAPTATIONS IN THIS FILE ───────────────────────────────────────────
    // The reference injects the store from the environment via the @Observable macro. In
    // Voiid GamesStore has no injector, so this screen — the root of the flow — owns it.
    // AppSession and ChatStore are ObservableObjects, so they need @EnvironmentObject rather
    // than @Environment(_:). RootTabView already provides both.
    @State private var store = GamesStore()
    @EnvironmentObject private var session: AppSession
    /// The opponent list — games are played with people you already have a conversation with.
    @EnvironmentObject private var chat: ChatStore

    @State private var featuredPage = 0

    /// The pushed step of the match flow. The reference had three (detail → lobby → starting);
    /// only `detail` survives, because the other two were the party lobby Voiid does not have.
    private enum Step: Hashable {
        case detail(String)
    }

    @State private var path: [Step] = []
    /// The invite sheet. Nil when nobody is asking.
    @State private var invite: RefGameInvite?

    // ── THE REAL MATCH PLUMBING ─────────────────────────────────────────────────────
    // Reused verbatim from GamesHomeView, which is the reference implementation for all of
    // this. Not a second version of it: same states, same sheets, same destinations.

    /// The game whose ENTRY FLOW is open. A card is a GAME; nothing exists until an opponent
    /// is chosen.
    ///
    /// ONE SHEET FOR THE WHOLE DECISION. This used to be the head of a chain — `setupGame` →
    /// `pendingGame` → `pendingCricket`/`pendingDuel`, four modal presentations for one
    /// question. `GameEntryFlow` is a single sheet with a NavigationStack inside it; see that
    /// file's header for why that shape and not a content swap.
    @State private var setupGame: Game?
    /// The offline practice board: which game, at what difficulty.
    @State private var botGame: BotSession?
    /// The open online match, as id + slug. The SLUG chooses the renderer.
    @State private var openMatch: OpenMatch?
    /// The lobby the CREATOR waits in after sending an invite. The 1:1 invite-and-wait one.
    @State private var lobby: LobbyArgs?
    /// The PARTY lobby — ready-states, join code, chat. A different room from `lobby` above,
    /// chosen explicitly in the entry flow. See PartyLobbyHost.
    @State private var party: PartyArgs?
    @State private var showSkinPicker = false
    @State private var showLudoWalkthrough = false
    @State private var ludoWalkthroughCompletion: (() -> Void)?

    private struct OpenMatch: Identifiable, Hashable {
        let id: String
        let slug: String
    }
    private struct BotSession: Identifiable, Hashable {
        let id = UUID()
        let slug: String
        let level: BotDifficulty
        let skill: Double
    }

    /// Which games can be practised against a local bot.
    ///
    /// AN ALLOWLIST, NOT A DENYLIST, and it must stay in step with the `botGame` switch below —
    /// that switch falls through to Tic Tac Toe, so a game listed here without a case opens the
    /// wrong game rather than failing visibly. Same list GamesHomeView keeps, same reason.
    private static func hasLocalBot(_ slug: String) -> Bool {
        ["tictactoe", "rps", "cricket", "snake", "seabattle", "ludo"].contains(slug)
    }

    /// §10: experienced players (seen version ≥ 1) proceed without a pause; everyone else sees
    /// the seven-step walkthrough ONCE before their first Ludo create.
    private static var ludoWalkthroughSeen: Bool {
        UserDefaults.standard.integer(forKey: "ludo.walkthrough.seen") >= 1
    }

    var body: some View {
        NavigationStack(path: $path) {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                        header

                        // THE V COIN PILL WAS HERE. See the file note — removed, not hidden.

                        switch store.feedState {
                        case .loading:
                            loadingState
                        case .failed(let message):
                            // A failed fetch must never render as an empty list.
                            failedState(message)
                        case .empty:
                            emptyState
                        case .loaded:
                            content
                        }
                    }
                    .padding(.top, VoiidSpacing.sm)
                }
                .scrollIndicators(.hidden)
                // ADAPTATION, availability only. The reference targets iOS 26, where this
                // modifier is unconditional; Voiid deploys lower, so it is gated. On iOS 26
                // the soft top edge is exactly the reference's; below it the scroll view
                // simply has no edge effect, which is the OS default and not a layout change.
                .modifier(SoftTopScrollEdge())
                // The floor matters: `bottomInset` is 0 until the tab bar measures itself a
                // frame later, and the last card would already have laid out underneath it.
                .contentMargins(.bottom, max(session.bottomInset, 96), for: .scrollContent)
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Step.self) { step in
                switch step {
                case .detail(let gameId):
                    // The game is looked up by id rather than carried in the enum: a Step must
                    // be Hashable and the path survives a catalog refresh, so holding the id
                    // means a refreshed row is the one that renders.
                    if let game = store.games.first(where: { $0.id == gameId }) {
                        GameDetailScreen(
                            game: game,
                            // Both footer buttons do the same real thing — open the setup
                            // sheet, which is where an opponent is chosen. The reference's
                            // "Create Lobby" / "Invite Friends" split assumed a party lobby you
                            // could sit in alone; Voiid has no such state.
                            onCreateLobby: { setupGame = game },
                            onInviteFriends: { setupGame = game })
                    }
                }
            }
            .navigationDestination(item: $openMatch) { m in
                // Renderer per game, keyed by the same slug the server's rules modules use.
                // Holding only a match id is what made every online match draw a tic-tac-toe
                // grid, RPS included. Reused verbatim from GamesHomeView.
                Group {
                    switch m.slug {
                    case "rps":
                        RpsMatchView(matchId: m.id,
                                     onClose: { openMatch = nil },
                                     onRematch: { openMatch = OpenMatch(id: $0, slug: "rps") })
                    case "cricket":
                        CricketMatchView(matchId: m.id,
                                         onClose: { openMatch = nil },
                                         onRematch: { openMatch = OpenMatch(id: $0, slug: "cricket") })
                    case "seabattle":
                        SeaBattleView(matchId: m.id,
                                      onClose: { openMatch = nil },
                                      onRematch: { openMatch = OpenMatch(id: $0, slug: "seabattle") })
                    case "ludo":
                        LudoGameView(matchId: m.id,
                                     onClose: { openMatch = nil },
                                     onRematch: { openMatch = OpenMatch(id: $0, slug: "ludo") })
                    case "snake":
                        SnakeArenaView(
                            matchId: m.id,
                            onClose: { openMatch = nil },
                            // A fresh match rather than reusing the finished one: the server
                            // drops a match's state when it ends, so there is nothing to rejoin.
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
                        TicTacToeView(matchId: m.id,
                                      onClose: { openMatch = nil },
                                      onRematch: { openMatch = OpenMatch(id: $0, slug: "tictactoe") })
                    }
                }
                .environmentObject(session)
            }
            .navigationDestination(item: $botGame) { s in
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
            // THE REAL LOBBY. Not the ported party screen — see the file note.
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
            .sheet(item: $invite) { invite in
                GameInviteSheet(
                    invite: invite,
                    // Accepting opens the REAL match. Joining is authorized server-side (the
                    // caller must be in player_ids), so this only has to open the board — the
                    // opening `game_state` frame populates it.
                    onJoin: {
                        self.invite = nil
                        openMatch = OpenMatch(id: invite.matchId, slug: invite.slug)
                    },
                    onMessage: { self.invite = nil })
            }
            // THE PARTY LOBBY. Reachable at last — it was fully wired to
            // `game_lobbies`/`game_lobby_members`/`game_lobby_messages` and had no entry point
            // anywhere in the app. See PartyLobbyHost for the state handling it adds.
            .navigationDestination(item: $party) { args in
                if let game = store.games.first(where: { $0.id == args.gameId }) {
                    PartyLobbyHost(
                        game: game,
                        args: args,
                        onStart: {
                            openMatch = OpenMatch(id: args.id, slug: game.slug)
                            party = nil
                        },
                        onClose: { party = nil })
                        .environmentObject(session)
                }
            }
            // ── ONE SHEET FOR THE WHOLE ENTRY DECISION ──────────────────────────────
            // Was four chained presentations (setup → opponent/seats → overs/duel). Now one,
            // with the steps pushed INSIDE it so the system's interactive swipe-back works at
            // every step and no surface ever animates away to be replaced by another.
            .sheet(item: $setupGame) { game in
                GameEntryFlow(
                    game: game,
                    conversations: chat.directConversations,
                    // FALSE FOR A GAME WITH NO BOT. The bot destination above switches on slug
                    // and falls through to Tic Tac Toe, so a game without a case does not
                    // merely show a dead button — it opens a DIFFERENT GAME.
                    hasLocalBot: Self.hasLocalBot(game.slug),
                    onFinish: { outcome in handle(outcome, for: game) })
            }
            .sheet(isPresented: $showSkinPicker) {
                SnakeSkinPicker { showSkinPicker = false }
                    .presentationDetents([.medium, .large])
            }
            .sheet(isPresented: $showLudoWalkthrough) {
                LudoWalkthroughView(mode: .firstRun, clockNote: false, onDismiss: {
                    showLudoWalkthrough = false
                    ludoWalkthroughCompletion?()
                    ludoWalkthroughCompletion = nil
                })
                .presentationDetentsCompat(heightFraction: 0.3)
            }
        }
        .task { await store.load() }
        // A SEPARATE `.task`, not chained onto the catalog load: the two are independent
        // round-trips and neither should be able to delay or fail the other. Visibility
        // failing silently leaves every game on the shelf — see `loadVisibility`.
        .task { await store.loadVisibility() }
        .task { await store.loadTournaments() }
        .task {
            // Polled rather than pushed: an invite arrives as a chat message, and the games
            // surface has no socket subscription of its own — a 20s poll while this tab is
            // open is cheaper than inventing a second delivery path for a banner.
            while !Task.isCancelled {
                await store.refreshInvites()
                try? await Task.sleep(nanoseconds: 20_000_000_000)
            }
        }
        // Presence, on its own clock.
        //
        // 60 SECONDS, MATCHED TO THE TTL. The relay stamps `user:<id>:online` with a 60s
        // expiry, so the underlying fact changes at most once a minute; polling faster than
        // that spends a request to re-read a value that provably cannot have moved. Polling
        // much SLOWER would let the card outlive the heartbeat and claim someone is here
        // after Redis has already forgotten them.
        //
        // STOPS WITH THE VIEW. `.task` is cancelled when this view goes away, so switching
        // tabs or pushing a board ends the poll rather than leaving a timer running behind a
        // screen nobody is looking at.
        .task(id: chat.directConversations.count) {
            while !Task.isCancelled {
                await store.refreshFriends(peers: chat.directConversations)
                try? await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        // A ROOT tab, so it claims the bar exactly like ChatsHomeView does.
        .onAppear { session.hideTabBar = false }
        // AND claims it again whenever a pushed screen pops back. `onAppear` does NOT re-fire
        // when a NavigationStack pops to this view, and RootTabView's self-heal only runs on a
        // TAB change — so coming out of a game back onto this same tab left the bar hidden with
        // nothing to put it back.
        .onChange(of: openMatch == nil && botGame == nil && lobby == nil && party == nil) { _, atRoot in
            if atRoot { session.hideTabBar = false }
        }
        // Join tapped on a game-invite bubble over in Chats.
        .onReceive(NotificationCenter.default.publisher(for: .voiidOpenGameMatch)) { note in
            guard let id = note.userInfo?["match_id"] as? String else { return }
            let slug = (note.userInfo?["slug"] as? String) ?? "tictactoe"
            openMatch = OpenMatch(id: id, slug: slug)
        }
    }

    // MARK: The loaded page

    /// Everything below the header, once the catalog is in.
    @ViewBuilder
    private var content: some View {
        // HIDING EVERY GAME MUST NOT PRODUCE A DEAD TAB. With every row switched off the
        // carousel, the chips and the grid are all empty, and rendering them would leave a
        // tab that looks broken with nothing on it to explain why or undo it. So the whole
        // browsing stack is replaced by a state that NAMES THE CAUSE and carries the way
        // back — the same screen the setting was changed on, one tap away.
        //
        // Distinct from `emptyState` above, which means the SERVER sent no catalog. Same
        // blank grid, opposite causes, and only one of them is something the user can fix.
        if store.everythingHidden {
            allHiddenState
            // Invites and tournaments still render below: an invite to a hidden game is
            // still a live invite, and a tournament is not a shelf listing.
            inviteBanners
            tournaments
        } else {
            browsingContent
        }
    }

    /// The ordinary browsing stack — everything shown when at least one game is on the shelf.
    @ViewBuilder
    private var browsingContent: some View {
        featured
        // HIDDEN UNTIL A BACKEND EXISTS — no session-resume state. See the file note. The
        // section body is kept intact so it lights up unchanged the day one lands.
        if store.hasContinuePlaying { continueSection }
        categories
        catalogSection
        // LIVE. Shown only when there is something true to say — see `showFriendsSection`,
        // which deliberately keeps the section up on a FAILED check and takes it down on a
        // successful one that found nobody.
        if store.showFriendsSection { friendsSection }
        inviteBanners
        tournaments
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: VoiidSpacing.sm + 2) {
            ProfilePhoto(name: "You", size: 42, allowFallbackPhoto: true)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(VoiidColor.accent)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                }

            Text("Games")
                .font(VoiidFont.rounded(28, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            Spacer(minLength: 0)

            HStack(spacing: VoiidSpacing.sm) {
                // The reference's search and bell went nowhere. These two go somewhere real —
                // standings and history, the two occasionally-checked references GamesHomeView
                // puts in its toolbar. Same circle-button chrome, same positions.
                NavigationLink {
                    LeaderboardView { }
                } label: {
                    circleButtonLabel("trophy")
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Leaderboard")

                NavigationLink {
                    MatchHistoryView { }
                } label: {
                    // Badged when something is actually waiting, which is what the reference's
                    // dot implied and never had.
                    circleButtonLabel("clock.arrow.circlepath",
                                      badged: !store.visibleInvites.isEmpty)
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Match history")

                // GAME SETTINGS — THE ONE DOOR, AND IT IS HERE.
                //
                // This button briefly moved into the Settings tree as a "Games" row. That was
                // wrong: game settings are settings ABOUT the arcade, and the arcade is where
                // a player is standing when they want them. The Settings row is gone — there
                // is no `SettingsRoute.games` any more — so this is the ONLY entry point.
                // Do not add a second one; two doors to one screen is how a user learns to
                // distrust both.
                //
                // What it opens is NOT the old `GameSettingsSheet`. That sheet mixed scopes:
                // sound and haptics (every game) sat directly above Snake's steering (one
                // game). The per-game half stayed split out onto the game's own detail screen
                // (`GameSettingsCard`), which is correct and is not being undone. What comes
                // back here is the GLOBAL half, in the card vocabulary, plus the visibility
                // list — both of which are facts about the whole arcade.
                //
                // A push, not a sheet, matching Leaderboard and Match History beside it: this
                // is a place with a list in it, not a quick modal decision.
                NavigationLink {
                    GameSettingsView(store: store)
                } label: {
                    circleButtonLabel("slider.horizontal.3")
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Game settings")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    private func circleButtonLabel(_ icon: String, badged: Bool = false) -> some View {
        Image(systemName: icon)
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(VoiidColor.textPrimary)
            .frame(width: 40, height: 40)
            .background(Circle().fill(VoiidColor.surfaceCard))
            .overlay(Circle().stroke(VoiidColor.divider, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                if badged {
                    Circle()
                        .fill(VoiidColor.accent)
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(VoiidColor.background, lineWidth: 1.5))
                }
            }
    }

    // MARK: Catalog states

    private var loadingState: some View {
        ProgressView()
            .tint(VoiidColor.accent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 120)
    }

    /// A failed fetch and an empty catalog look identical to a user; say which.
    private func failedState(_ message: String) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 34))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.bottom, VoiidSpacing.xs)

            Text(message)
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Button {
                Haptics.tap()
                Task { await store.load() }
            } label: {
                Text("Try again")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .frame(height: 40)
                    .background(Capsule().fill(VoiidColor.accent))
            }
            .buttonStyle(PressableButtonStyle())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    /// The third state: the fetch worked and the server has nothing enabled.
    /// Every game switched off in Game settings.
    ///
    /// Says WHO did it ("You've hidden"), so it reads as a setting rather than a failure, and
    /// offers the only useful action: go turn one back on. Anything less — a bare "No games"
    /// — would have the user pulling to refresh a tab that is working exactly as told.
    private var allHiddenState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "eye.slash")
                .font(.system(size: 34))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.bottom, VoiidSpacing.xs)

            Text("You've hidden every game")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Text("Turn one back on in Game settings and it reappears here.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            // The way out, in the empty state itself — not only under the small circle in
            // the header the user has evidently not connected to this. Same destination, so
            // there is still exactly one game-settings screen.
            NavigationLink {
                GameSettingsView(store: store)
            } label: {
                Text("Open Game settings")
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .frame(height: 44)
                    .background(Capsule().fill(VoiidColor.accent))
            }
            .buttonStyle(PressableButtonStyle())
            .padding(.top, VoiidSpacing.xs)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.vertical, 70)
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.xs) {
            Text("No games yet")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("New games show up here as they ship.")
                .font(VoiidFont.rounded(13))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 90)
    }

    // MARK: Featured

    private var featured: some View {
        VStack(spacing: VoiidSpacing.sm) {
            TabView(selection: $featuredPage) {
                ForEach(Array(store.featured.enumerated()), id: \.element.id) { index, slide in
                    FeaturedCard(slide: slide) { path.append(.detail(slide.game.id)) }
                        .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 200)

            // Dots live outside the TabView so they sit ON the card's lower edge rather than
            // inside its padding, which is where the reference puts them.
            HStack(spacing: 6) {
                ForEach(store.featured.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == featuredPage ? VoiidColor.accent
                                                : VoiidColor.textSecondary.opacity(0.35))
                        .frame(width: i == featuredPage ? 16 : 6, height: 6)
                        .animation(.easeOut(duration: 0.2), value: featuredPage)
                }
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: Continue playing
    //
    // NO BACKEND — gated off in `content`. Kept whole, so the day a resume state ships this
    // needs no layout work. See the file note.

    private var continueSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            sectionHeader("Continue Playing", showAll: false)

            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    ForEach(store.continuePlaying) { game in
                        ContinueCard(game: game)
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: Categories

    private var categories: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            sectionHeader("Categories", showAll: false)

            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    // The categories the catalog ACTUALLY has, not a fixed enum — a chip that
                    // filters to nothing is a dead control. See GamesStore.categories.
                    ForEach(store.categories) { option in
                        let selected = store.category == option

                        Button {
                            Haptics.selection()
                            withAnimation(.easeOut(duration: 0.18)) {
                                // Tapping the active one clears it — see the store's note.
                                store.category = selected ? nil : option
                            }
                        } label: {
                            HStack(spacing: 7) {
                                Image(systemName: option.icon)
                                    .font(.system(size: 13))
                                    .foregroundColor(selected ? VoiidColor.textOnAccent
                                                              : VoiidColor.accentInk)
                                Text(option.rawValue)
                                    .font(VoiidFont.rounded(14, .medium))
                                    .foregroundColor(selected ? VoiidColor.textOnAccent
                                                              : VoiidColor.textPrimary)
                            }
                            .padding(.horizontal, 15)
                            .frame(height: 42)
                            .background(
                                Capsule().fill(selected ? VoiidColor.accent
                                                        : VoiidColor.surfaceCard)
                            )
                            .overlay(Capsule().stroke(selected ? .clear : VoiidColor.divider,
                                                      lineWidth: 1))
                        }
                        .buttonStyle(PressableButtonStyle())
                        .accessibilityAddTraits(selected ? [.isSelected] : [])
                    }
                }
                .padding(.horizontal, VoiidSpacing.md)
            }
            .scrollIndicators(.hidden)
        }
    }

    // MARK: The catalog itself
    //
    // The reference had no such section — its Categories row filtered a grid that did not
    // exist, because every game on that screen was a sample. A real catalog has to be
    // browsable, so the chips now filter THIS. Same card language as the Continue strip.

    private var catalogSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            sectionHeader(store.category?.rawValue ?? "All Games", showAll: false)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: VoiidSpacing.sm),
                                GridItem(.flexible(), spacing: VoiidSpacing.sm)],
                      spacing: VoiidSpacing.sm) {
                ForEach(store.visibleGames) { game in
                    GameTile(game: game) { path.append(.detail(game.id)) }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    // MARK: Friends
    //
    // LIVE NOW — see `GamesStore.refreshFriends`. Presence is real (a 60s Redis heartbeat
    // written by the WebSocket relay, read through the last_seen_privacy gate); what the
    // reference claimed on top of it — "Playing", "In Lobby", a game name and that game's
    // art — was not, and is gone. See `GameFriend`.
    //
    // The section's VISIBILITY is decided by `store.showFriendsSection`, not by whether the
    // array is empty: a failed presence check keeps the section on screen to say it failed,
    // because rendering nothing would assert that nobody is online.

    private var friendsSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            sectionHeader("Friends Online", showAll: false)

            if case .failed(let message) = store.friendState {
                // Distinct from "nobody is online" — same treatment tournaments give the
                // same distinction, because it is the same distinction.
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 15))
                        .foregroundColor(VoiidColor.textSecondary)
                    Text(message)
                        .font(VoiidFont.rounded(13.5))
                        .foregroundColor(VoiidColor.textSecondary)
                    Spacer(minLength: 0)
                    Button("Retry") {
                        Task { await store.refreshFriends(peers: chat.directConversations) }
                    }
                    .font(VoiidFont.rounded(13.5, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
                }
                .padding(VoiidSpacing.md)
                .background(VoiidColor.surfaceCard)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .padding(.horizontal, VoiidSpacing.md)
            } else {
                ScrollView(.horizontal) {
                    HStack(spacing: 12) {
                        ForEach(store.friends) { friend in
                            FriendCard(friend: friend)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                }
                .scrollIndicators(.hidden)
            }
        }
    }

    // MARK: Tournaments

    private var tournaments: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // ALWAYS DRAWN NOW. It used to be suppressed on `.empty`, which meant the section
            // vanished entirely — and a section that renders nothing is indistinguishable from
            // a section that does not exist. Tournaments DO exist; they just live inside
            // communities, and a user in none has none by definition. That is a fact worth one
            // line, not a reason to make the whole feature invisible. See `emptyTournaments`.
            sectionHeader("Live Tournaments", showAll: false)

            VStack(spacing: VoiidSpacing.sm + 2) {
                switch store.tournamentState {
                case .loading:
                    ProgressView()
                        .tint(VoiidColor.accent)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, VoiidSpacing.lg)
                case .failed(let message):
                    // Distinct from empty: "no tournaments" and "couldn't reach the server"
                    // are different sentences with different remedies.
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "wifi.exclamationmark")
                            .font(.system(size: 15))
                            .foregroundColor(VoiidColor.textSecondary)
                        Text(message)
                            .font(VoiidFont.rounded(13.5))
                            .foregroundColor(VoiidColor.textSecondary)
                        Spacer(minLength: 0)
                        Button("Retry") { Task { await store.loadTournaments() } }
                            .font(VoiidFont.rounded(13.5, .semibold))
                            .foregroundColor(VoiidColor.accentInk)
                    }
                    .padding(VoiidSpacing.md)
                    .background(VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                case .empty:
                    emptyTournaments
                case .loaded:
                    ForEach(store.tournaments) { tournament in
                        TournamentCard(tournament: tournament) {
                            Task { await store.toggleRegistration(tournament) }
                        }
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    /// The tournaments empty state — which says WHICH KIND of empty it is.
    ///
    /// Two causes, one blank list, and they need different sentences because they have
    /// different remedies. A user in no community will never see a tournament here no matter
    /// how long they wait, and telling them where tournaments actually live is the only useful
    /// thing this space can do. A user who IS in communities is simply between events.
    ///
    /// NO BUTTON. Joining a community is a Community-tab journey with its own discovery
    /// surface; a shortcut minted here would be a second entry point to maintain for a
    /// one-sentence explanation.
    private var emptyTournaments: some View {
        VStack(spacing: VoiidSpacing.xs) {
            Image(systemName: "trophy")
                .font(.system(size: 26))
                .foregroundColor(VoiidColor.textSecondary)
                .padding(.bottom, 2)

            Text(store.inAnyCommunity ? "Nothing running right now"
                                      : "Tournaments live in communities")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textPrimary)

            Text(store.inAnyCommunity
                 ? "When one of your communities starts a tournament, it shows up here."
                 : "Join a community and its tournaments appear here.")
                .font(VoiidFont.rounded(12.5))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.lg)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    // MARK: Incoming invites

    /// LIVE invites, inline on Home. Real ones, from `GamesAPI.invites()` — the reference's
    /// banner was a hardcoded "Maya is playing Weekend Arena" that opened a sample sheet.
    ///
    /// It sits above Tournaments because a friend waiting on you outranks an event.
    @ViewBuilder
    private var inviteBanners: some View {
        if !store.visibleInvites.isEmpty {
            VStack(spacing: VoiidSpacing.sm) {
                ForEach(store.visibleInvites) { pending in
                    inviteBanner(pending)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
    }

    private func inviteBanner(_ pending: GamesAPI.PendingInvite) -> some View {
        let model = RefGameInvite(pending)

        return HStack(spacing: 10) {
            Button {
                Haptics.tap()
                invite = model
            } label: {
                HStack(spacing: 10) {
                    ProfilePhoto(name: model.from, size: 38, allowFallbackPhoto: true)
                        .overlay(Circle().stroke(VoiidColor.accent, lineWidth: 2).padding(-2))

                    VStack(alignment: .leading, spacing: 1) {
                        Text("\(model.from) invited you to \(model.gameTitle)")
                            .font(VoiidFont.rounded(13.5, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .lineLimit(1)
                        // The server's own verdict on the window, not the client's clock.
                        Text(pending.missed ? "This invite expired" : "Tap to see the invite")
                            .font(VoiidFont.rounded(11.5))
                            .foregroundColor(VoiidColor.textSecondary)
                    }

                    Spacer(minLength: 0)

                    // A missed invite has nothing left to join, so it gets no Join button —
                    // an affordance that always fails is worse than no affordance.
                    if !pending.missed {
                        Text("Join")
                            .font(VoiidFont.rounded(13.5, .semibold))
                            .foregroundColor(VoiidColor.textOnAccent)
                            .padding(.horizontal, 16)
                            .frame(height: 34)
                            .background(Capsule().fill(VoiidColor.accent))
                    }
                }
            }
            .buttonStyle(PressableButtonStyle())

            Button {
                Haptics.tap()
                withAnimation(.easeOut(duration: 0.2)) {
                    store.dismissInvite(pending.match_id)
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .frame(width: 26, height: 26)
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Dismiss invite")
        }
        .padding(.horizontal, VoiidSpacing.sm + 4)
        .frame(height: 62)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
            .stroke(VoiidColor.accent.opacity(0.4), lineWidth: 1))
    }

    // MARK: Section scaffold

    private func sectionHeader(_ title: String, showAll: Bool) -> some View {
        HStack {
            Text(title)
                .font(VoiidFont.rounded(19, .bold))
                .foregroundColor(VoiidColor.textPrimary)

            Spacer(minLength: 0)

            // ALWAYS FALSE AT EVERY CALL SITE NOW. "View All" went nowhere in the reference,
            // and every section here already shows everything it has. The parameter stays so
            // the reference's scaffold is recognisable, and so a section that genuinely
            // overflows one day can turn it on.
            if showAll {
                Button("View All") { Haptics.tap() }
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.accentInk)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    // MARK: Starting a match
    //
    // Reused verbatim from GamesHomeView — same calls, same order, same reasons. The only
    // change is that the catalog row arrives as a `Game` rather than a `CatalogGame`.

    /// Turn the entry flow's ONE answer into the right piece of match plumbing.
    ///
    /// The flow decides WHO and WITH WHAT; this decides what that means. Keeping the split
    /// there is what lets `GameEntryFlow` know nothing about `GamesEngine`.
    ///
    /// EVERY BRANCH THAT PUSHES A SCREEN WAITS OUT THE SHEET FIRST. `GameEntryFlow` calls
    /// `dismiss()` and then answers, so this runs while the sheet is still animating away —
    /// and SwiftUI silently DROPS a navigation push that lands inside that window. That is the
    /// bug `GameEntryFlow.dismissWait` exists for; the one difference from the old flow is that
    /// there is now exactly ONE dismissal to wait out instead of up to four.
    private func handle(_ outcome: GameEntryOutcome, for game: Game) {
        switch outcome {
        case .customise:
            // WAITS TOO, for the mirror of the push problem: presenting a second sheet while
            // the first is still animating away is the sheet-over-sheet the whole redesign
            // exists to remove, and iOS drops the second presentation outright when the timing
            // is unlucky. The picker is a different surface for a different question, so it is
            // a fresh sheet — but only once this one has actually gone.
            Task {
                try? await Task.sleep(nanoseconds: GameEntryFlow.dismissWait)
                showSkinPicker = true
            }

        case .bot(let level, let skill):
            startBot(game: game, level: level, skill: skill)

        case .friend(let convo, let options, let skin):
            Task {
                try? await Task.sleep(nanoseconds: GameEntryFlow.dismissWait)
                await startMatch(game: game, conversation: convo,
                                 options: options, skin: skin)
            }

        case .seats(let convos, let options):
            Task {
                try? await Task.sleep(nanoseconds: GameEntryFlow.dismissWait)
                await startMultiMatch(game: game, conversations: convos, options: options)
            }

        case .party(let convos, let options):
            Task {
                try? await Task.sleep(nanoseconds: GameEntryFlow.dismissWait)
                await startParty(game: game, conversations: convos, options: options)
            }
        }
    }

    /// Create the match, then open a PARTY LOBBY on it.
    ///
    /// SAME CREATION CALL AS `startMultiMatch`, deliberately. A party lobby is not a different
    /// kind of match — it is the same row with a lobby opened on it, which is exactly what
    /// `POST /games/matches/:id/lobby` does. What differs is where the creator waits: the party
    /// room (ready-states, join code, chat) rather than the 1:1 invite-and-wait screen.
    ///
    /// The Ludo walkthrough gate applies here for the same reason it applies to a direct
    /// multi-seat create: it is gating a player's FIRST Ludo match, not a particular lobby shape.
    private func startParty(game: Game, conversations: [VConversation],
                            options: [String: Int] = [:]) async {
        if game.slug == "ludo" && !Self.ludoWalkthroughSeen {
            showLudoWalkthrough = true
            ludoWalkthroughCompletion = {
                Task { await startParty(game: game, conversations: conversations,
                                        options: options) }
            }
            return
        }
        let opponents: [(userId: String, conversationId: String)] = conversations.compactMap {
            guard let peer = $0.peerUserId, !peer.isEmpty else { return nil }
            return (userId: peer, conversationId: $0.id)
        }
        guard !opponents.isEmpty else { return }

        if let id = await GamesEngine.shared.createMulti(
            slug: game.slug, opponents: opponents, gameName: game.title, options: options) {
            let overs = options["overs"] ?? 0
            party = PartyArgs(
                id: id,
                gameId: game.id,
                asHost: true,
                // The host's free-text option line. EMPTY when the game has no such setting —
                // `LobbyState.format` renders nothing rather than inventing a string.
                format: overs > 0 ? "\(overs) \(overs == 1 ? "over" : "overs")" : "")
        }
    }

    private func startBot(game: Game, level: BotDifficulty, skill: Double) {
        // Snake's and Ludo's bots live on the SERVER, so "play a bot" mints a real match
        // rather than opening a local simulation. Every other game here is turn-based and
        // simulates its opponent on-device.
        guard game.slug == "snake" else {
            botGame = BotSession(slug: game.slug, level: level, skill: skill)
            return
        }
        let slug = game.slug
        Task {
            // WAIT FOR THE SHEET TO FINISH DISMISSING before pushing. SwiftUI silently DROPS a
            // navigation push that lands while a sheet is still animating away, and the REST
            // round-trip below usually finishes inside that window — so the first taps did
            // nothing at all. Half a beat is enough to clear the transition.
            //
            // The flow already called `dismiss()` on itself, so there is no `setupGame = nil`
            // here any more; the wait is unchanged and is now the single one in the path.
            try? await Task.sleep(nanoseconds: GameEntryFlow.dismissWait)
            // Difficulty maps to how many bots share the arena. Bots use identical physics to
            // the player — no speed or turning advantage — so a busier arena IS the difficulty.
            let bots: Int
            switch level {
            case .easy:     bots = 3
            case .moderate: bots = 5
            case .hard:     bots = 8
            }
            if let id = await GamesEngine.shared.createSolo(
                slug: slug,
                options: ["bots": bots].merging(SnakeChoiceStore.matchOptions) { a, _ in a },
                skin: SnakeChoiceStore.skinId) {
                openMatch = OpenMatch(id: id, slug: slug)
            }
        }
    }

    /// Create a match with several opponents and wait in the lobby for them.
    ///
    /// Same shape as `startMatch`, and deliberately so: the difference between a 2-player and
    /// a 4-player match is the number of invites sent, not a different lifecycle.
    private func startMultiMatch(game: Game, conversations: [VConversation],
                                 options: [String: Int] = [:]) async {
        if game.slug == "ludo" && !Self.ludoWalkthroughSeen {
            showLudoWalkthrough = true
            ludoWalkthroughCompletion = {
                Task { await startMultiMatch(game: game, conversations: conversations,
                                             options: options) }
            }
            return
        }
        let opponents: [(userId: String, conversationId: String)] = conversations.compactMap {
            guard let peer = $0.peerUserId, !peer.isEmpty else { return nil }
            return (userId: peer, conversationId: $0.id)
        }
        guard !opponents.isEmpty else { return }

        if let id = await GamesEngine.shared.createMulti(
            slug: game.slug, opponents: opponents, gameName: game.title, options: options) {
            lobby = LobbyArgs(
                id: id,
                slug: game.slug,
                gameName: game.title,
                // Every name, not just the first: in a 4-player lobby "waiting for Priya" when
                // three people were invited is actively misleading about who is missing.
                opponentName: conversations.map(\.title).joined(separator: ", "),
                detailLine: "\(opponents.count + 1) players",
                seatCount: opponents.count + 1)
        }
    }

    /// Create the match — which SENDS THE INVITE into this conversation — then wait in the
    /// lobby. The board only opens once the opponent has actually joined.
    private func startMatch(game: Game, conversation: VConversation,
                            options: [String: Int] = [:],
                            /// Snake only. Forwarded rather than read here so the games that
                            /// have no skin do not have to know one exists.
                            skin: String? = nil) async {
        guard let peer = conversation.peerUserId, !peer.isEmpty else { return }
        if let id = await GamesEngine.shared.create(
            slug: game.slug,
            opponentId: peer,
            conversationId: conversation.id,
            gameName: game.title,
            options: options,
            skin: skin) {
            // The creator WAITS IN THE LOBBY. Opening the board here is what made it look like
            // nothing happened: no opponent means no opening frame, so the board sat on
            // "Setting up…" forever.
            let overs = options["overs"] ?? 0
            lobby = LobbyArgs(
                id: id,
                slug: game.slug,
                gameName: game.title,
                opponentName: conversation.title,
                detailLine: {
                    if overs > 0 { return "\(overs) \(overs == 1 ? "over" : "overs")" }
                    if game.slug == "rps" { return "first to 3" }
                    if game.slug == "snake" {
                        let bots = options["bots"] ?? 0
                        return bots == 0 ? "duel — no bots" : "\(bots) bots"
                    }
                    return ""
                }())
        }
    }
}

// MARK: - Game artwork

/// The shipped artwork for a catalog row, or the reference's gradient when none has shipped.
///
/// ONE PLACE, because four different cards draw a game and every one of them has to make the
/// same call about a game whose art is missing. `icon_key` is looked up by NAME at runtime so
/// adding a game is a DB row plus a drop-in asset — no client change.
struct GameArtwork: View {
    let game: Game
    var glyphSize: CGFloat = 30

    var body: some View {
        if let key = game.iconKey, UIImage(named: key) != nil {
            Image(key)
                .resizable()
                .scaledToFill()
        } else {
            // The reference's id-keyed gradient. Stable across launches, so a game looks the
            // same every time while staying obviously art-less.
            LinearGradient(
                colors: [AvatarPalette.color(for: game.id),
                         AvatarPalette.color(for: game.title).opacity(0.65)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .overlay {
                Image(systemName: game.category.icon)
                    .font(.system(size: glyphSize))
                    .foregroundColor(.white.opacity(0.3))
            }
        }
    }
}

// MARK: - Featured card

private struct FeaturedCard: View {
    let slide: FeaturedGame
    var action: () -> Void = {}

    var body: some View {
        ZStack(alignment: .leading) {
            artwork

            // Left-weighted, so the copy stays readable while the art shows through on the
            // right. A full-width scrim would flatten the illustration the card exists for.
            LinearGradient(
                colors: [VoiidColor.background.opacity(0.96),
                         VoiidColor.background.opacity(0.75),
                         .clear],
                startPoint: .leading, endPoint: .trailing
            )

            VStack(alignment: .leading, spacing: 0) {
                Text(slide.badge)
                    .font(VoiidFont.rounded(10.5, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .tracking(0.8)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(VoiidColor.surfaceRaised.opacity(0.9)))
                    .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))

                Text(slide.title)
                    .font(VoiidFont.rounded(25, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.top, VoiidSpacing.sm + 2)

                Text(slide.subtitle)
                    .font(VoiidFont.rounded(13.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)

                Button {
                    Haptics.tap()
                    action()
                } label: {
                    HStack(spacing: 7) {
                        Text(slide.cta)
                            .font(VoiidFont.rounded(15, .semibold))
                        Image(systemName: "arrow.right")
                            .font(.system(size: 13, weight: .bold))
                    }
                    .foregroundColor(VoiidColor.textOnAccent)
                    .padding(.horizontal, VoiidSpacing.md + 2)
                    .frame(height: 42)
                    .background(Capsule().fill(VoiidColor.accent))
                }
                .buttonStyle(PressableButtonStyle())
                .padding(.top, VoiidSpacing.md)
            }
            .padding(VoiidSpacing.md + 2)
            .frame(maxWidth: 230, alignment: .leading)
        }
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
    }

    /// Real art where it exists, and the reference's gradient where it does not. The
    /// controller glyph the reference overlaid unconditionally would sit on top of the shipped
    /// artwork, so it belongs to the fallback — which is where GameArtwork puts it.
    private var artwork: some View {
        GameArtwork(game: slide.game, glyphSize: 76)
    }
}

// MARK: - Catalog tile

/// One catalog row in the browsable grid. Same card language as the Continue strip so the
/// screen reads as one surface.
private struct GameTile: View {
    let game: Game
    var action: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                GameArtwork(game: game)
                    // 4:3 — the aspect the shipped artwork is authored at.
                    .aspectRatio(4.0 / 3.0, contentMode: .fill)
                    .frame(height: 104)
                    .clipped()

                VStack(alignment: .leading, spacing: 1) {
                    Text(game.title)
                        .font(VoiidFont.rounded(14.5, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)

                    // The seat count, straight off the catalog row — the one fact that
                    // changes what you have to arrange before you can play.
                    Text(game.maxPlayers > 2 ? "Up to \(game.maxPlayers) players" : "2 players")
                        .font(VoiidFont.rounded(11.5))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VoiidSpacing.sm + 2)
            }
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(game.title)
    }
}

// MARK: - Continue card
//
// UNREACHABLE TODAY — the section that draws it is gated off, because nothing can populate a
// progress fraction. Kept intact so the day a resume state ships this needs no layout work.

private struct ContinueCard: View {
    let game: Game
    var action: () -> Void = {}

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                GameArtwork(game: game)
                    .frame(height: 104)
                    .clipped()

                VStack(alignment: .leading, spacing: 6) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.title)
                            .font(VoiidFont.rounded(14.5, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                            .lineLimit(1)

                        Text(game.category.rawValue)
                            .font(VoiidFont.rounded(11.5))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(VoiidSpacing.sm + 2)
            }
            .frame(width: 172)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(VoiidColor.divider, lineWidth: 1)
            )
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(game.title), \(game.category.rawValue)")
    }
}

// MARK: - Friend card
//
// UNREACHABLE TODAY — the section that draws it is gated off, because there is no
// presence-for-games endpoint. Kept intact for the same reason as ContinueCard.

private struct FriendCard: View {
    let friend: GameFriend

    var body: some View {
        // NOT A BUTTON ANY MORE. The reference's card was tappable and its action was
        // `Haptics.tap()` — a press state, a haptic, and nothing else. A control that
        // acknowledges a press and then does nothing is worse than a card that never
        // offered: it teaches the user that this screen's affordances lie (§16.4).
        //
        // There IS a real destination — the entry flow, pre-set to this person — but it
        // belongs to a GAME, and this card names no game. Choosing one on the user's behalf
        // would be the screen deciding what they came to play. So the card states a fact and
        // the games above it remain the way in.
        HStack(spacing: 10) {
            ProfilePhoto(name: friend.name, size: 42, allowFallbackPhoto: true)
                .overlay(alignment: .bottomTrailing) {
                    Circle()
                        .fill(VoiidColor.success)
                        .frame(width: 12, height: 12)
                        .overlay(Circle().stroke(VoiidColor.surfaceCard, lineWidth: 2))
                }

            VStack(alignment: .leading, spacing: 1) {
                Text(friend.name)
                    .font(VoiidFont.rounded(14.5, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)

                // The ONLY claim presence supports. "Playing" and the game name are gone —
                // nothing in the backend knows what anyone is doing. See `GameFriend`.
                Text("Online")
                    .font(VoiidFont.rounded(12, .medium))
                    // Small type wants slightly positive tracking (§15).
                    .tracking(0.1)
                    .foregroundColor(VoiidColor.accentInk)
            }

            Spacer(minLength: 0)
        }
        .padding(VoiidSpacing.sm + 2)
        // Narrower than the reference's 258 — that width was sized around a 44pt game-art
        // tile and a third line of text, neither of which exists now. `fixedSize` on the
        // height lets the card grow with Dynamic Type instead of clipping the name.
        .frame(width: 200)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(friend.name), online")
    }
}

// MARK: - Tournament card

/// One real tournament.
///
/// ── WHAT THE REFERENCE CARD LOST ────────────────────────────────────────────────
/// The entry-fee pill and the Prize Pool stat, both denominated in V Coins. Neither column
/// exists on the tournaments table and there is no currency to denominate them in — see the
/// file note. The `affordable` gate that greyed the Join button went with them; the button is
/// now gated on the SERVER's registration window instead, which is a real constraint.
private struct TournamentCard: View {
    let tournament: Tournament
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            trophy

            VStack(alignment: .leading, spacing: 3) {
                Text(tournament.title)
                    .font(VoiidFont.rounded(17, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)

                Text(tournament.format)
                    .font(VoiidFont.rounded(12.5))
                    .foregroundColor(VoiidColor.textSecondary)
                    .lineLimit(2)

                HStack(alignment: .top, spacing: VoiidSpacing.lg) {
                    stat("Status") {
                        Text(tournament.statusText)
                            .font(VoiidFont.rounded(14.5, .semibold))
                            .foregroundColor(VoiidColor.textPrimary)
                    }

                    // Drawn only when the server actually set a start time. A countdown to a
                    // moment nobody scheduled is worse than no countdown.
                    if let starts = tournament.startsText {
                        stat("Starts") {
                            HStack(spacing: 5) {
                                Image(systemName: "clock")
                                    .font(.system(size: 11))
                                    .foregroundColor(VoiidColor.textSecondary)
                                Text(starts)
                                    .font(VoiidFont.rounded(14.5, .semibold))
                                    .foregroundColor(VoiidColor.textPrimary)
                                    .monospacedDigit()
                            }
                        }
                    }
                }
                .padding(.top, VoiidSpacing.sm)
            }

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: VoiidSpacing.md) {
                Spacer(minLength: 0)

                // Registration is only offered while the server would actually accept it.
                // Every other state gets no button rather than one that 409s — the same rule
                // CommunityTournamentsSection applies.
                if tournament.isOpen {
                    Button {
                        Haptics.tap()
                        onToggle()
                    } label: {
                        Text(tournament.registered ? "Withdraw" : "Join Now")
                            .font(VoiidFont.rounded(14.5, .semibold))
                            .foregroundColor(tournament.registered ? VoiidColor.textPrimary
                                                                   : VoiidColor.textOnAccent)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(height: 40)
                            .background(
                                Capsule().fill(tournament.registered ? VoiidColor.surfaceRaised
                                                                     : VoiidColor.accent)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .stroke(VoiidColor.divider, lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tournament.title), \(tournament.format), \(tournament.statusText)")
    }

    private func stat<Content: View>(_ label: String,
                                     @ViewBuilder value: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(VoiidFont.rounded(11))
                .foregroundColor(VoiidColor.textSecondary)
            value()
        }
    }

    private var trophy: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(VoiidColor.accentTint)
                .frame(width: 62, height: 62)

            Image(systemName: "trophy.fill")
                .font(.system(size: 26))
                .foregroundColor(VoiidColor.accentInk)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(VoiidColor.accent.opacity(0.3), lineWidth: 1)
        )
    }
}

// MARK: - Availability shim

/// Applies the reference's soft top scroll-edge effect where the OS has it.
///
/// The reference app targets iOS 26 and calls `.scrollEdgeEffectStyle(.soft, for: .top)`
/// directly. Voiid's deployment target is lower, so the call has to be guarded — and a guard
/// cannot sit inline in a modifier chain without changing the view's type on both branches.
private struct SoftTopScrollEdge: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.scrollEdgeEffectStyle(.soft, for: .top)
        } else {
            content
        }
    }
}
