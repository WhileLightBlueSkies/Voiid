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
        /// Per-game settings chosen at creation (hand cricket's over count). Stored on the
        /// match row and validated by the engine — this client sends, it does not police.
        let options: [String: Int]
        /// Snake's chosen skin id. A separate field because `options` is [String: Int] across
        /// every game, and widening that for one game's cosmetic would touch four others.
        let skin: String?
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
    func create(
        slug: String,
        opponentIds: [String],
        options: [String: Int] = [:],
        skin: String? = nil
    ) async throws -> String {
        let res: CreateResponse = try await api.request(
            "POST", "games/matches",
            body: CreateBody(slug: slug, opponent_ids: opponentIds, options: options, skin: skin))
        return res.match_id
    }

    /// Enter a match. The opening board does NOT come back here — the server builds it and
    /// broadcasts a `game_state` frame to every player.
    @discardableResult
    func join(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/join",
                              body: EmptyBody())
    }

    /// An invite the caller has received but not joined. Drives the home-screen banners.
    ///
    /// DECODED BY HAND, and it has to be. Swift's synthesized `Decodable` ignores property
    /// default values: with the synthesized conformance every one of `overs`, `sent_at`,
    /// `expires_at` and `missed` throws `keyNotFound` the moment the server omits it, one throw
    /// fails the whole array, and the poll's `try?` swallows it — the user just never sees a
    /// banner again, with nothing anywhere to say why. Android's kotlinx defaults DO apply, so
    /// the same payload would work there and the two platforms would diverge silently.
    struct PendingInvite: Decodable, Identifiable {
        let match_id: String
        let slug: String
        let name: String
        var icon_key: String?
        /// Lifted out of the options bag by the server; 0 when the game has no such setting.
        var overs: Int = 0
        var inviter_id: String?
        var inviter_name: String?
        var sent_at: Int64 = 0
        var expires_at: Int64 = 0
        /// Server's verdict on whether the window has passed — not the client's clock.
        var missed: Bool = false

        var id: String { match_id }

        private enum CodingKeys: String, CodingKey {
            case match_id, slug, name, icon_key, overs
            case inviter_id, inviter_name, sent_at, expires_at, missed
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Required: without these there is no invite to show or join.
            match_id = try c.decode(String.self, forKey: .match_id)
            slug     = try c.decode(String.self, forKey: .slug)
            name     = try c.decode(String.self, forKey: .name)

            icon_key      = try c.decodeIfPresent(String.self, forKey: .icon_key)
            overs         = try c.decodeIfPresent(Int.self,    forKey: .overs) ?? 0
            inviter_id    = try c.decodeIfPresent(String.self, forKey: .inviter_id)
            inviter_name  = try c.decodeIfPresent(String.self, forKey: .inviter_name)
            sent_at       = try c.decodeIfPresent(Int64.self,  forKey: .sent_at) ?? 0
            expires_at    = try c.decodeIfPresent(Int64.self,  forKey: .expires_at) ?? 0
            missed        = try c.decodeIfPresent(Bool.self,   forKey: .missed) ?? false
        }
    }

    private struct InvitesResponse: Decodable { let invites: [PendingInvite] }

    /// Invites waiting on the caller: live ones to accept, missed ones to acknowledge.
    func invites() async throws -> [PendingInvite] {
        let res: InvitesResponse = try await api.request("GET", "games/invites")
        return res.invites
    }

    /// Decline an invite, or abandon a lobby nobody joined. Same call for both — they are the same
    /// state change (a 'waiting' match that will never start).
    @discardableResult
    func decline(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/decline", body: EmptyBody())
    }

    /// Tell the server a player is deliberately backing out of a LIVE match screen — as
    /// opposed to `decline`, which is for a match that never started. Without this a
    /// continuous game's tick loop had nothing telling it a player left, so backing out of
    /// Snake left the match ticking (and broadcasting `game_state` at full rate) for up to its
    /// full duration. See docs/GAMES_SNAKE_BUGS.md.
    ///
    /// Fire-and-forget from the caller's perspective — `GamesEngine.leave()` clears local
    /// state unconditionally regardless of whether this network call lands, exactly like
    /// every other "tell the server, but don't block the UI on it" pattern in this app.
    @discardableResult
    func leave(matchId: String) async throws -> JoinResponse {
        try await api.request("POST", "games/matches/\(matchId)/leave", body: EmptyBody())
    }

    private struct EmptyBody: Encodable {}
}
