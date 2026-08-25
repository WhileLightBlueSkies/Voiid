//
//  TournamentService.swift
//  Voiid
//
//  Client for the tournament API (plan item 3.22). The backend shipped complete — brackets,
//  seeding, registration, standings — and nothing on either app referenced it, so no user
//  could see a tournament existed. This is the half that makes it reachable.
//
//  ── NOT E2EE, AND THAT IS THE DESIGN ─────────────────────────────────────────────
//  A bracket is a shared public structure inside a community: the server seeds it, advances
//  it and decides who won, which it can only do by reading it. Game MOVES are refereed by
//  `backend/games`; the bracket around them is ordinary server state, exactly like the
//  community container itself. Nothing on this screen claims otherwise.
//
//  ── MEMBERSHIP IS THE GATE ───────────────────────────────────────────────────────
//  Every endpoint here is community-scoped and the server checks membership on each one; a
//  non-member gets 403 rather than an empty list. This client does not pre-filter on top of
//  that — one authority, not two.
//

import Foundation

@MainActor
final class TournamentService {
    static let shared = TournamentService()
    private let api = APIClient()

    private init() {}

    /// One tournament, as the list and detail endpoints both return it.
    ///
    /// Every field the server may omit is optional. Swift's `Codable` throws `keyNotFound`
    /// on an absent key, so a required field here would turn one added-or-removed server
    /// field into a screen that fails to load rather than one that renders slightly less.
    struct Tournament: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        /// single_elim | double_elim | round_robin — decides what the bracket looks like.
        let format: String?
        /// draft | registering | running | finished | cancelled.
        let status: String?
        let game_name: String?
        let game_slug: String?
        let max_players: Int?
        let player_count: Int?
        let starts_at: String?
        let winner_user_id: String?
        /// Whether YOU are on the roster — decides Register vs Withdraw.
        let registered: Bool?
    }

    private struct ListResponse: Decodable { let tournaments: [Tournament]? }

    func list(communityId: String) async throws -> [Tournament] {
        let r = try await api.request("GET", "communities/\(communityId)/tournaments",
                                      as: ListResponse.self)
        return r.tournaments ?? []
    }

    /// One tournament plus its field. The route nests the card under `tournament` and puts
    /// the roster beside it — decoding straight into `Tournament` read a body that is not
    /// there and threw on every call.
    struct Detail: Decodable {
        let tournament: Tournament?
        let players: [Player]?
        let you_registered: Bool?
    }

    /// One row of the roster, as `GET /tournaments/:id` returns it.
    struct Player: Decodable, Identifiable, Equatable {
        let user_id: String
        let seed: Int?
        /// registered | withdrawn.
        let state: String?
        let eliminated_in_round: Int?
        let full_name: String?
        let username: String?

        var id: String { user_id }

        var display: String {
            if let n = full_name, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            if let u = username, !u.isEmpty { return "@\(u)" }
            return "Player"
        }
    }

    func detail(id: String) async throws -> Detail {
        try await api.request("GET", "tournaments/\(id)", as: Detail.self)
    }

    /// Join the roster. The server owns capacity and the registration window, so a full or
    /// closed tournament is refused there — this client does not gate on `player_count`,
    /// which it read some seconds ago and which several people may be racing to fill.
    func register(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/register", as: EmptyResponse.self)
    }

    func withdraw(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/withdraw", as: EmptyResponse.self)
    }
}

// MARK: - Hosting
//
// The organiser's half. `create`, `start` and `cancel` are admin-gated ON THE SERVER by
// `communityAccess(..., needsAdmin: true)`; standings and matches need only membership.
// The client hides host controls for convenience and is never the enforcement.
extension TournamentService {

    /// The formats the router accepts, with the ceilings 031_tournaments.sql enforces. The
    /// DATABASE is the authority on both — these exist so the picker cannot offer a value the
    /// server would 400, not so the client can decide.
    enum Format: String, CaseIterable, Identifiable {
        case single_elim
        case round_robin

        var id: String { rawValue }

        var title: String {
            switch self {
            case .single_elim: return "Single elimination"
            case .round_robin: return "Round robin"
            }
        }

        var detail: String {
            switch self {
            case .single_elim: return "Lose once and you're out. Up to 64 players."
            case .round_robin: return "Everyone plays everyone. Up to 16 players."
            }
        }

