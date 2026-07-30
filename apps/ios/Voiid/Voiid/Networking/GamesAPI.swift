//
//  GamesAPI.swift
//  Voiid
//
//  Match lifecycle only (docs/GAMES.md §3): the catalog, creating a match, joining one,
//  history. This is the durable, authorized half of the games system.
//
//  There is deliberately NO move endpoint. Moves are WS-only (GamesEngine), for the same
//  reason LocationAPI has no position endpoint: a move is a tiny frame in a stream of
//  them, and an HTTP round-trip per tap would add latency to the one interaction that has
//  to feel immediate.
//

import Foundation

struct GamesAPI {
    private let api = APIClient()

    // MARK: - DTOs

    struct CatalogGame: Decodable, Identifiable {
        let id: String
        let slug: String
        let name: String
        let category: String
        let min_players: Int
        let max_players: Int
        var icon_key: String?
    }
    struct CatalogResponse: Decodable { let games: [CatalogGame] }

    struct CreateBody: Encodable {
        let slug: String
        let opponent_ids: [String]
    }
    struct CreateResponse: Decodable {
        let match_id: String
        let players: [String]
    }
    struct JoinResponse: Decodable { let ok: Bool; let match_id: String }

    /// One opponent's head-to-head record with the caller. Scoped to people actually
    /// played — never a global ranking (see the route header for why).
    struct LeaderboardRow: Decodable, Identifiable {
        let opponent_id: String
        var full_name: String?
        var username: String?
        let played: Int
        let wins: Int
        let draws: Int
        let losses: Int

        var id: String { opponent_id }
        var displayName: String { full_name ?? username ?? "Unknown" }
    }
    private struct LeaderboardResponse: Decodable { let leaderboard: [LeaderboardRow] }

    // MARK: - Calls

    /// Wins per person among people the caller has finished matches with.
    func leaderboard(slug: String? = nil) async throws -> [LeaderboardRow] {
        let path = slug.map { "games/leaderboard?game=\($0)" } ?? "games/leaderboard"
        let res: LeaderboardResponse = try await api.request("GET", path)
        return res.leaderboard
    }

    /// The catalog. Static and small; a caller may cache it for the session.
    func catalog() async throws -> [CatalogGame] {
        let res: CatalogResponse = try await api.request("GET", "games")
        return res.games
    }

    /// Mint a match. The CALLER then sends the invite as an ordinary E2EE message
    /// carrying this id — this endpoint deliberately sends no notification of its own, so
    /// an invite produces exactly one alert, from the message path that already does wake
    /// and push correctly.
    func create(slug: String, opponentIds: [String]) async throws -> String {
        let res: CreateResponse = try await api.request(
            "POST", "games/matches", body: CreateBody(slug: slug, opponent_ids: opponentIds))
        return res.match_id
    }

    /// Enter a match. The opening board does NOT come back here — the server builds it and
    /// broadcasts a `game_state` frame to every player.
    @discardableResult
    func join(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/join",
                              body: EmptyBody())
    }

    private struct EmptyBody: Encodable {}
}
