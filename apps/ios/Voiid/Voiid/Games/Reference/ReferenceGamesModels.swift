//
//  ReferenceGamesModels.swift
//  Voiid
//
//  Games — the arcade tab.
//
//  ── WHAT CHANGED WHEN THIS WAS WIRED UP ─────────────────────────────────────────
//  `GamesStore` was a bag of literals: three invented featured slides, three fake "continue
//  playing" cards, three fake friends, two fake tournaments and a V Coin balance of 2,450.
//  It is now a LIVE ADAPTER over the real backend — `GamesAPI.catalog()` for the games and
//  their categories, `GamesAPI.invites()` for incoming invites, `TournamentService.list()`
//  for tournaments — republished in the shape the ported screens already read.
//
//  The adapter shape was chosen deliberately, exactly as `MapStore` was: GamesScreen and its
//  four pushed screens are a signed-off, byte-for-byte port of the design reference. Keeping
//  `GamesStore` as their interface means the screen still reads `store.games`, `store.featured`,
//  `store.category`, `store.tournaments` and essentially none of its layout had to move.
//
//  ── V COINS ARE GONE, AND THAT IS THE ONE DELIBERATE VISUAL CHANGE ──────────────
//  The reference modelled a currency: a header pill reading "2,450", a per-tournament entry
//  fee, a prize pool, and a `canAfford` gate on the Join button. VOIID HAS NO CURRENCY. There
//  is no wallet table, no balance route, no ledger, and no entry-fee or prize column on the
//  tournaments table. A number rendered in a pill next to a coin glyph is read by a user as
//  their balance — as a fact about their account — so shipping a literal there would be
//  fiction presented as truth, not placeholder art.
//
//  So `balance`, `balanceText`, `canAfford` and the fee/prize fields are REMOVED rather than
//  zeroed. Removed, because a zeroed balance still renders a pill that claims the user has an
//  account with 0 coins in it, and because a property that exists is a property the next
//  reader wires up. If a currency ever ships, it comes back here first.
//  DO NOT RE-ADD THESE FROM THE REFERENCE.
//
//  ── WHAT ELSE HAS NO BACKEND ────────────────────────────────────────────────────
//  * FEATURED: the `games` table carries no editorial or promoted flag. The carousel is kept
//    (signed-off layout) but populated with the first N catalog rows in the server's own
//    order — the same choice `GamesHomeView` documents and for the same reason. It is a
//    bigger view of rows that are also in the grid, not a promotion nobody authored.
//  * CONTINUE PLAYING: there is no session-resume state anywhere. `GamesAPI.matches()`
//    returns finished/abandoned history with no progress fraction, so a "72%" bar would be
//    invented. The section is HIDDEN — see `hasContinuePlaying`.
//  CONTINUE PLAYING is hidden rather than shown empty: a section that is permanently empty is
//  clutter that teaches the user to scroll past that part of the screen forever.
//
//  ── FRIENDS ONLINE: NO LONGER HIDDEN ────────────────────────────────────────────
//  This note used to say there was no presence backend. That was wrong. The WebSocket relay
//  has always written a 60-second Redis heartbeat per connected user, and the API has always
//  served it through the `last_seen_privacy` gate. What was missing was a BATCH read, so
//  `POST /users/presence` was added — same gate, applied per user, one round trip.
//
//  The section is now live, but strictly narrower than the reference's: presence answers
//  "awake", not "playing Turbo Rush". See `GameFriend` for exactly which fields were removed
//  and why, and `refreshFriends` for who counts as a friend.
//

import SwiftUI

// MARK: - Games