        /// Mirrors `FORMAT_MAX_PLAYERS` in routes/tournaments.ts.
        var maxPlayers: Int {
            switch self {
            case .single_elim: return 64
            case .round_robin: return 16
            }
        }

        /// The route's own default: 32 clamped to the format's ceiling.
        var defaultPlayers: Int { min(32, maxPlayers) }
    }

    private struct TournamentEnvelope: Decodable { let tournament: Tournament? }

    /// Create a tournament.
    ///
    /// `id` IS THE RETRY KEY, and it is minted here rather than left to the server. Creating
    /// and seeding are separate calls, so a POST that times out must be able to land on the
    /// same row instead of leaving a second empty bracket on the community's list — the route
    /// upserts on this id and hands back the existing row.
    func create(communityId: String,
                id: String,
                gameSlug: String,
                name: String,
                format: Format,
                maxPlayers: Int,
                startsAt: String?) async throws -> Tournament? {
        struct Body: Encodable {
            let id: String
            let game_slug: String
            let name: String
            let format: String
            let max_players: Int
            let starts_at: String?
        }
        let r = try await api.request(
            "POST", "communities/\(communityId)/tournaments",
            body: Body(id: id, game_slug: gameSlug, name: name, format: format.rawValue,
                       max_players: maxPlayers, starts_at: startsAt),
            as: TournamentEnvelope.self)
        return r.tournament
    }

    /// Seed the bracket. Seeding order is REGISTRATION order — the server writes it down
    /// rather than shuffling, so a player can be told why they drew who they drew.
    ///
    /// 409 if it has already started, or if fewer than two people registered.
    func start(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/start", as: EmptyResponse.self)
    }

    /// open|active → cancelled. Matches already played are LEFT ALONE: they are history and
    /// belong on the players' records. Nothing here deletes a result.
    func cancel(id: String) async throws {
        _ = try await api.request("POST", "tournaments/\(id)/cancel", as: EmptyResponse.self)
    }

    /// One row of the standings table. Every counter is optional-with-a-default for the
    /// reason the header gives: an absent key must not throw away the whole table.
    struct Standing: Decodable, Identifiable, Equatable {
        let user_id: String
        let full_name: String?
        let username: String?
        let seed: Int?
        /// registered | withdrawn.
        let state: String?
        let eliminated_in_round: Int?
        let played: Int?
        let wins: Int?
        let draws: Int?
        let losses: Int?
        let score: Int?
        let points: Int?

        var id: String { user_id }

        var display: String {
            if let n = full_name, !n.trimmingCharacters(in: .whitespaces).isEmpty { return n }
            if let u = username, !u.isEmpty { return "@\(u)" }
            return "Player"
        }
    }

    struct Standings: Decodable {
        let standings: [Standing]?
        let winner_user_id: String?
    }

    /// The table. Members may read it — a community-scoped leaderboard is defensible where a
    /// global one is not, because everyone on it joined the same community on purpose.
    func standings(id: String) async throws -> Standings {
        try await api.request("GET", "tournaments/\(id)/standings", as: Standings.self)
    }

    /// One fixture. THIS IS HOW A PLAYER LEARNS THEY HAVE A MATCH — there is no bracket
    /// invite, because two strangers drawn against each other have no Double Ratchet session
    /// and no right to open one. The match row is the entire handshake.
    struct Match: Decodable, Identifiable, Equatable {
        let match_id: String
        let round: Int?
        let slot: Int?
        let attempt: Int?
        /// The ordinary game-match vocabulary: pending | active | finished | abandoned.
        let status: String?
        let winner_id: String?
        let player_ids: [String]?
        /// A one-player row is a bye or the remains of a walkover. The server marks it, and a
        /// client MUST NOT offer a Join button for one.
        let bye: Bool?
        let mine: Bool?
        let ended_at: String?

        var id: String { match_id }
        var isBye: Bool { bye ?? ((player_ids?.count ?? 0) < 2) }
    }

    private struct MatchesResponse: Decodable { let matches: [Match]? }

    func matches(id: String) async throws -> [Match] {
        let r = try await api.request("GET", "tournaments/\(id)/matches", as: MatchesResponse.self)
        return r.matches ?? []
    }
}
