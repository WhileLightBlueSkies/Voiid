//
//  GamesModels.swift
//  Voiid
//
//  Data models and store for the arcade hub.
//

import SwiftUI

// MARK: - Games

enum GameCategory: String, CaseIterable, Identifiable, Hashable {
    case board = "Board"
    case arcade = "Arcade"
    case puzzle = "Puzzle"
    case trivia = "Trivia"
    case party = "Party"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .board:  "dice"
        case .arcade: "gamecontroller"
        case .puzzle: "puzzlepiece"
        case .trivia: "questionmark.circle"
        case .party:  "person.3"
        }
    }
}

struct Game: Identifiable, Hashable {
    let id: String
    let title: String
    let pitch: String
    let category: GameCategory
    var players: String?
    var minutes: String?
    var isPlayable: Bool = false
    /// The server says this build's copy is below the game's min_app: drawn, not playable.
    var needsUpdate: Bool = false
    /// The admin panel's teaser, for a game the server lists as announced.
    var teaser: String?
    var tintA: Color = VoiidColor.accent
    var tintB: Color = VoiidColor.accentSoft
    var symbol: String = "gamecontroller.fill"

    var lastPlayed: String?
    var bestScore: String?

    static let playable: [Game] = [
        .init(id: "ludo", title: "Ludo",
              pitch: "Roll a six to leave home. First to get all four in wins.",
              category: .board, players: "1–4", minutes: "10–20 min",
              isPlayable: true,
              tintA: Color(ludoHex: 0x13828C), tintB: Color(ludoHex: 0x68B8BD),
              symbol: "dice.fill",
              lastPlayed: "Yesterday", bestScore: "12 wins"),

        .init(id: "carrom", title: "Carrom", pitch: "You play white. Clear your colour to win.",
              category: .board, players: "You + bot", minutes: "5–15 min",
              isPlayable: true,
              tintA: Color(ludoHex: 0x13828C), tintB: Color(ludoHex: 0xE8A72E),
              symbol: "circle.circle.fill"),

        .init(id: "snake", title: "Snake Arena",
              pitch: "Eat, grow, and cut off anyone bigger than you.",
              category: .arcade, players: "You + 11 bots", minutes: "3–8 min",
              isPlayable: true,
              tintA: Color(ludoHex: 0x2FA36B), tintB: Color(ludoHex: 0xE8A72E),
              symbol: "scribble.variable",
              lastPlayed: "2h ago", bestScore: "1,840"),
    ]

    static let upcoming: [Game] = [
        .init(id: "word", title: "Word Duel", pitch: "Two players, one board, seven letters.",
              category: .trivia,
              tintA: Color(ludoHex: 0x3B7DD8), tintB: Color(ludoHex: 0x8BE8EA),
              symbol: "textformat.abc"),
        .init(id: "quiz", title: "Quiz Night", pitch: "Ten questions, everyone at once.",
              category: .trivia,
              tintA: Color(ludoHex: 0x8B5CF6), tintB: Color(ludoHex: 0xE879A6),
              symbol: "questionmark.diamond.fill"),
    ]

    static let all: [Game] = playable + upcoming
}

// MARK: - Modes

struct GameMode: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String
    let humans: Int
    var seats: Int?

    /// One word for the slider's tick labels, where the full title is too long to sit
    /// under a track three across.
    var shortLabel: String {
        switch id {
        case "easy":     "Easy"
        case "moderate": "Moderate"
        case "hard":     "Hard"
        default:         title
        }
    }

    static func modes(for gameID: String) -> [GameMode] {
        switch gameID {
        case "ludo":
            [
                .init(id: "easy", title: "Easy Mode (vs Bots)",
                      detail: "Relaxed bots, gentle moves, easy practice",
                      icon: "leaf.fill", humans: 1, seats: 4),
                .init(id: "moderate", title: "Moderate (vs Bots)",
                      detail: "Standard balanced match against 3 bots",
                      icon: "cpu", humans: 1, seats: 4),
                .init(id: "hard", title: "Hard Mode (vs Bots)",
                      detail: "Aggressive bots that cut and race",
                      icon: "flame.fill", humans: 1, seats: 4),
            ]
        case "carrom":
            [
                .init(id: "solo", title: "Play vs Bot",
                      detail: "You play white, the bot plays black",
                      icon: "cpu", humans: 1, seats: 2),
            ]
        case "snake":
            [
                .init(id: "easy", title: "Easy Mode (Practice)",
                      detail: "Calm arena with fewer bots, relaxed growth",
                      icon: "leaf.fill", humans: 1),
                .init(id: "moderate", title: "Standard Arena",
                      detail: "Competitive 8 bots, balanced speed",
                      icon: "cpu", humans: 1),
                .init(id: "hard", title: "Hardcore Arena",
                      detail: "Fast paced, aggressive hunting bots",
                      icon: "flame.fill", humans: 1),
            ]
        default:
            []
        }
    }
}