/// What kind of game it is. Doubles as the Categories row, so the two can never disagree about
/// which categories exist.
///
/// NOW SERVER-DERIVED. The reference hardcoded six categories (Arcade, Puzzle, Strategy,
/// Trivia, Racing, Party) as an enum; Voiid's catalog carries a real `category` column
/// ('board', 'arcade', 'card', …) and a new category is expected to ship as a DB row, exactly
/// like a new game. An enum cannot represent a value the server invents after the app shipped,
/// so this became a struct wrapping the raw column value. `allCases` is gone with it — the
/// chip row now iterates the categories actually present in the catalog (`GamesStore.categories`),
/// which is what stops the row offering "Racing" when no racing game exists.
struct GameCategory: Identifiable, Hashable {
    /// The catalog's own `category` value, verbatim. The identity — never the display string.
    let raw: String

    var id: String { raw }

    /// Display name. Known values get proper copy; anything else is capitalised rather than
    /// dropped, so a category shipped tonight renders tonight.
    var rawValue: String {
        switch raw {
        case "board":  "Board"
        case "arcade": "Arcade"
        case "card":   "Card"
        case "puzzle": "Puzzle"
        case "word":   "Word"
        case "sports": "Sports"
        default:       raw.capitalized
        }
    }

    /// The chip glyph. A lookup with a general fallback, for the same reason `rawValue` has
    /// one: an unknown category must still draw.
    var icon: String {
        switch raw {
        case "board":  "square.grid.3x3.fill"
        case "arcade": "gamecontroller.fill"
        case "card":   "suit.spade.fill"
        case "puzzle": "puzzlepiece.fill"
        case "word":   "textformat.abc"
        case "sports": "figure.run"
        default:       "gamecontroller.fill"
        }
    }
}

/// One playable game, as the screen reads it.
///
/// Built from a `GamesAPI.CatalogGame` and nothing else. Every field is carried by that row or
/// derived from it.
struct Game: Identifiable, Hashable {
    /// The catalog row's id. Stable and what every API call is keyed on.
    let id: String
    /// The slug — `create`/`join` and every renderer switch use this, not the id.
    let slug: String
    let title: String
    let category: GameCategory
    /// Straight off the catalog row. The one fact that changes what you must arrange before
    /// you can play — and what decides whether this game gets the seat picker.
    let minPlayers: Int
    let maxPlayers: Int
    /// The shipped artwork's asset name. Nil when the game has no art yet, which the cards
    /// already handle with a tinted glyph fallback.
    let iconKey: String?

    // NO `progress` AND NO `isResuming`, BY DECISION. Both existed only to drive the Continue
    // Playing cards, and nothing on the server can populate either: a match row carries a
    // status ('waiting' | 'active' | 'finished' | 'abandoned') and timestamps, never a
    // completion fraction. A field nothing can fill is a field the next reader wastes an hour
    // sourcing — see the file note on hidden sections.
}

// MARK: - Featured

/// A carousel slide.
///
/// NOT AN EDITORIAL SURFACE. There is no featured/promoted flag on the games table, so this is
/// built from ordinary catalog rows in the server's own order — see the file note. `badge` is
/// therefore always the neutral seat count rather than "FEATURED" / "NEW" / "EVENT", which
/// would each be a claim nobody authored.
struct FeaturedGame: Identifiable, Hashable {
    let id: String
    let badge: String
    let title: String
    let subtitle: String
    let cta: String
    /// The catalog row this slide draws. Held so tapping the slide can open the real setup
    /// flow for the real game, rather than a detail screen about nothing.
    let game: Game

    /// One catalog row, at carousel size.
    init(game: Game) {
        self.id = game.id
        self.game = game
        self.title = game.title
        // The seat count, straight off the catalog row — the same line GamesHomeView's
        // featured card shows, and the only honest thing there is to say about a game here.
        self.badge = game.category.rawValue.uppercased()
        self.subtitle = game.maxPlayers > 2
            ? "Up to \(game.maxPlayers) players.\nPlay a friend or a bot."
            : "Two players.\nPlay a friend or a bot."
        self.cta = "Play"
    }
}

// MARK: - Friends
//
// NOW POPULATED, AND NARROWER THAN THE REFERENCE'S. The reference's card claimed a `status`
// ("Playing" / "In Lobby") and a `game` ("Turbo Rush"), and rendered that game's art beside
// the person. Voiid's presence backend answers ONE question — is this account's WebSocket
// heartbeat alive within the last 60 seconds — and it cannot answer either of the others:
// there is no per-user "currently in match X" index anywhere, and `game_lobbies` is not
// queryable by member for this purpose.
//
// So `status`, `game` and `gameID` are REMOVED rather than filled with a plausible default.
// A card reading "Playing · Ludo" beside someone who is merely awake is a specific claim
// about what another person is doing right now, and it would be false most of the time.
// What survives is what is true: this is someone you have a direct chat with, and they are
// online. DO NOT RE-ADD THE STATUS OR GAME FIELDS FROM THE REFERENCE without a backend that
// can actually answer them.

struct GameFriend: Identifiable, Hashable {
    /// The peer's user id — the identity presence was resolved for.
    let id: String
    let name: String
    /// The conversation that made them a "friend". Carried so the card can hand the entry
    /// flow the same `VConversation` the opponent picker would have used.
    let conversationId: String
    /// Their avatar, when the conversation resolved one.
    let photoURL: String?
}

// MARK: - Tournaments

/// A tournament, as the card reads it.
///
/// GENUINELY REAL — this maps `TournamentService.Tournament`, which is a shipped backend with
/// brackets, seeding, registration and standings.
///
/// NO ENTRY FEE AND NO PRIZE POOL. The reference card rendered both as V Coin amounts; the
/// real row has neither column, and there is no currency to denominate them in anyway. Both
/// fields are removed and the card's fee pill and prize stat go with them — see the file note.
struct Tournament: Identifiable, Hashable {
    let id: String
    let title: String
    /// "Ludo · 6/16 players · Open for entries" — assembled from the fields the row actually
    /// carries, the same way CommunityTournamentsSection builds its subtitle.
    let format: String
    /// The server's status vocabulary, verbatim: draft | registering | running | finished |
    /// cancelled. Kept raw because it is a state machine, not display copy — `isOpen` is the
    /// only thing the screen asks of it.
    let status: String
    /// Whether YOU are on the roster. Decides Register vs Withdraw.
    let registered: Bool
    /// Which community it belongs to. Registration is community-scoped and the caller needs it
    /// to reload the right list afterwards.
    let communityId: String

    /// Only 'registering' accepts a join. Every other state gets no button rather than one
    /// that 409s — the same rule CommunityTournamentsSection already applies.
    var isOpen: Bool { status == "registering" }

    /// "Open for entries". The server names states for what they ARE; this is the reading.
    var statusText: String {
        switch status {
        case "draft":       "Not open yet"
        case "registering": "Open for entries"
        case "running":     "In progress"
        case "finished":    "Finished"
        case "cancelled":   "Cancelled"
        default:            status
        }
    }

    // NO `startsIn` COUNTDOWN. The row carries `starts_at` as an optional ISO-8601 string and
    // frequently omits it entirely (a draft has no start time yet). The reference rendered an
    // unconditional HH:MM:SS ticking clock, which for a tournament with no start time would
    // have counted down to a moment nobody scheduled. `startsText` answers honestly or says
    // nothing.
    let startsAt: Date?

    /// "in 2h 15m", or nil when the server has not set a start time. The card draws the stat
    /// only when this is non-nil.
    var startsText: String? {
        guard let startsAt else { return nil }
        let seconds = Int(startsAt.timeIntervalSinceNow)
        guard seconds > 0 else { return "Started" }
        let h = seconds / 3600, m = (seconds % 3600) / 60
        if h >= 24 { return "in \(h / 24)d" }
        if h > 0 { return "in \(h)h \(m)m" }
        return "in \(m)m"
    }