// MARK: - Friends

struct GameFriend: Identifiable, Hashable {
    let id: String
    let name: String
    let gameID: String
    let gameTitle: String
    var conversationId: String? = nil
    var photoURL: String? = nil
    var isJoinable: Bool = true
    var isOnline: Bool = false
}

// MARK: - Store

@Observable
final class GamesStore {
    /// Built-in until the server catalog arrives (or when it never has, offline on a first
    /// launch). After that the SERVER decides the shelf — see `apply`.
    var playable: [Game] = Game.playable
    var upcoming: [Game] = Game.upcoming
    var friends: [GameFriend] = []

    // MARK: Server-driven shelf

    /// Loads GET /games and rebuilds the shelf from it. On failure, the last catalog this
    /// device saw is used instead, so a game pulled from the admin panel stays pulled while
    /// offline rather than reappearing from the built-in list.
    @MainActor
    func loadCatalog() async {
        do {
            let rows = try await GamesAPI().catalog().map(ShelfCache.Entry.init)
            ShelfCache.save(rows)
            apply(rows)
        } catch {
            if let cached = ShelfCache.load() { apply(cached) }
        }
    }

    /// The admin panel's release controls, applied.
    ///
    ///   live + playable  → on the shelf.
    ///   live + update    → on the shelf, marked "Update to play" (below the game's min_app).
    ///   announced        → "Coming soon", with the admin's teaser.
    ///   hidden / pulled  → absent: the server never sends those rows.
    ///
    /// A live row this BUILD cannot launch (a game added after it shipped) goes to "Coming
    /// soon" rather than onto the shelf: there is no screen behind it to open.
    func apply(_ rows: [ShelfCache.Entry]) {
        var shelf: [Game] = []
        var soon: [Game] = []
        for row in rows {
            let local = Game.all.first { $0.id == row.slug }
            if row.state != "announced", var game = local, game.isPlayable {
                game.needsUpdate = row.state == "update"
                shelf.append(game)
            } else {
                var game = local ?? Game(
                    id: row.slug, title: row.name,
                    pitch: row.teaser ?? "Coming soon",
                    category: GameCategory(rawValue: row.category.capitalized) ?? .board)
                game.isPlayable = false
                game.teaser = row.teaser
                soon.append(game)
            }
        }
        // Keep the designed order of the built-in shelf rather than the server's A–Z.
        let order = Game.playable.map(\.id)
        playable = shelf.sorted {
            (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max)
        }
        upcoming = soon
    }

    var lastPlayed: Game? { playable.first { $0.lastPlayed != nil } }

    func friends(in gameID: String) -> [GameFriend] {
        friends.filter { $0.gameID == gameID }
    }

    @MainActor
    func loadRealFriends() {
        let allConvs = LocalStore.conversations()
        let direct = allConvs.filter {
            $0.type == .direct &&
            $0.peerUserId != nil &&
            $0.title != "Note to Self" &&
            $0.title != "Unknown" &&
            !$0.title.trimmingCharacters(in: .whitespaces).isEmpty
        }

        var seen = Set<String>()
        var unique: [VConversation] = []
        for c in direct {
            let key = c.peerUserId ?? c.id
            if !seen.contains(key) {
                seen.insert(key)
                unique.append(c)
            }
        }

        self.friends = unique.enumerated().map { idx, c in
            let peer = c.peerUserId ?? c.id
            let assignedGame = idx % 2 == 0 ? "ludo" : "snake"
            let assignedTitle = idx % 2 == 0 ? "Ludo" : "Snake Arena"
            return GameFriend(
                id: peer,
                name: c.title,
                gameID: assignedGame,
                gameTitle: assignedTitle,
                conversationId: c.id,
                photoURL: c.photoURL,
                isJoinable: true,
                isOnline: c.isOnline
            )
        }

        let userIds = unique.compactMap { $0.peerUserId }
        if !userIds.isEmpty {
            Task {
                if let presence = try? await ChatService.shared.presence(userIds: userIds) {
                    await MainActor.run {
                        self.friends = self.friends.map { f in
                            var updated = f
                            if let status = presence[f.id] {
                                updated.isOnline = status.online
                            }
                            return updated
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Shelf cache

/// The last catalog this device received, so the shelf honours the admin panel offline.
/// A convenience copy only: the server re-decides on every successful load.
enum ShelfCache {
    struct Entry: Codable {
        let slug: String
        let name: String
        let category: String
        /// "playable" | "update" | "announced" — the server's `availability`.
        let state: String
        let teaser: String?

        init(_ game: GamesAPI.CatalogGame) {
            slug = game.slug
            name = game.name
            category = game.category
            state = game.state.rawValue
            teaser = game.teaser
        }
    }

    private static let key = "games.shelf.v1"

    static func save(_ entries: [Entry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    static func load() -> [Entry]? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode([Entry].self, from: data)
    }
}