    init(_ t: TournamentService.Tournament, communityId: String) {
        self.id = t.id
        self.title = t.name
        self.status = t.status ?? ""
        self.registered = t.registered ?? false
        self.communityId = communityId

        var parts: [String] = []
        if let g = t.game_name { parts.append(g) }
        if let n = t.player_count {
            parts.append(t.max_players.map { "\(n)/\($0) players" } ?? "\(n) players")
        }
        if let f = t.format {
            switch f {
            case "single_elim": parts.append("Single elimination")
            case "double_elim": parts.append("Double elimination")
            case "round_robin": parts.append("Round robin")
            default:            parts.append(f.replacingOccurrences(of: "_", with: " "))
            }
        }
        self.format = parts.joined(separator: " · ")

        self.startsAt = t.starts_at.flatMap(Self.parse)
    }

    /// pg emits ISO-8601; whether it carries fractional seconds varies by column type, so both
    /// are tried rather than assuming one.
    private static func parse(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Feed state

/// What the catalog is doing right now.
///
/// Loading / empty / failed must be three distinguishable things: "the server has no games
/// enabled" is a correct, settled answer, and "we couldn't load" is a fault. Collapsing them
/// into one empty view tells a user the arcade is empty when in fact the request failed.
enum GamesFeedState: Equatable {
    case loading
    case loaded
    /// The fetch worked and the catalog is empty.
    case empty
    /// The fetch failed. Carries a message.
    case failed(String)
}

// MARK: - Store

/// The games tab's state, shared across the screens of the flow.
///
/// NOW A LIVE ADAPTER. It calls the real API on `load()` and republishes the results in the
/// shape the reference screens already read. It owns no game state of its own and persists
/// nothing; the actual match lifecycle belongs to `GamesEngine`, which this never touches.
@Observable
@MainActor
final class GamesStore {

    // MARK: Backend-derived, read-only

    /// The catalog, in the server's order.
    var games: [Game] = []
    var feedState: GamesFeedState = .loading

    /// The carousel. Catalog rows at a larger size — NOT a promotion. See the file note.
    ///
    /// Suppressed below three, exactly as `GamesHomeView` does: a carousel of two is a worse
    /// grid, and the page dots under one slide are noise.
    var featured: [FeaturedGame] {
        // Built from `shelf`, not `games`: a game the user hid must not reappear as a
        // 200pt carousel slide, which would be the single most prominent place on the tab
        // to contradict a setting they just changed.
        let shelf = self.shelf
        return shelf.count >= 3 ? shelf.prefix(3).map(FeaturedGame.init) : []
    }

    /// PERMANENTLY EMPTY — no session-resume state exists. See the file note. Kept as a
    /// property so the ported section body compiles untouched; `hasContinuePlaying` is what
    /// keeps it off the screen.
    var continuePlaying: [Game] { [] }
    var hasContinuePlaying: Bool { !continuePlaying.isEmpty }

    // ── FRIENDS ONLINE — NOW LIVE ───────────────────────────────────────────────
    //
    // This section was hidden on the belief that no presence backend existed. One does:
    // the WebSocket relay writes `user:<id>:online` into Redis with a 60s TTL, and the API
    // serves it through the last_seen_privacy gate. What did not exist was a way to ask
    // about MANY people at once; `POST /users/presence` is that, and it applies the same
    // per-user gate as the single route.
    //
    // WHAT "FRIEND" MEANS HERE, AND WHY. Voiid has no friend graph. The three candidates
    // were `contact_sync` (your phone's address book — people who have never used Voiid,
    // and people you have never spoken to), `creator_follows` (a one-way subscription; a
    // creator you follow is not someone you invite to Ludo), and DIRECT CONVERSATIONS.
    // Direct conversations win: a person you have a one-to-one thread with is someone you
    // have mutually chosen to talk to, they are reachable right now, and — decisively —
    // it is ALREADY what this tab means by an opponent. `GameEntryFlow.candidates` picks
    // the match roster from exactly this set. Any other definition would put a face in
    // "Friends Online" that the very next screen refuses to let you play against.
    //
    // NOTHING IS INFERRED. `online` comes from the server or it does not come at all.
    // There is no "recently active" fallback and no reading of message timestamps: a
    // person whose privacy setting hides them is simply not here, and looks identical to
    // a person who is asleep. That is the point of the gate.

    /// People with a direct conversation who the server says are online RIGHT NOW.
    /// Empty until `refreshFriends` has succeeded at least once.
    var friends: [GameFriend] = []
    /// Presence has its own three states — the catalog can be fine while this fails.
    var friendState: GamesFeedState = .loading
    /// Whether anyone could POSSIBLY appear. False when the user has no direct chats at
    /// all, which is a different fact from "nobody is online" and hides the section
    /// outright rather than promising a row that can never fill.
    var hasAnyPeers = false

    /// Draw the section at all?
    ///
    /// Deliberately NOT `!friends.isEmpty`. A failed fetch must not read as "nobody is
    /// online" — that is a lie the user would act on — so `.failed` keeps the section on
    /// screen to say so. A successful fetch that found nobody hides it, because an empty
    /// shell teaches the user to scroll past this part of the screen forever.
    var showFriendsSection: Bool {
        guard hasAnyPeers else { return false }
        switch friendState {
        case .loading: return false   // nothing to say yet; the section appears when it has news
        case .loaded:  return !friends.isEmpty
        case .empty:   return false   // asked, answered: nobody is online
        case .failed:  return true    // say so rather than imply an empty room
        }
    }

    /// Real tournaments, across every community the user belongs to.
    var tournaments: [Tournament] = []
    /// Tournaments have their own three states: the catalog can load fine while this fails,
    /// and vice versa — they are separate round-trips to separate services.
    var tournamentState: GamesFeedState = .loading

    /// Whether the user belongs to ANY community.
    ///
    /// WHY THIS EXISTS: "no tournaments" has two completely different causes and the same
    /// empty list. Tournaments are community-scoped by design — there is no global tournaments
    /// route — so a user in no community has none BY DEFINITION and nothing they do on this
    /// tab will ever change that. A user who IS in communities and sees none is simply between
    /// events. Showing the same blank space for both leaves the first user hunting for a
    /// feature that was never going to appear here. Set on every `loadTournaments()`.
    var inAnyCommunity = false

    /// Live invites waiting on the user. Real, from `GamesAPI.invites()`.
    var invites: [GamesAPI.PendingInvite] = []
    /// Match ids acknowledged this session. A MISSED invite is information you need once;
    /// without this, dismissing one would bring it straight back on the next poll. Same
    /// mechanism as `GamesHomeView.dismissed`.
    var dismissed: Set<String> = []

    /// Invites actually worth drawing.
    var visibleInvites: [GamesAPI.PendingInvite] {
        invites.filter { !dismissed.contains($0.match_id) }
    }

    // MARK: Screen-local UI state

    /// nil means "no filter" — the row is a filter, and a filter that cannot be cleared is a
    /// trap. Tapping the active category again clears it.
    var category: GameCategory?

    /// The categories the catalog ACTUALLY contains, in the order they first appear in the
    /// server's response — so the backend still decides what comes first. Not a fixed enum:
    /// offering a chip that filters to nothing is a dead control.
    var categories: [GameCategory] {
        var seen = Set<String>()
        // Over `shelf`, for the same reason the row exists at all: a chip whose only games
        // are hidden would filter to an empty grid, which is precisely the dead control this
        // property was written to prevent.
        return shelf.compactMap { game in
            guard seen.insert(game.category.raw).inserted else { return nil }
            return game.category
        }
    }

    // ── PER-GAME VISIBILITY ─────────────────────────────────────────────────────
    //
    // The user's own shelf. A game hidden in Games settings disappears from the carousel,
    // the category chips and the grid — every browsing surface on this tab — and from
    // nowhere else. It is not moderation: an invite to a hidden game still arrives (the
    // banners read `visibleInvites`, which never consults this), still joins, and still
    // opens its renderer. Match history and the leaderboard are likewise untouched, because
    // a match you played is a fact about your past, not a shelf listing.
    //
    // FAILS OPEN, DELIBERATELY. `hiddenSlugs` starts empty and is only ever narrowed by a
    // SUCCESSFUL fetch. A preferences call that times out therefore leaves every game
    // visible rather than hiding the tab behind a network error — the opposite default
    // would turn one dropped request into an app that looks broken and offers no clue why.

    /// Slugs this user has switched off. Empty until `loadVisibility` succeeds.
    var hiddenSlugs: Set<String> = []

    /// The catalog minus what this user hid. Everything browsable reads THIS, not `games`.
    var shelf: [Game] {
        hiddenSlugs.isEmpty ? games : games.filter { !hiddenSlugs.contains($0.slug) }
    }

    /// True when a non-empty catalog has been hidden down to nothing BY THE USER.
    ///
    /// The distinction the empty state depends on: `games.isEmpty` means the server sent no
    /// catalog, which the user cannot fix from here, while this means they hid every row and
    /// the fix is two taps away. Same list, two completely different sentences.
    var everythingHidden: Bool { !games.isEmpty && shelf.isEmpty }

    /// The catalog under the current filter.
    var visibleGames: [Game] {
        guard let category else { return shelf }
        return shelf.filter { $0.category == category }
    }

    // MARK: Wiring

    @ObservationIgnored private let api = GamesAPI()

    /// Pull the catalog. Three distinguishable outcomes — see `GamesFeedState`.
    func load() async {
        feedState = .loading
        do {
            let catalog = try await api.catalog()
            games = catalog.map {
                Game(id: $0.id,
                     slug: $0.slug,
                     title: $0.name,
                     category: GameCategory(raw: $0.category),
                     minPlayers: $0.min_players,
                     maxPlayers: $0.max_players,
                     iconKey: $0.icon_key)
            }
            // If the active filter's category vanished from the catalog, clear it rather than
            // leaving the screen filtered to an empty set with no way to tell why.
            if let category, !categories.contains(category) { self.category = nil }
            feedState = games.isEmpty ? .empty : .loaded
        } catch {
            // A FAILED FETCH MUST NEVER RENDER AS AN EMPTY LIST. The previous list is left in
            // place — stale games are still playable — and the state says what happened.
            feedState = .failed("Couldn't load games")
        }
    }

    /// Pull the hidden set. Called alongside `load()`.
    ///
    /// SILENT ON FAILURE, AND THAT IS THE POINT. There is no `visibilityState` and no error
    /// banner: the only consequence of a failed fetch is that `hiddenSlugs` stays as it is
    /// (empty on a cold start), so every game shows. A user seeing one game they meant to
    /// hide is a far smaller failure than a user seeing an error where their games were,
    /// and the settings screen — which CAN act on the error — reports it there instead.
    func loadVisibility() async {
        if let fresh = try? await api.visibility() { hiddenSlugs = Set(fresh) }
    }

    /// Refresh the invite banners. Called on a poll, so it deliberately does NOT touch
    /// `feedState`: a dropped invite poll must not blank the catalog.
    func refreshInvites() async {
        if let fresh = try? await api.invites() { invites = fresh }
    }

    /// Who, of the people you have a direct conversation with, is online right now.
    ///
    /// Takes the roster as an argument rather than reaching for `ChatStore` itself: this
    /// store owns no dependencies on the chat layer, and the screen already holds that list
    /// for the opponent picker. One source of truth for "who counts", shared by both.
    ///
    /// FAILURE IS NOT EMPTINESS. On a thrown request the previously-known list is LEFT IN
    /// PLACE and the state becomes `.failed`. Blanking it would tell the user everyone went
    /// offline in the last minute, which is a claim the failed request did not make.
    func refreshFriends(peers: [VConversation]) async {
        // Same filter the entry flow's `candidates` uses — direct chats whose peer we can
        // actually name. Self-chats have no peer id and drop out here, which is right: you
        // are not your own opponent.
        let named: [(userId: String, convo: VConversation)] = peers.compactMap { convo in
            guard convo.type == .direct, let peer = convo.peerUserId, !peer.isEmpty else { return nil }
            return (peer, convo)
        }
        // Deduplicated by peer: two conversations with the same person must not draw two
        // cards, and must not cost two entries against the server's batch cap.
        var seen = Set<String>()
        let unique = named.filter { seen.insert($0.userId).inserted }

        hasAnyPeers = !unique.isEmpty
        guard !unique.isEmpty else {
            friends = []
            friendState = .empty
            return
        }

        do {
            let presence = try await ChatService.shared.presence(userIds: unique.map(\.userId))
            // ONLY genuinely-online people. An id the server did not answer for is absent
            // from the map, and absent is not offline — but it is also not a licence to
            // show them, so it falls out here either way.
            friends = unique.compactMap { entry in
                guard presence[entry.userId]?.online == true else { return nil }
                return GameFriend(id: entry.userId,
                                  name: entry.convo.title,
                                  conversationId: entry.convo.id,
                                  photoURL: entry.convo.photoURL)
            }
            friendState = friends.isEmpty ? .empty : .loaded
        } catch {
            friendState = .failed("Couldn't check who's online")
        }
    }

    /// Acknowledge an invite locally at once so the banner goes immediately, then tell the
    /// server. A failed decline is harmless — the invite expires anyway.
    func dismissInvite(_ matchId: String) {
        dismissed.insert(matchId)
        Task { try? await api.decline(matchId: matchId) }
    }

    /// Every tournament in every community the user belongs to.
    ///
    /// FANNED OUT, because the tournaments API is community-scoped by design — there is no
    /// "all my tournaments" route, and inventing a global list would mean showing brackets
    /// from spaces the user is not in. A community whose list fails is skipped rather than
    /// failing the whole section; only a total failure (including the membership fetch) is
    /// reported as one.
    func loadTournaments() async {
        tournamentState = .loading
        guard let mine = try? await CommunityService.shared.mine() else {
            tournamentState = .failed("Couldn't load tournaments")
            return
        }
        // Recorded BEFORE the per-community fan-out, so the empty state can tell "you are in no
        // communities" apart from "your communities have nothing running".
        inAnyCommunity = mine.contains { $0.isMember }
        var out: [Tournament] = []
        for community in mine where community.isMember {
            guard let list = try? await TournamentService.shared.list(communityId: community.id)
            else { continue }
            out += list.map { Tournament($0, communityId: community.id) }
        }
        // Open ones first — a tournament you can still enter outranks one already running,
        // which outranks one that is over. Within a bucket, soonest first.
        tournaments = out.sorted { a, b in
            if a.isOpen != b.isOpen { return a.isOpen }
            switch (a.startsAt, b.startsAt) {
            case let (x?, y?): return x < y
            case (_?, nil):    return true
            case (nil, _?):    return false
            default:           return a.title < b.title
            }
        }
        tournamentState = tournaments.isEmpty ? .empty : .loaded
    }

    /// Join or leave a tournament roster, then re-read. The server owns capacity and the
    /// registration window — several people may be racing for the last slot — so the result is
    /// re-read rather than assumed.
    func toggleRegistration(_ tournament: Tournament) async {
        do {
            if tournament.registered {
                try await TournamentService.shared.withdraw(id: tournament.id)
            } else {
                try await TournamentService.shared.register(id: tournament.id)
            }
        } catch {
            // Fall through to the reload: it shows what is actually true either way.
        }
        await loadTournaments()
    }
}

// MARK: - The match flow
//
// Invite → details → the real lobby. Three steps, because each owns a genuinely different
// question: WHO asked you, WHAT the game is, and WHO is coming.

/// A friend's invitation to play. Arrives as a sheet over the home screen.
///
/// NOW BUILT FROM A REAL `GamesAPI.PendingInvite` — the envelope the server actually sends,
/// carrying the match id the Join button opens.
struct RefGameInvite: Identifiable, Hashable {
    let id: String
    let from: String
    let gameTitle: String
    let format: String
    let mode: String
    let slots: String
    /// The real match to open on Join. This is the whole point of the sheet.
    let matchId: String
    /// Chooses the renderer, exactly as `GamesHomeView.OpenMatch.slug` does.
    let slug: String

    init(_ invite: GamesAPI.PendingInvite) {
        self.id = invite.match_id
        self.matchId = invite.match_id
        self.slug = invite.slug
        // "Someone" is the honest reading of an invite whose inviter row hasn't resolved —
        // never a raw uuid, and never a fabricated name.
        self.from = invite.inviter_name ?? "Someone"
        self.gameTitle = invite.name
        // Hand cricket is the one game whose invite carries a setting; every other game has
        // nothing to say here, so it says nothing rather than inventing a format string.
        self.format = invite.overs > 0
            ? "\(invite.overs) \(invite.overs == 1 ? "over" : "overs")"
            : ""
        self.mode = "1v1"
        // NO "3/3 Players". The invites route returns no roster, so the slot count cannot be
        // known here. The two-seat reading is the only one every current invite satisfies —
        // a multi-seat invite is still an invitation to one seat, which is yours.
        self.slots = "Your seat"
    }
}

// ── SUPERSEDED: `GameMode`, `PartyStatus`, `PartyMember`, `LobbyMessage` and `LobbyState` ARE
// BACK, and they live in Games/Reference/LobbyState.swift.
//
// The note below is kept as the record of why they were once deleted, and its reasoning was
// right for the code that existed then: the reference lobby needed ready-states, a join code
// and a chat, and Voiid had none of the three. THAT IS WHAT CHANGED —
// database/migrations/052_game_lobbies.sql and the lobby routes in backend/api's games.ts now
// provide exactly those, so the screens are wired to real columns rather than to samples. The
// objection was answered, not overruled.
//
// What still has no source is recorded per-property in LobbyState.swift: `pending` (no column
// separates invited-to-a-party from seated-in-a-match), and the local-only controls
// (`voiceChat` — there is NO voice transport — plus `difficulty` and `crossplay`). The frozen
// reference layout renders all of them; none of them transmits anything.
//
// ── the original note ──
// NO `GameMode`, `PartyStatus`, `PartyMember` OR `LobbyMessage`, AND NO `LobbyState`.
//
// The reference's lobby was a PARTY lobby: solo/duo/squad modes, per-member ready-states, a
// host badge, per-member mic toggles, a chat with quick reactions, a copyable team code, a
// public/private room switch, and crossplay / voice-chat / fill-empty toggles.
//
// VOIID'S LOBBY IS NONE OF THAT. It is a two-party (or multi-seat) invite that waits for
// acceptance: `GameLobbyView` sends the invite through the E2EE message pipe and watches for
// the opening `game_state` frame, which only arrives once every seat is filled. There is no
// ready-state to set, no lobby chat channel, no team code, no voice transport, no crossplay
// concept and no matchmaking to fill empty seats with strangers.
//
// So the ported `GameLobbyScreen` and `MatchStartingScreen` are NOT wired — they are kept as
// unreferenced files for the design record, and the flow routes through the real
// `GameLobbyView` instead. Binding the reference lobby to `player_ids` would have meant
// shipping ready-state checkmarks nothing sets, a chat that sends nowhere and a countdown to
// a moment no server schedules; deleting `GameLobbyView` to replace it would have meant
// rewriting working invite plumbing to look like a party screen. Neither is honest.
// See the note at the top of GamesScreen for the routing.
